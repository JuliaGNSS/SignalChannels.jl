module ChannelUtilitiesTest

using Test: @test, @testset, @test_throws
using SignalChannels: SignalChannel, PipeChannel, consume_channel, tee, rechunk, write_to_file, read_from_file
using FixedSizeArrays: FixedSizeMatrixDefault

@testset "Channel Utilities" begin
    @testset "consume_channel" begin
        chan = PipeChannel{Int}(10)
        results = Int[]

        task = @async begin
            for i in 1:5
                put!(chan, i)
            end
            close(chan)
        end

        consume_channel(chan) do data
            push!(results, data)
        end

        wait(task)
        @test results == [1, 2, 3, 4, 5]
    end

    @testset "consume_channel with SignalChannel" begin
        chan = SignalChannel{ComplexF32}(100, 2)
        results = []

        task = @async begin
            for i in 1:3
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 100, 2))
                put!(chan, data)
            end
            close(chan)
        end

        consume_channel(chan) do data
            push!(results, data[1, 1])
        end

        wait(task)
        @test results == [ComplexF32(1, 0), ComplexF32(2, 0), ComplexF32(3, 0)]
    end

    @testset "tee" begin
        input_chan = SignalChannel{ComplexF32}(100, 2)
        out1, out2 = tee(input_chan)

        task = @async begin
            for i in 1:3
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 100, 2))
                put!(input_chan, data)
            end
            close(input_chan)
        end

        results1 = []
        results2 = []

        # Consume both channels concurrently to avoid deadlock
        task1 = @async begin
            for data in out1
                push!(results1, data[1, 1])
            end
        end

        task2 = @async begin
            for data in out2
                push!(results2, data[1, 1])
            end
        end

        wait(task)
        wait(task1)
        wait(task2)
        @test results1 == [ComplexF32(1, 0), ComplexF32(2, 0), ComplexF32(3, 0)]
        @test results2 == [ComplexF32(1, 0), ComplexF32(2, 0), ComplexF32(3, 0)]
    end

    @testset "tee with generic PipeChannel" begin
        input_chan = PipeChannel{Int}(10)
        out1, out2 = tee(input_chan)

        task = @async begin
            for i in 1:5
                put!(input_chan, i)
            end
            close(input_chan)
        end

        results1 = []
        results2 = []

        # Consume both channels concurrently
        task1 = @async begin
            for data in out1
                push!(results1, data)
            end
        end

        task2 = @async begin
            for data in out2
                push!(results2, data)
            end
        end

        wait(task)
        wait(task1)
        wait(task2)
        @test results1 == [1, 2, 3, 4, 5]
        @test results2 == [1, 2, 3, 4, 5]
    end

    @testset "rechunk - upsampling" begin
        # Convert 100-sample chunks to 250-sample chunks
        input_chan = SignalChannel{ComplexF32}(100, 2)
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

    @testset "rechunk - downsampling" begin
        # Convert 1000-sample chunks to 300-sample chunks
        input_chan = SignalChannel{ComplexF32}(1000, 2)
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

    @testset "rechunk preserves data" begin
        input_chan = SignalChannel{Float64}(10, 1)
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

    @testset "write_to_file" begin
        mktempdir() do tmpdir
            input_chan = SignalChannel{ComplexF32}(100, 3, 10)  # Buffer size to prevent blocking
            filepath = joinpath(tmpdir, "test_data")

            task = @async begin
                for i in 1:5
                    data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, i), 100, 3))
                    put!(input_chan, data)
                end
                close(input_chan)
            end

            write_task = write_to_file(input_chan, filepath)
            wait(write_task)
            wait(task)

            # Check that files were created
            @test isfile(filepath * "ComplexF321.dat")
            @test isfile(filepath * "ComplexF322.dat")
            @test isfile(filepath * "ComplexF323.dat")

            # Verify file contents
            for channel_idx in 1:3
                data = read(filepath * "ComplexF32$(channel_idx).dat")
                values = reinterpret(ComplexF32, data)
                @test length(values) == 500  # 5 chunks × 100 samples
                @test values[1] == ComplexF32(1, 1)
                @test values[100] == ComplexF32(1, 1)
                @test values[101] == ComplexF32(2, 2)
            end
        end
    end

    @testset "write_to_file with different types" begin
        mktempdir() do tmpdir
            input_chan = SignalChannel{Float64}(50, 2, 10)  # Buffer size to prevent blocking
            filepath = joinpath(tmpdir, "float_data")

            task = @async begin
                for i in 1:3
                    data = FixedSizeMatrixDefault{Float64}(fill(Float64(i * 10), 50, 2))
                    put!(input_chan, data)
                end
                close(input_chan)
            end

            write_task = write_to_file(input_chan, filepath)
            wait(write_task)
            wait(task)

            @test isfile(filepath * "Float641.dat")
            @test isfile(filepath * "Float642.dat")

            for channel_idx in 1:2
                data = read(filepath * "Float64$(channel_idx).dat")
                values = reinterpret(Float64, data)
                @test length(values) == 150  # 3 chunks × 50 samples
            end
        end
    end

    @testset "read_from_file" begin
        mktempdir() do tmpdir
            # First write some data
            input_chan = SignalChannel{ComplexF32}(100, 3, 10)
            filepath = joinpath(tmpdir, "test_read")

            task = @async begin
                for i in 1:5
                    data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, i), 100, 3))
                    put!(input_chan, data)
                end
                close(input_chan)
            end

            write_task = write_to_file(input_chan, filepath)
            wait(write_task)
            wait(task)

            # Now read it back
            output_chan = read_from_file(filepath, 100, 3; T=ComplexF32)

            results = collect(output_chan)

            @test length(results) == 5
            @test size(results[1]) == (100, 3)
            @test results[1][1, 1] == ComplexF32(1, 1)
            @test results[5][1, 1] == ComplexF32(5, 5)
        end
    end

    @testset "read_from_file with different chunk size" begin
        mktempdir() do tmpdir
            # Write with one chunk size
            input_chan = SignalChannel{Float64}(100, 2, 10)
            filepath = joinpath(tmpdir, "test_rechunk")

            task = @async begin
                for i in 1:5
                    data = FixedSizeMatrixDefault{Float64}(fill(Float64(i), 100, 2))
                    put!(input_chan, data)
                end
                close(input_chan)
            end

            write_task = write_to_file(input_chan, filepath)
            wait(write_task)
            wait(task)

            # Read back with different chunk size
            output_chan = read_from_file(filepath, 50, 2; T=Float64)

            results = collect(output_chan)

            # 5 chunks × 100 samples = 500 samples total
            # 500 samples / 50 per chunk = 10 output chunks
            @test length(results) == 10
            @test size(results[1]) == (50, 2)
        end
    end

    @testset "read_from_file error handling" begin
        mktempdir() do tmpdir
            filepath = joinpath(tmpdir, "nonexistent")

            # Should error when files don't exist
            @test_throws ErrorException read_from_file(filepath, 100, 2; T=ComplexF32)
        end
    end

    @testset "processing task error propagates to upstream" begin
        # When a processing task (like rechunk) throws an error, it should propagate
        # back to close the upstream channel via bind()
        #
        # Architecture:
        #   Producer → input_chan → [rechunk task] → output_chan → Consumer
        #                 ↑              ↓               ↓
        #              bind(in,task)  bind(out,task)
        #
        # If rechunk task fails, both input_chan and output_chan should close.

        input_chan = SignalChannel{ComplexF32}(100, 2)
        tee_out1, tee_out2 = tee(input_chan)

        # Close one of the tee outputs early - this will cause the tee task to fail
        # when it tries to put! to the closed channel
        close(tee_out1)

        # Producer that tries to put data
        producer_task = Threads.@spawn begin
            for i in 1:100
                put!(input_chan, FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 100, 2)))
            end
            close(input_chan)
        end

        # Give time for the error to propagate
        sleep(0.2)

        # The input channel should be closed due to bind propagation
        # (tee task failed → input_chan closed via bind)
        @test !isopen(input_chan)

        # The other tee output should also be closed
        @test !isopen(tee_out2)

        # The producer should fail when trying to put to the closed channel
        @test_throws Exception wait(producer_task)
    end

    @testset "rechunk buffer pool integrity" begin
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

        input = SignalChannel{ComplexF32}(num_samples, 1, channel_size)
        intermediate = rechunk(input, 2048, channel_size)
        output = rechunk(intermediate, num_samples, channel_size)

        producer = Threads.@spawn begin
            for data in all_original
                put!(input, data)
            end
            close(input)
        end
        bind(input, producer)  # Propagate errors from producer to close the channel

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

end # module ChannelUtilitiesTest
