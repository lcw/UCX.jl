using UCX
using Sockets

using UCX: UCXEndpoint
using UCX: recv, send

using Base.Threads

const default_port = 8890
const expected_clients = Atomic{Int}(0)

function echo_server(ep::UCXEndpoint)
    size = Int[0]
    recv(ep.worker, size, sizeof(Int), 777)
    data = Array{UInt8}(undef, size[1])
    recv(ep.worker, data, sizeof(data), 777)
    send(ep, data, sizeof(data), 777)
    atomic_sub!(expected_clients, 1)
end

function start_server(ch_port = Channel{Int}(1), port = default_port)
    ctx = UCX.UCXContext()
    worker = UCX.UCXWorker(ctx)

    function listener_callback(conn_request_h::UCX.API.ucp_conn_request_h, args::Ptr{Cvoid})
        conn_request = UCX.UCXConnectionRequest(conn_request_h)
        Threads.@spawn begin
            try
                echo_server(UCXEndpoint($worker, $conn_request))
            catch err
                showerror(stderr, err, catch_backtrace())
                exit(-1)
            end
        end
        nothing
    end
    cb = @cfunction($listener_callback, Cvoid, (UCX.API.ucp_conn_request_h, Ptr{Cvoid}))
    listener = UCX.UCXListener(worker, port, cb)
    push!(ch_port, listener.port)

    while expected_clients[] > 0
        UCX.progress(worker)
        yield()
    end
end

function start_client(port=default_port)
    ctx = UCX.UCXContext()
    worker = UCX.UCXWorker(ctx)
    ep = UCX.UCXEndpoint(worker, IPv4("127.0.0.1"), port)

    data = "Hello world"
    send(ep, Int[sizeof(data)], sizeof(Int), 777)
    send(ep, data, sizeof(data), 777)
    buffer = Array{UInt8}(undef, sizeof(data))
    recv(worker, buffer, sizeof(buffer), 777)
    @assert String(buffer) == data
end

if !isinteractive()
    @assert length(ARGS) >= 1 "Expected command line argument role: 'client', 'server', 'test'"
    kind = ARGS[1]
    expected_clients[] = length(ARGS) == 2 ? parse(Int, ARGS[2]) : 1
    if kind == "server"
        start_server()
    elseif kind == "client"
        start_client()
    elseif kind =="test"
        ch_port = Channel{Int}(1)
        @sync begin
            UCX.@async_showerr start_server(ch_port, nothing)
            port = take!(ch_port)
            for i in 1:expected_clients[]
                UCX.@async_showerr start_client(port)
            end
        end
    end
end
