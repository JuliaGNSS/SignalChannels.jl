module ChannelUtilitiesTest

using Test: @test, @testset, @test_throws
using SignalChannels: SignalChannel, PipeChannel, consume_channel, tee, write_to_file, read_from_file
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
        chan = SignalChannel{ComplexF32,2}(100)
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
        input_chan = SignalChannel{ComplexF32,2}(100)
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

    @testset "write_to_file" begin
        mktempdir() do tmpdir
            input_chan = SignalChannel{ComplexF32,3}(100, 10)  # Buffer size to prevent blocking
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
            input_chan = SignalChannel{Float64,2}(50, 10)  # Buffer size to prevent blocking
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
            input_chan = SignalChannel{ComplexF32,3}(100, 10)
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
            input_chan = SignalChannel{Float64,2}(100, 10)
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

        input_chan = SignalChannel{ComplexF32,2}(100)
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
end

end # module ChannelUtilitiesTest
