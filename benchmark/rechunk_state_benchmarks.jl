using BenchmarkTools
using SignalChannels

const RECHUNK_STATE_SUPPORTED = isdefined(SignalChannels, :RechunkState)

if RECHUNK_STATE_SUPPORTED

    using SignalChannels: RechunkState, rechunk!, reset!
    using FixedSizeArrays: FixedSizeMatrixDefault

    # ============================================================================
    # RechunkState / rechunk! Benchmarks
    #
    # These benchmarks test the low-level rechunk! function performance,
    # independent of channel overhead. This measures the raw data copying
    # throughput of the rechunking algorithm.
    # ============================================================================

    # Number of input buffers to process per benchmark iteration
    const RECHUNK_STATE_NUM_BUFFERS = 1000

    # ============================================================================
    # Single-threaded rechunk! throughput
    # ============================================================================

    # Setup: create RechunkState and pre-allocated input buffers
    function setup_rechunk_state(
        ::Type{T},
        input_size::Int,
        output_size::Int,
        nchannels::Int,
        num_buffers::Int
    ) where {T}
        # Estimate how many output buffers we'll produce
        total_input_samples = input_size * num_buffers
        max_output_buffers = cld(total_input_samples, output_size) + 2

        state = RechunkState{T}(output_size, nchannels, max_output_buffers)
        inputs = [FixedSizeMatrixDefault{T}(rand(T, input_size, nchannels)) for _ in 1:num_buffers]
        return (state, inputs)
    end

    # Benchmark: process all input buffers through rechunk!, consuming all outputs
    function run_rechunk_state!(state::RechunkState{T}, inputs::Vector{<:AbstractMatrix{T}}) where {T}
        output_count = 0
        for input in inputs
            for _ in rechunk!(state, input)
                output_count += 1
            end
        end
        return output_count
    end

    # ============================================================================
    # Benchmark Suite Definition
    # ============================================================================

    SUITE["rechunk_state"] = BenchmarkGroup()

    # -----------------------------------------------------------------------------
    # Upsampling benchmarks: combining multiple small inputs into larger outputs
    # -----------------------------------------------------------------------------
    SUITE["rechunk_state"]["upsample"] = BenchmarkGroup()

    # 512 → 2048 (4:1 ratio) - typical SDR buffer combining
    SUITE["rechunk_state"]["upsample"]["512_to_2048_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 512, 2048, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["upsample"]["512_to_2048_4ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 512, 2048, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # 1024 → 10000 (~10:1 ratio) - large FFT buffer building
    SUITE["rechunk_state"]["upsample"]["1024_to_10000_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 1024, 10000, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # -----------------------------------------------------------------------------
    # Downsampling benchmarks: splitting large inputs into smaller outputs
    # -----------------------------------------------------------------------------
    SUITE["rechunk_state"]["downsample"] = BenchmarkGroup()

    # 2048 → 512 (1:4 ratio) - typical SDR buffer splitting
    SUITE["rechunk_state"]["downsample"]["2048_to_512_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 512, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["downsample"]["2048_to_512_4ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 512, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # 10000 → 1024 (~1:10 ratio) - large input chunking
    SUITE["rechunk_state"]["downsample"]["10000_to_1024_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 10000, 1024, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # -----------------------------------------------------------------------------
    # Same-size passthrough (edge case - no actual rechunking needed)
    # -----------------------------------------------------------------------------
    SUITE["rechunk_state"]["passthrough"] = BenchmarkGroup()

    SUITE["rechunk_state"]["passthrough"]["2048_to_2048_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 2048, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["passthrough"]["2048_to_2048_4ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 2048, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # -----------------------------------------------------------------------------
    # Different element types
    # -----------------------------------------------------------------------------
    SUITE["rechunk_state"]["types"] = BenchmarkGroup()

    # Float32 (real samples)
    SUITE["rechunk_state"]["types"]["Float32_2048_to_1024"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(Float32, 2048, 1024, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # Float64 (double precision)
    SUITE["rechunk_state"]["types"]["Float64_2048_to_1024"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(Float64, 2048, 1024, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # ComplexF64 (double precision complex - largest common type)
    SUITE["rechunk_state"]["types"]["ComplexF64_2048_to_1024"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF64, 2048, 1024, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # Int16 (raw ADC samples)
    SUITE["rechunk_state"]["types"]["Int16_2048_to_1024"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(Int16, 2048, 1024, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # -----------------------------------------------------------------------------
    # Multi-channel scaling
    # -----------------------------------------------------------------------------
    SUITE["rechunk_state"]["channels"] = BenchmarkGroup()

    for nch in [1, 2, 4, 8]
        SUITE["rechunk_state"]["channels"]["2048_to_1024_$(nch)ch"] = @benchmarkable(
            run_rechunk_state!(state, inputs),
            setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 1024, $nch, RECHUNK_STATE_NUM_BUFFERS)),
            evals = 1
        )
    end

    # -----------------------------------------------------------------------------
    # Zero-copy passthrough comparison
    # When input size == output size and no partial data is buffered, the input
    # is returned directly without copying. Compare against near-passthrough
    # (input size = output size - 1) which requires actual copying.
    # -----------------------------------------------------------------------------
    SUITE["rechunk_state"]["zero_copy"] = BenchmarkGroup()

    # Setup for passthrough benchmarks - need exact size match
    function setup_passthrough(::Type{T}, size::Int, nchannels::Int, num_buffers::Int) where {T}
        state = RechunkState{T}(size, nchannels, num_buffers + 2)
        inputs = [FixedSizeMatrixDefault{T}(rand(T, size, nchannels)) for _ in 1:num_buffers]
        return (state, inputs)
    end

    # Setup for near-passthrough (requires copying due to size mismatch)
    function setup_near_passthrough(::Type{T}, size::Int, nchannels::Int, num_buffers::Int) where {T}
        # Output is 1 sample smaller, so copies are required
        state = RechunkState{T}(size - 1, nchannels, num_buffers + 100)
        inputs = [FixedSizeMatrixDefault{T}(rand(T, size, nchannels)) for _ in 1:num_buffers]
        return (state, inputs)
    end

    # Passthrough (zero-copy) benchmarks
    SUITE["rechunk_state"]["zero_copy"]["passthrough_2048_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_passthrough(ComplexF32, 2048, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["zero_copy"]["passthrough_2048_4ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_passthrough(ComplexF32, 2048, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["zero_copy"]["passthrough_8192_4ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_passthrough(ComplexF32, 8192, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # Near-passthrough (requires copying) benchmarks for comparison
    SUITE["rechunk_state"]["zero_copy"]["near_passthrough_2048_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_near_passthrough(ComplexF32, 2048, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["zero_copy"]["near_passthrough_2048_4ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_near_passthrough(ComplexF32, 2048, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["zero_copy"]["near_passthrough_8192_4ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_near_passthrough(ComplexF32, 8192, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # -----------------------------------------------------------------------------
    # Batch API benchmarks
    # Compare batch rechunk!(state, inputs_vector) vs iterating rechunk!(state, input)
    # -----------------------------------------------------------------------------
    SUITE["rechunk_state"]["batch"] = BenchmarkGroup()

    # Benchmark: use batch API - pass entire vector at once
    function run_rechunk_state_batch!(state::RechunkState{T}, inputs::Vector{<:AbstractMatrix{T}}) where {T}
        output_count = 0
        for _ in rechunk!(state, inputs)
            output_count += 1
        end
        return output_count
    end

    # Batch vs iterative comparison - downsampling (produces many outputs)
    SUITE["rechunk_state"]["batch"]["iterative_2048_to_512_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 512, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["batch"]["batch_2048_to_512_1ch"] = @benchmarkable(
        run_rechunk_state_batch!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 512, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # Batch vs iterative comparison - upsampling (produces fewer outputs)
    SUITE["rechunk_state"]["batch"]["iterative_512_to_2048_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 512, 2048, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["batch"]["batch_512_to_2048_1ch"] = @benchmarkable(
        run_rechunk_state_batch!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 512, 2048, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # Batch vs iterative comparison - passthrough (zero-copy path)
    SUITE["rechunk_state"]["batch"]["iterative_passthrough_2048_1ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_passthrough(ComplexF32, 2048, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["batch"]["batch_passthrough_2048_1ch"] = @benchmarkable(
        run_rechunk_state_batch!(state, inputs),
        setup = ((state, inputs) = setup_passthrough(ComplexF32, 2048, 1, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    # Batch with multiple channels
    SUITE["rechunk_state"]["batch"]["iterative_2048_to_512_4ch"] = @benchmarkable(
        run_rechunk_state!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 512, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

    SUITE["rechunk_state"]["batch"]["batch_2048_to_512_4ch"] = @benchmarkable(
        run_rechunk_state_batch!(state, inputs),
        setup = ((state, inputs) = setup_rechunk_state(ComplexF32, 2048, 512, 4, RECHUNK_STATE_NUM_BUFFERS)),
        evals = 1
    )

end # RECHUNK_STATE_SUPPORTED
