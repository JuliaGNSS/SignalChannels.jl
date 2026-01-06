module RechunkTest

using Test: @test, @testset
using SignalChannels: SignalChannel, rechunk, RechunkState, rechunk!, get_partial_buffer, reset!, get_num_antenna_channels
using FixedSizeArrays: FixedSizeMatrixDefault

@testset "Rechunk" begin
    @testset "RechunkState - basic construction" begin
        state = RechunkState{ComplexF32}(1024, 4, 10)
        @test state.output_chunk_size == 1024
        @test get_num_antenna_channels(state) == 4
        @test length(state.buffer_pool) == 10
        @test state.buffer_idx == 1
        @test state.chunk_filled == 0
        @test size(state.buffer_pool[1]) == (1024, 4)
    end

    @testset "RechunkState - single channel rechunking" begin
        # 512 samples input → 1024 samples output
        state = RechunkState{Float64}(1024, 1, 5)

        # First input: 512 samples - should yield nothing (partial fill)
        input1 = FixedSizeMatrixDefault{Float64}(fill(1.0, 512, 1))
        results1 = rechunk!(state, input1)
        @test length(results1) == 0
        @test state.chunk_filled == 512

        # Second input: 512 more samples - should complete one chunk
        input2 = FixedSizeMatrixDefault{Float64}(fill(2.0, 512, 1))
        results2 = rechunk!(state, input2)
        @test length(results2) == 1
        @test size(results2[1]) == (1024, 1)
        @test all(results2[1][1:512, 1] .== 1.0)
        @test all(results2[1][513:1024, 1] .== 2.0)
        @test state.chunk_filled == 0
    end

    @testset "RechunkState - multi-channel rechunking" begin
        # Test with 4 channels
        state = RechunkState{ComplexF32}(100, 4, 5)

        # Input with 250 samples × 4 channels
        input = FixedSizeMatrixDefault{ComplexF32}(undef, 250, 4)
        for ch in 1:4
            input[:, ch] .= ComplexF32(ch, 0)
        end

        results = rechunk!(state, input)
        @test length(results) == 2  # 250 / 100 = 2 complete chunks

        # Verify each channel has correct data
        for ch in 1:4
            @test all(results[1][:, ch] .== ComplexF32(ch, 0))
            @test all(results[2][:, ch] .== ComplexF32(ch, 0))
        end

        # 50 samples should be left over
        @test state.chunk_filled == 50
    end

    @testset "RechunkState - downsampling (large input)" begin
        # 10000 samples input → 1024 samples output
        state = RechunkState{Float32}(1024, 2, 12)

        input = FixedSizeMatrixDefault{Float32}(fill(3.14f0, 10000, 2))
        results = rechunk!(state, input)

        # 10000 / 1024 = 9.765 → 9 complete chunks
        @test length(results) == 9
        @test all(size(r) == (1024, 2) for r in results)

        # 10000 - 9*1024 = 784 samples left
        @test state.chunk_filled == 784
    end

    @testset "RechunkState - exact multiple" begin
        # When input is exact multiple of output, no remainder
        state = RechunkState{Int}(100, 1, 5)

        input = FixedSizeMatrixDefault{Int}(fill(42, 500, 1))
        results = rechunk!(state, input)

        @test length(results) == 5
        @test state.chunk_filled == 0
    end

    @testset "RechunkState - get_partial_buffer" begin
        state = RechunkState{Float64}(100, 2, 5)

        # No partial data initially
        @test get_partial_buffer(state) === nothing

        # Add partial data
        input = FixedSizeMatrixDefault{Float64}(fill(1.0, 50, 2))
        rechunk!(state, input)  # Should not yield any complete chunks

        partial = get_partial_buffer(state)
        @test partial !== nothing
        buffer, n_samples = partial
        @test n_samples == 50
        @test size(buffer) == (100, 2)
        @test all(buffer[1:50, :] .== 1.0)
    end

    @testset "RechunkState - reset!" begin
        state = RechunkState{Float64}(100, 2, 5)

        # Add some partial data
        input = FixedSizeMatrixDefault{Float64}(fill(1.0, 75, 2))
        rechunk!(state, input)
        @test state.chunk_filled == 75
        @test state.buffer_idx == 1

        # Reset
        reset!(state)
        @test state.chunk_filled == 0
        @test state.buffer_idx == 1
        @test get_partial_buffer(state) === nothing
    end

    @testset "RechunkState - buffer pool cycling" begin
        # Test that buffer pool cycles correctly
        # Note: RechunkState returns references to pooled buffers, so we must copy
        # the data immediately to avoid aliasing when buffers get reused.
        state = RechunkState{Int}(10, 1, 3; max_outputs_per_input=1)

        # Push enough data to cycle through all buffers multiple times
        # Copy data immediately since buffers are pooled and will be reused
        all_values = Vector{Int}[]
        for i in 1:20
            input = FixedSizeMatrixDefault{Int}(fill(i, 10, 1))
            for chunk in rechunk!(state, input)
                push!(all_values, copy(vec(chunk[:, 1])))
            end
        end

        @test length(all_values) == 20

        # Each output should have the correct value
        for (i, values) in enumerate(all_values)
            @test all(values .== i)
        end
    end

    @testset "RechunkState - data integrity across multiple calls" begin
        state = RechunkState{Float64}(100, 2, 10)

        # Create inputs with sequential values
        inputs = [FixedSizeMatrixDefault{Float64}(fill(Float64(i), 37, 2)) for i in 1:10]

        all_outputs = FixedSizeMatrixDefault{Float64}[]
        for input in inputs
            for output in rechunk!(state, input)
                push!(all_outputs, copy(output))
            end
        end

        # Total input: 10 × 37 = 370 samples
        # Complete outputs: 3 × 100 = 300 samples
        @test length(all_outputs) == 3
        @test state.chunk_filled == 70  # 370 - 300 = 70

        # Verify data integrity by flattening
        output_flat = vcat([vec(o[:, 1]) for o in all_outputs]...)
        expected = Float64[]
        for i in 1:10
            append!(expected, fill(Float64(i), 37))
        end

        @test output_flat == expected[1:300]
    end

    @testset "RechunkState - view interface" begin
        state = RechunkState{Float32}(50, 1, 5; max_outputs_per_input=3)
        input = FixedSizeMatrixDefault{Float32}(fill(1.0f0, 125, 1))

        # rechunk! returns a view
        outputs = rechunk!(state, input)
        @test outputs isa SubArray
        @test length(outputs) == 2  # 125 / 50 = 2 complete
        @test state.chunk_filled == 25

        # Test iteration
        count = 0
        for chunk in outputs
            count += 1
            @test size(chunk) == (50, 1)
        end
        @test count == 2
    end

    @testset "rechunk! - zero-copy passthrough" begin
        # When input exactly matches output size and no partial data is buffered,
        # the input should be returned directly without copying
        state = RechunkState{Float64}(100, 2, 5)

        input = FixedSizeMatrixDefault{Float64}(fill(1.0, 100, 2))
        results = rechunk!(state, input)

        @test length(results) == 1
        @test results[1] === input  # Same object, not a copy
        @test state.chunk_filled == 0  # No partial data buffered
    end

    @testset "rechunk! - no passthrough with partial data" begin
        # When partial data is already buffered, passthrough should not occur
        state = RechunkState{Float64}(100, 2, 5)

        # First, add some partial data
        partial_input = FixedSizeMatrixDefault{Float64}(fill(1.0, 50, 2))
        rechunk!(state, partial_input)
        @test state.chunk_filled == 50

        # Now add input that matches output size - should NOT passthrough
        # because there's partial data buffered
        input = FixedSizeMatrixDefault{Float64}(fill(2.0, 100, 2))
        results = rechunk!(state, input)

        @test length(results) == 1
        @test results[1] !== input  # Different object (from buffer pool)
        @test state.chunk_filled == 50  # 50 remaining from second input

        # Verify data integrity: first 50 samples from partial, next 50 from input
        @test all(results[1][1:50, :] .== 1.0)
        @test all(results[1][51:100, :] .== 2.0)
    end

    @testset "rechunk! - batch version" begin
        # Test batch rechunk! that processes multiple inputs at once
        state = RechunkState{Float64}(100, 2, 10; max_outputs_per_input=5)

        # Create batch of 4 inputs, each with 37 samples
        inputs = [FixedSizeMatrixDefault{Float64}(fill(Float64(i), 37, 2)) for i in 1:4]

        # Process all 4 inputs at once
        results = rechunk!(state, inputs)

        # Total: 4 × 37 = 148 samples → 1 complete chunk of 100, 48 remaining
        @test length(results) == 1
        @test state.chunk_filled == 48

        # Verify data integrity
        @test all(results[1][1:37, :] .== 1.0)
        @test all(results[1][38:74, :] .== 2.0)
        @test all(results[1][75:100, :] .== 3.0)
    end

    @testset "rechunk! - batch with view" begin
        # Test batch rechunk! with a view (simulates pre-allocated buffer with partial fill)
        state = RechunkState{Float64}(50, 1, 10; max_outputs_per_input=5)

        # Create batch of 4 inputs, but only process first 2 via view
        inputs = [FixedSizeMatrixDefault{Float64}(fill(Float64(i), 30, 1)) for i in 1:4]

        results = rechunk!(state, @view inputs[1:2])

        # Only first 2 inputs processed: 2 × 30 = 60 samples → 1 complete chunk, 10 remaining
        @test length(results) == 1
        @test state.chunk_filled == 10
        @test all(results[1][1:30, :] .== 1.0)
        @test all(results[1][31:50, :] .== 2.0)
    end

    @testset "rechunk! - batch zero-copy passthrough" begin
        # Test that passthrough works correctly in batch mode
        state = RechunkState{Float64}(100, 2, 10; max_outputs_per_input=5)

        # Create inputs that exactly match output size
        inputs = [FixedSizeMatrixDefault{Float64}(fill(Float64(i), 100, 2)) for i in 1:3]

        results = rechunk!(state, inputs)

        # All 3 should pass through directly
        @test length(results) == 3
        @test state.chunk_filled == 0
        # Verify zero-copy: same objects
        @test results[1] === inputs[1]
        @test results[2] === inputs[2]
        @test results[3] === inputs[3]
    end

    @testset "rechunk channel - upsampling" begin
        # Convert 100-sample chunks to 250-sample chunks
        input_chan = SignalChannel{ComplexF32,2}(100)
        output_chan = rechunk(input_chan, 250)

        task = @async begin
            for i in 1:5
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 100, 2))
                put!(input_chan, data)
            end
            close(input_chan)
        end

        results = []
        for data in output_chan
            @test size(data) == (250, 2)
            push!(results, data)
        end

        wait(task)
        # 5 chunks of 100 samples = 500 samples total
        # 500 samples / 250 per chunk = 2 output chunks
        @test length(results) == 2

        # First chunk should have values from chunks 1 and 2, plus part of 3
        @test all(results[1][1:100, :] .== ComplexF32(1, 0))
        @test all(results[1][101:200, :] .== ComplexF32(2, 0))
        @test all(results[1][201:250, :] .== ComplexF32(3, 0))
    end

    @testset "rechunk channel - downsampling" begin
        # Convert 1000-sample chunks to 300-sample chunks
        input_chan = SignalChannel{ComplexF32,2}(1000)
        output_chan = rechunk(input_chan, 300)

        task = @async begin
            for i in 1:2
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 1000, 2))
                put!(input_chan, data)
            end
            close(input_chan)
        end

        results = []
        for data in output_chan
            @test size(data) == (300, 2)
            push!(results, data)
        end

        wait(task)
        # 2 chunks of 1000 samples = 2000 samples total
        # 2000 samples / 300 per chunk = 6 output chunks (with some remainder)
        @test length(results) == 6
    end

    @testset "rechunk channel - preserves data" begin
        input_chan = SignalChannel{Float64,1}(10)
        output_chan = rechunk(input_chan, 25)

        # Send exactly 50 samples (should produce 2 chunks of 25)
        task = @async begin
            for i in 1:5
                data = FixedSizeMatrixDefault{Float64}(fill(Float64(i), 10, 1))
                put!(input_chan, data)
            end
            close(input_chan)
        end

        all_data = Float64[]
        for data in output_chan
            append!(all_data, data[:, 1])
        end

        wait(task)
        @test length(all_data) == 50
        @test all_data[1:10] == fill(1.0, 10)
        @test all_data[11:20] == fill(2.0, 10)
        @test all_data[21:30] == fill(3.0, 10)
        @test all_data[31:40] == fill(4.0, 10)
        @test all_data[41:50] == fill(5.0, 10)
    end

    @testset "rechunk channel - buffer pool integrity" begin
        # This test verifies that the buffer pool doesn't have aliasing issues.
        # With channel_size=16, we have 18 buffers. Push enough data to cycle
        # through the buffer pool multiple times to catch any aliasing bugs.
        #
        # The bug scenario: if we only had channel_size + 1 buffers, then when
        # the channel is full and the consumer is slow, we could overwrite a
        # buffer that's still being read.

        num_samples = 20000
        num_chunks = 100  # Enough to cycle buffer pool many times
        channel_size = 16

        # Create data with unique values so we can detect corruption
        all_original = [FixedSizeMatrixDefault{ComplexF32}(ComplexF32.(i .+ (1:num_samples) ./ num_samples, 0) |> x -> reshape(x, :, 1)) for i in 1:num_chunks]

        input = SignalChannel{ComplexF32,1}(num_samples, channel_size)
        intermediate = rechunk(input, 2048, channel_size)
        output = rechunk(intermediate, num_samples, channel_size)

        producer = Threads.@spawn begin
            for data in all_original
                put!(input, data)
            end
            close(input)
        end
        bind(input, producer)

        # Collect results
        results = Vector{Matrix{ComplexF32}}()
        for chunk in output
            push!(results, Matrix(chunk))
        end

        wait(producer)

        # Flatten and compare
        original_flat = vcat([vec(d) for d in all_original]...)
        result_flat = vcat([vec(r) for r in results]...)

        # We expect some sample loss due to incomplete final chunks, but what
        # we do get should match exactly
        compare_length = length(result_flat)
        @test compare_length > 0
        @test original_flat[1:compare_length] == result_flat
    end
end

end # module RechunkTest
