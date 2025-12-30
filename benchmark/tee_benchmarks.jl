using BenchmarkTools
using SignalChannels

# PACKAGE_VERSION is provided by AirspeedVelocity or by benchmarks.jl
const TEE_HAS_CHANNEL_SIZE = @isdefined(PACKAGE_VERSION) ? PACKAGE_VERSION > v"3.0.3" : true
# In v4.1.0+, SignalChannels exports PipeChannel (lock-free channel)
# Check if PipeChannel is actually exported by the loaded SignalChannels module
const TEE_USE_PIPECHANNEL = isdefined(SignalChannels, :PipeChannel)

# Import PipeChannel if available
if TEE_USE_PIPECHANNEL
    using SignalChannels: PipeChannel
end

# Number of items to push through the pipeline per benchmark iteration
const TEE_NUM_ITEMS = 1000

# Setup for tee: create input channel with tee outputs
# For v4.1.0+: Uses PipeChannel{Int} for lock-free operation
# For older versions: Uses Channel{Int}
function setup_tee_pipeline(channel_size::Int)
    # Create input channel with large buffer so producer can push all data without blocking
    # PipeChannel requires capacity > 0, so use max(1, channel_size) for buffer sizing
    input = if TEE_USE_PIPECHANNEL
        PipeChannel{Int}(max(TEE_NUM_ITEMS, 16))
    else
        Channel{Int}(TEE_NUM_ITEMS)
    end

    # Create the tee pipeline - spawns task that blocks waiting for input
    # channel_size parameter was added in v3.0.3
    # For PipeChannel, ensure minimum size of 1
    effective_size = TEE_USE_PIPECHANNEL ? max(1, channel_size) : channel_size
    out1, out2 = TEE_HAS_CHANNEL_SIZE ? tee(input, effective_size) : tee(input)

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
    bind(input, producer)

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
# PipeChannel requires capacity > 0, so we start at 1
const TEE_CHANNEL_SIZES = TEE_USE_PIPECHANNEL ? [1, 4, 16, 64] : [0, 1, 4, 16, 64]

SUITE["tee"] = BenchmarkGroup()

for buf_size in TEE_CHANNEL_SIZES
    SUITE["tee"]["buffer=$buf_size"] = @benchmarkable(
        run_tee_pipeline!(input, out1, out2, data),
        setup = ((input, out1, out2, data) = setup_tee_pipeline($buf_size)),
        evals = 1
    )
end
