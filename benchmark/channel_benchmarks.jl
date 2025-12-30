using BenchmarkTools
using SignalChannels
using FixedSizeArrays: FixedSizeMatrixDefault

# Number of buffers to push through the channel per benchmark iteration
const CHANNEL_NUM_BUFFERS = 10_000
const CHANNEL_NUM_SAMPLES = 2048

# Setup: create producer/consumer pipeline ready to run
function setup_channel_benchmark(num_samples::Int, buffer_size::Int)
    ch = SignalChannel{ComplexF32}(num_samples, 1, buffer_size)

    data = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, num_samples, 1))
    return (ch, data)
end

# Benchmark: push data through the channel and drain output
function run_channel_benchmark!(ch::SignalChannel{ComplexF32}, data::FixedSizeMatrixDefault{ComplexF32}, num_items::Int)
    # Producer task
    producer = Threads.@spawn begin
        for _ in 1:num_items
            put!(ch, data)
        end
        close(ch)
    end
    bind(ch, producer)

    # Consumer task
    consumer = Threads.@spawn begin
        for _ in ch
        end
    end

    wait(producer)
    wait(consumer)
    return nothing
end

# Channel buffer sizes to test
const CHANNEL_BUFFER_SIZES = [1, 4, 16, 64, 256, 1024]

SUITE["channel"] = BenchmarkGroup()

for buf_size in CHANNEL_BUFFER_SIZES
    SUITE["channel"]["buffer=$buf_size"] = @benchmarkable(
        run_channel_benchmark!(ch, data, CHANNEL_NUM_BUFFERS),
        setup = ((ch, data) = setup_channel_benchmark(CHANNEL_NUM_SAMPLES, $buf_size)),
        evals = 1
    )
end
