module UCX

using Sockets: InetAddr, IPv4, listenany

include("api.jl")

function __init__()
    # Julia multithreading uses SIGSEGV to sync thread
    # https://docs.julialang.org/en/v1/devdocs/debuggingtips/#Dealing-with-signals-1
    # By default, UCX will error if this occurs (see https://github.com/JuliaParallel/MPI.jl/issues/337)
    # This is a global flag and can't be set per context, since Julia generally
    # handles signals I don't see any additional value in having UCX mess with
    # signal handlers. Setting the environment here does not work, since it is
    # global, not context specific, and is being parsed on library load.

    # reinstall signal handlers
    ccall((:ucs_debug_disable_signals, API.libucs), Cvoid, ())
end

function memzero!(ref::Ref)
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), ref, 0, sizeof(ref))
end

Base.@pure function find_field(::Type{T}, fieldname) where T
    findfirst(f->f === fieldname, fieldnames(T))
end

@inline function set!(ref::Ref{T}, fieldname, val) where T
    field = find_field(T, fieldname)
    offset = fieldoffset(T, field)
    GC.@preserve ref begin
        base_ptr =  Base.unsafe_convert(Ptr{T}, ref)
        ptr = reinterpret(UInt, base_ptr) + offset
        Base.unsafe_store!(reinterpret(Ptr{fieldtype(T, field)}, ptr), val)
    end
    val
end

# Exceptions/Status

uintptr_t(ptr::Ptr) = reinterpret(UInt, ptr)
uintptr_t(status::API.ucs_status_t) = reinterpret(UInt, convert(Int, status))

UCS_PTR_STATUS(ptr::Ptr{Cvoid}) = API.ucs_status_t(reinterpret(UInt, ptr)) 
UCS_PTR_IS_ERR(ptr::Ptr{Cvoid}) = uintptr_t(ptr) >= uintptr_t(API.UCS_ERR_LAST)
UCS_PTR_IS_PTR(ptr::Ptr{Cvoid}) = (uintptr_t(ptr) - 1) < (uintptr_t(API.UCS_ERR_LAST) - 1)

struct UCXException <: Exception
    status::API.ucs_status_t
end

macro check(ex)
    quote
        status = $(esc(ex))
        if status != API.UCS_OK
            throw(UCXException(status))
        end
    end
end

# Utils

macro async_showerr(ex)
    esc(quote
        @async try
            $ex
        catch err
            bt = catch_backtrace()
            showerror(stderr, err, bt)
            rethrow()
        end
    end)
end

macro spawn_showerr(ex)
    esc(quote
        Base.Threads.@spawn try
            $ex
        catch err
            bt = catch_backtrace()
            showerror(stderr, err, bt)
            rethrow()
        end
    end)
end

# Config

function version()
    major = Ref{Cuint}()
    minor = Ref{Cuint}()
    patch = Ref{Cuint}()
    API.ucp_get_version(major, minor, patch)
    VersionNumber(major[], minor[], patch[])
end

mutable struct UCXConfig
    handle::Ptr{API.ucp_config_t}

    function UCXConfig(; kwargs...)
        r_handle = Ref{Ptr{API.ucp_config_t}}()
        @check API.ucp_config_read(C_NULL, C_NULL, r_handle) # XXX: Prefix is broken

        config = new(r_handle[])
        finalizer(config) do config
            API.ucp_config_release(config)
        end

        for (key, value) in kwargs
            config[key] = string(value)
        end

        config
    end
end
Base.unsafe_convert(::Type{Ptr{API.ucp_config_t}}, config::UCXConfig) = config.handle

function Base.setindex!(config::UCXConfig, value::String, key::Union{String, Symbol})
    @check API.ucp_config_modify(config, key, value)
    return value
end

function Base.parse(::Type{Dict}, config::UCXConfig)
    ptr  = Ref{Ptr{Cchar}}()
    size = Ref{Csize_t}()
    fd   = ccall(:open_memstream, Ptr{API.FILE}, (Ptr{Ptr{Cchar}}, Ptr{Csize_t}), ptr, size)

    # Flush the just created fd to have `ptr` be valid
    systemerror("fflush", ccall(:fflush, Cint, (Ptr{API.FILE},), fd) != 0)

    try
        API.ucp_config_print(config, fd, C_NULL, API.UCS_CONFIG_PRINT_CONFIG)
        systemerror("fclose", ccall(:fclose, Cint, (Ptr{API.FILE},), fd) != 0)
    catch
        Base.Libc.free(ptr[])
        rethrow()
    end
    io = IOBuffer(unsafe_wrap(Array, Base.unsafe_convert(Ptr{UInt8}, ptr[]), (size[],), own=true))

    dict = Dict{Symbol, String}()
    for line in readlines(io)
        key, value = split(line, '=')
        key = key[5:end] # Remove `UCX_`
        dict[Symbol(key)] = value
    end
    return dict
end

mutable struct UCXContext
    handle::API.ucp_context_h
    config::Dict{Symbol, String}

    function UCXContext(; kwargs...)
        field_mask   = API.UCP_PARAM_FIELD_FEATURES

        # We always request UCP_FEATURE_WAKEUP even when in blocking mode
        # See <https://github.com/rapidsai/ucx-py/pull/377>
        # There is also AMO32 & AMO64 (atomic), RMA, and AM
        features     = API.UCP_FEATURE_TAG |
                       API.UCP_FEATURE_WAKEUP |
                       API.UCP_FEATURE_STREAM

        params = Ref{API.ucp_params}()
        memzero!(params)
        set!(params, :field_mask,   field_mask)
        set!(params, :features,     features)

        config = UCXConfig(; kwargs...)

        r_handle = Ref{API.ucp_context_h}()
        # UCP.ucp_init is a header function so we call, UCP.ucp_init_version
        @check API.ucp_init_version(API.UCP_API_MAJOR, API.UCP_API_MINOR,
                                    params, config, r_handle)

        context = new(r_handle[], parse(Dict, config))

        finalizer(context) do context
            API.ucp_cleanup(context)
        end
    end
end
Base.unsafe_convert(::Type{API.ucp_context_h}, ctx::UCXContext) = ctx.handle

function info(ucx::UCXContext)
    ptr  = Ref{Ptr{Cchar}}()
    size = Ref{Csize_t}()
    fd   = ccall(:open_memstream, Ptr{API.FILE}, (Ptr{Ptr{Cchar}}, Ptr{Csize_t}), ptr, size)

    # Flush the just created fd to have `ptr` be valid
    systemerror("fflush", ccall(:fflush, Cint, (Ptr{API.FILE},), fd) != 0)

    try
        API.ucp_context_print_info(ucx, fd)
        systemerror("fclose", ccall(:fclose, Cint, (Ptr{API.FILE},), fd) != 0)
    catch
        Base.Libc.free(ptr[])
        rethrow()
    end
    str = unsafe_string(ptr[], size[])
    Base.Libc.free(ptr[])
    str
end

# ucp_context_query

mutable struct UCXWorker
    handle::API.ucp_worker_h
    context::UCXContext

    function UCXWorker(context::UCXContext)
        field_mask  = API.UCP_WORKER_PARAM_FIELD_THREAD_MODE
        thread_mode = API.UCS_THREAD_MODE_MULTI

        params = Ref{API.ucp_worker_params}()
        memzero!(params)
        set!(params, :field_mask,  field_mask)
        set!(params, :thread_mode, thread_mode)

        r_handle = Ref{API.ucp_worker_h}()
        @check API.ucp_worker_create(context, params, r_handle)

        worker = new(r_handle[], context)
        finalizer(worker) do worker
            API.ucp_worker_destroy(worker)
        end
        return worker
    end
end
Base.unsafe_convert(::Type{API.ucp_worker_h}, worker::UCXWorker) = worker.handle

function progress(worker::UCXWorker)
    API.ucp_worker_progress(worker) !== 0
end

struct UCXConnectionRequest
    handle::API.ucp_conn_request_h
end

mutable struct UCXEndpoint
    handle::API.ucp_ep_h
    worker::UCXWorker
    open::Bool

    function UCXEndpoint(worker::UCXWorker, handle::API.ucp_ep_h)
        endpoint = new(handle, worker, true)
        finalizer(endpoint) do endpoint
            # NOTE: Generally not safe to spin in finalizer
            #   - ucp_ep_destroy
            #   - ucp_ep_close_nb (Gracefully shutdown)
            #     - UCP_EP_CLOSE_MODE_FORCE
            #     - UCP_EP_CLOSE_MODE_FLUSH
            let handle = endpoint.handle # Valid since we are aleady finalizing endpoint
                @async_showerr begin
                    status = API.ucp_ep_close_nb(handle, API.UCP_EP_CLOSE_MODE_FLUSH)
                    if UCS_PTR_IS_PTR(status)
                        while API.ucp_request_check_status(status) == API.UCS_INPROGRESS
                            progress(worker)
                            yield()
                        end
                        API.ucp_request_free(status)
                    else
                        @check UCS_PTR_STATUS(status)
                    end
                end
            end
        end
        endpoint
    end
end
Base.unsafe_convert(::Type{API.ucp_ep_h}, ep::UCXEndpoint) = ep.handle

function Base.isopen(ep::UCXEndpoint)
    ep.open
end

function UCXEndpoint(worker::UCXWorker, ip::IPv4, port)
    field_mask = API.UCP_EP_PARAM_FIELD_FLAGS |
                 API.UCP_EP_PARAM_FIELD_SOCK_ADDR
    flags      = API.UCP_EP_PARAMS_FLAGS_CLIENT_SERVER
    sockaddr   = Ref(API.IP.sockaddr_in(InetAddr(ip, port)))

    r_handle = Ref{API.ucp_ep_h}()
    GC.@preserve sockaddr begin
        ptr = Base.unsafe_convert(Ptr{API.sockaddr}, sockaddr)
        ucs_sockaddr = API.ucs_sock_addr(ptr, sizeof(sockaddr))

        params = Ref{API.ucp_ep_params}()
        memzero!(params)
        set!(params, :field_mask,   field_mask)
        set!(params, :sockaddr,     ucs_sockaddr)
        set!(params, :flags,        flags)

        # TODO: Error callback
    
        @check API.ucp_ep_create(worker, params, r_handle)
    end

    UCXEndpoint(worker, r_handle[])
end

function UCXEndpoint(worker::UCXWorker, conn_request::UCXConnectionRequest)
    field_mask = API.UCP_EP_PARAM_FIELD_FLAGS |
                 API.UCP_EP_PARAM_FIELD_CONN_REQUEST
    flags      = API.UCP_EP_PARAMS_FLAGS_NO_LOOPBACK

    params = Ref{API.ucp_ep_params}()
    memzero!(params)
    set!(params, :field_mask,   field_mask)
    set!(params, :conn_request, conn_request.handle)
    set!(params, :flags,        flags)

    # TODO: Error callback

    r_handle = Ref{API.ucp_ep_h}()
    @check API.ucp_ep_create(worker, params, r_handle)

    UCXEndpoint(worker, r_handle[])
end

function listener_callback(conn_request_h::API.ucp_conn_request_h, args::Ptr{Cvoid})
    nothing
end

mutable struct UCXListener
    handle::API.ucp_listener_h
    worker::UCXWorker
    port::Cint

    function UCXListener(worker::UCXWorker, port=nothing,
                         callback::Union{Ptr{Cvoid}, Base.CFunction} = @cfunction(listener_callback, Cvoid, (API.ucp_conn_request_h, Ptr{Cvoid})),
                         args::Ptr{Cvoid} = C_NULL)
        # Choose free port
        if port === nothing || port == 0
            port_hint = 9000 + (getpid() % 1000)
            port, sock = listenany(UInt16(port_hint))
            close(sock) # FIXME: https://github.com/rapidsai/ucx-py/blob/72552d1dd1d193d1c8ce749171cdd34d64523d53/ucp/core.py#L288-L304
        end

        field_mask   = API.UCP_LISTENER_PARAM_FIELD_SOCK_ADDR |
                       API.UCP_LISTENER_PARAM_FIELD_CONN_HANDLER
        sockaddr     = Ref(API.IP.sockaddr_in(InetAddr(IPv4(API.IP.INADDR_ANY), port)))
        conn_handler = API.ucp_listener_conn_handler(Base.unsafe_convert(Ptr{Cvoid}, callback), args)

        r_handle = Ref{API.ucp_listener_h}()
        GC.@preserve sockaddr begin
            ptr = Base.unsafe_convert(Ptr{API.sockaddr}, sockaddr)
            ucs_sockaddr = API.ucs_sock_addr(ptr, sizeof(sockaddr))

            params = Ref{API.ucp_listener_params}()
            memzero!(params)
            set!(params, :field_mask, field_mask)
            set!(params, :sockaddr, ucs_sockaddr)
            set!(params, :conn_handler, conn_handler)

            @check API.ucp_listener_create(worker, params, r_handle)
        end  

        listener = new(r_handle[], worker, port)
        finalizer(listener) do listener
            API.ucp_listener_destroy(listener)
        end
    end
end
Base.unsafe_convert(::Type{API.ucp_listener_h}, listener::UCXListener) = listener.handle

function reject(listener::UCXListener, conn_request::UCXConnectionRequest)
    @check API.ucp_listener_reject(listener, conn_request.handle)
end

function ucp_dt_make_contig(elem_size)
    ((elem_size%API.ucp_datatype_t) << convert(API.ucp_datatype_t, API.UCP_DATATYPE_SHIFT)) | API.UCP_DATATYPE_CONTIG
end

##
# UCX tagged send and receive
##

function send_callback(request::Ptr{Cvoid}, status::API.ucs_status_t)
    nothing
end

function recv_callback(request::Ptr{Cvoid}, status::API.ucs_status_t, info::Ptr{API.ucp_tag_recv_info_t})
    nothing
end

# Current implementation is blocking
handle_request(ep::UCXEndpoint, ptr) = handle_request(ep.worker, ptr)
function handle_request(worker::UCXWorker, ptr)
    if UCS_PTR_IS_PTR(ptr)
        status = API.ucp_request_check_status(ptr)
        while status === API.UCS_INPROGRESS
            progress(worker)
            yield()
            status = API.ucp_request_check_status(ptr)
        end
        API.ucp_request_free(ptr)
    else
        status = UCS_PTR_STATUS(ptr)
    end
    @check status
end


function send(ep::UCXEndpoint, buffer, nbytes, tag)
    dt = ucp_dt_make_contig(1) # since we are sending nbytes
    cb = @cfunction(send_callback, Cvoid, (Ptr{Cvoid}, API.ucs_status_t))

    GC.@preserve buffer begin
        data = pointer(buffer)

        ptr = API.ucp_tag_send_nb(ep, data, nbytes, dt, tag, cb)
        return handle_request(ep, ptr)
    end
end

function recv(worker::UCXWorker, buffer, nbytes, tag, tag_mask=~zero(UCX.API.ucp_tag_t))
    dt = ucp_dt_make_contig(1)
    cb = @cfunction(recv_callback, Cvoid, (Ptr{Cvoid}, API.ucs_status_t, Ptr{API.ucp_tag_recv_info_t}))

    GC.@preserve buffer begin
        data = pointer(buffer)
        ptr = API.ucp_tag_recv_nb(worker, data, nbytes, dt, tag, tag_mask, cb)
        return handle_request(worker, ptr)
    end
end

struct UCXMessage
    handle::API.ucp_tag_message_h
    info::API.ucp_tag_recv_info_t
end

function probe(worker::UCXWorker, tag, tag_mask=~zero(UCX.API.ucp_tag_t), remove=true)
    info = Ref{API.ucp_tag_recv_info_t}()
    message_h = API.ucp_tag_probe_nb(worker, tag, tag_mask, remove, info)
    if message_h === C_NULL
        return nothing
    else
        return UCXMessage(message_h, info[])
    end
end

function recv(worker::UCXWorker, msg::UCXMessage, buffer, nbytes)
    dt = ucp_dt_make_contig(sizeof(eltype(buffer)))
    cb = @cfunction(recv_callback, Cvoid, (Ptr{Cvoid}, API.ucs_status_t, Ptr{API.ucp_tag_recv_info_t}))

    GC.@preserve data begin
        data = pointer(buffer)

        ptr = API.ucp_tag_msg_recv_nb(worker, data, nbytes, dt, msg.handle, cb)
        return handle_request(worker, ptr)
    end
end

# UCX stream interface

function stream_send(ep::UCXEndpoint, buffer, nbytes)
    dt = ucp_dt_make_contig(1) # since we are sending nbytes
    cb = @cfunction(send_callback, Cvoid, (Ptr{Cvoid}, API.ucs_status_t))

    GC.@preserve buffer begin
        data = pointer(buffer)

        ptr = API.ucp_stream_send_nb(ep, data, nbytes, dt, cb, #=flags=# 0)
        return handle_request(ep, ptr)
    end
end

function stream_recv(ep::UCXEndpoint, buffer, nbytes)
    dt = ucp_dt_make_contig(1) # since we are sending nbytes
    cb = @cfunction(send_callback, Cvoid, (Ptr{Cvoid}, API.ucs_status_t))

    GC.@preserve buffer begin
        data = pointer(buffer)

        length = Ref{Csize_t}(0)
        ptr = API.ucp_stream_recv_nb(ep, data, nbytes, dt, cb, length, API.UCP_STREAM_RECV_FLAG_WAITALL)
        return handle_request(ep, ptr)
    end
end

# RMA

# Atomics

# AM

# Collectives

end #module
