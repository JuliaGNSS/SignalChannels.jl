using BenchmarkTools
using SignalChannels

# Number of buffers to push through the pipeline per benchmark iteration
const NUM_BUFFERS = 1000

# Setup: create the full pipeline (input -> rechunk -> output) ready to run
# Returns (input_channel, output_channel, pre-allocated input buffers)
function setup_pipeline(input_size::Int, output_size::Int, output_channel_size::Int)
    # Create input channel with large buffer so producer can push all data without blocking
    # This ensures we measure rechunk throughput, not input channel contention
    input = SignalChannel{ComplexF32}(input_size, 1, NUM_BUFFERS)

    # Create the rechunk pipeline - this spawns the task but it blocks waiting for input
    output = rechunk(input, output_size, output_channel_size)

    # Pre-allocate input buffers to avoid allocation during benchmark
    buffers = [zeros(ComplexF32, input_size, 1) for _ in 1:NUM_BUFFERS]

    return (input, output, buffers)
end

# Benchmark: push data through the pipeline and drain output
# This measures only the data flow, not the pipeline setup
function run_pipeline!(input, output, buffers)
    # Producer task: push all buffers into the pipeline
    producer = Threads.@spawn begin
        for buff in buffers
            put!(input, buff)
        end
        close(input)
    end

    # Consumer: drain the output as fast as possible
    count = 0
    for _ in output
        count += 1
    end

    wait(producer)
    return count
end

# Channel sizes to test - reduced set for faster CI
const RECHUNK_CHANNEL_SIZES = [0, 1, 4, 16, 64]

SUITE["rechunk"] = BenchmarkGroup()

# Upsampling: 2048 -> 10000 (combining ~5 input buffers per output)
SUITE["rechunk"]["2048_to_10000"] = BenchmarkGroup()
for buf_size in RECHUNK_CHANNEL_SIZES
    SUITE["rechunk"]["2048_to_10000"]["buffer=$buf_size"] = @benchmarkable(
        run_pipeline!(input, output, buffers),
        setup = ((input, output, buffers) = setup_pipeline(2048, 10000, $buf_size)),
        evals = 1
    )
end

# Downsampling: 10000 -> 2048 (splitting each input buffer into ~5 outputs)
SUITE["rechunk"]["10000_to_2048"] = BenchmarkGroup()
for buf_size in RECHUNK_CHANNEL_SIZES
    SUITE["rechunk"]["10000_to_2048"]["buffer=$buf_size"] = @benchmarkable(
        run_pipeline!(input, output, buffers),
        setup = ((input, output, buffers) = setup_pipeline(10000, 2048, $buf_size)),
        evals = 1
    )
end
