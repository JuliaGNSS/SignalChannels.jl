using BenchmarkTools
using SignalChannels

# PACKAGE_VERSION is provided by AirspeedVelocity
const TEE_HAS_CHANNEL_SIZE = @isdefined(PACKAGE_VERSION) ? PACKAGE_VERSION > v"3.0.3" : true

# Number of items to push through the pipeline per benchmark iteration
const TEE_NUM_ITEMS = 1000

# Setup for tee: create input channel with tee outputs
# Uses simple Channel{Int} for primitive data
function setup_tee_pipeline(channel_size::Int)
    # Create input channel with large buffer so producer can push all data without blocking
    input = Channel{Int}(TEE_NUM_ITEMS)

    # Create the tee pipeline - spawns task that blocks waiting for input
    # channel_size parameter added in v3.0.3
    out1, out2 = TEE_HAS_CHANNEL_SIZE ? tee(input, channel_size) : tee(input)

    # Pre-allocate input data
    data = collect(1:TEE_NUM_ITEMS)

    return (input, out1, out2, data)
end

# Benchmark: push data through tee and drain both outputs
function run_tee_pipeline!(input, out1, out2, data)
    # Producer task: push all data into the input
    producer = Threads.@spawn begin
        for d in data
            put!(input, d)
        end
        close(input)
    end

    # Consumer tasks: drain both outputs concurrently
    consumer1 = Threads.@spawn begin
        count = 0
        for _ in out1
            count += 1
        end
        count
    end

    consumer2 = Threads.@spawn begin
        count = 0
        for _ in out2
            count += 1
        end
        count
    end

    wait(producer)
    return fetch(consumer1) + fetch(consumer2)
end

# Channel sizes to test - reduced set for faster CI
const TEE_CHANNEL_SIZES = [0, 1, 4, 16, 64]

SUITE["tee"] = BenchmarkGroup()

for buf_size in TEE_CHANNEL_SIZES
    SUITE["tee"]["buffer=$buf_size"] = @benchmarkable(
        run_tee_pipeline!(input, out1, out2, data),
        setup = ((input, out1, out2, data) = setup_tee_pipeline($buf_size)),
        evals = 1
    )
end
