module StreamUtilitiesTest

using Test: @test, @testset
using SignalChannels: SignalChannel, spawn_channel_thread, membuffer, generate_stream
using FixedSizeArrays: FixedSizeMatrixDefault

@testset "Stream Utilities" begin
    @testset "spawn_channel_thread with SignalChannel" begin
        chan = spawn_channel_thread(T=ComplexF32, num_samples=100, num_antenna_channels=2) do out
            for i in 1:3
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 100, 2))
                put!(out, data)
            end
        end

        @test chan isa SignalChannel{ComplexF32}
        @test chan.num_samples == 100
        @test chan.num_antenna_channels == 2

        results = []
        for data in chan
            push!(results, data[1, 1])
        end

        @test results == [ComplexF32(1, 0), ComplexF32(2, 0), ComplexF32(3, 0)]
    end

    @testset "spawn_channel_thread closes on completion" begin
        chan = spawn_channel_thread(T=Float64, num_samples=50, num_antenna_channels=1) do out
            data = FixedSizeMatrixDefault{Float64}(fill(1.0, 50, 1))
            put!(out, data)
        end

        # Consume the channel
        take!(chan)

        # Give it a moment to close
        sleep(0.1)
        @test !isopen(chan)
    end

    @testset "spawn_channel_thread closes on error" begin
        chan = spawn_channel_thread(T=Float64, num_samples=50, num_antenna_channels=1) do out
            data = FixedSizeMatrixDefault{Float64}(fill(1.0, 50, 1))
            put!(out, data)
            error("Intentional error")
        end

        # Consume the one successful put
        take!(chan)

        # Give it a moment to close after error
        sleep(0.1)
        @test !isopen(chan)
    end

    @testset "membuffer" begin
        input_chan = SignalChannel{ComplexF32}(100, 2)
        buffered_chan = membuffer(input_chan, 10)

        @test buffered_chan isa SignalChannel{ComplexF32}
        @test buffered_chan.num_samples == 100
        @test buffered_chan.num_antenna_channels == 2

        task = @async begin
            for i in 1:5
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 100, 2))
                put!(input_chan, data)
            end
            close(input_chan)
        end

        results = []
        for data in buffered_chan
            push!(results, data[1, 1])
        end

        wait(task)
        @test results == [ComplexF32(1, 0), ComplexF32(2, 0), ComplexF32(3, 0), ComplexF32(4, 0), ComplexF32(5, 0)]
    end

    @testset "membuffer with large buffer size" begin
        input_chan = SignalChannel{Float64}(50, 1)
        buffered_chan = membuffer(input_chan, 100)

        # Quickly put many items
        task = @async begin
            for i in 1:50
                data = FixedSizeMatrixDefault{Float64}(fill(Float64(i), 50, 1))
                put!(input_chan, data)
            end
            close(input_chan)
        end

        # Slowly consume
        count = 0
        for data in buffered_chan
            count += 1
            sleep(0.001)  # Slow consumer
        end

        wait(task)
        @test count == 50
    end

    @testset "generate_stream basic" begin
        counter = Ref(0)
        chan = generate_stream(100, 2; T=ComplexF32) do buff
            counter[] += 1
            buff .= ComplexF32(counter[], 0)
            return counter[] < 5  # Generate 4 buffers
        end

        @test chan isa SignalChannel{ComplexF32}
        @test chan.num_samples == 100
        @test chan.num_antenna_channels == 2

        results = []
        for data in chan
            push!(results, data[1, 1])
        end

        @test results == [ComplexF32(1, 0), ComplexF32(2, 0), ComplexF32(3, 0), ComplexF32(4, 0)]
    end

    @testset "generate_stream with wrapper" begin
        setup_called = Ref(false)
        teardown_called = Ref(false)

        wrapper = function(f)
            setup_called[] = true
            result = f()
            teardown_called[] = true
            return result
        end

        counter = Ref(0)
        chan = generate_stream(50, 1; T=Float64, wrapper=wrapper) do buff
            counter[] += 1
            buff .= Float64(counter[])
            return counter[] < 3
        end

        results = []
        for data in chan
            push!(results, data[1, 1])
        end

        @test setup_called[]
        @test teardown_called[]
        @test length(results) == 2
    end

    @testset "generate_stream stops when function returns false" begin
        counter = Ref(0)
        results = []
        chan = generate_stream(10, 1; T=Float64) do buff
            counter[] += 1
            buff .= Float64(counter[])
            return counter[] < 100  # Would generate many, but we'll break early
        end

        # Only take 3 items then close
        for (idx, data) in enumerate(chan)
            push!(results, data[1, 1])
            if idx == 3
                close(chan)
                break
            end
        end

        # Wait a moment for background task to finish
        sleep(0.2)

        @test length(results) == 3
        @test results == [1.0, 2.0, 3.0]
    end

    @testset "generate_stream with multiple buffers in flight" begin
        counter = Ref(0)
        chan = generate_stream(100, 2; T=ComplexF32, buffers_in_flight=5) do buff
            counter[] += 1
            buff .= ComplexF32(counter[], 0)
            return counter[] < 10
        end

        results = []
        for data in chan
            push!(results, data[1, 1])
        end

        @test length(results) == 9
        @test results[1] == ComplexF32(1, 0)
        @test results[end] == ComplexF32(9, 0)
    end

    @testset "generate_stream data independence" begin
        # Test that copying buffer works correctly
        chan = generate_stream(5, 1; T=Float64) do buff
            buff .= rand(5)
            return true
        end

        data1 = take!(chan)
        data2 = take!(chan)

        # Data should be different (with very high probability)
        @test data1 != data2

        close(chan)

        # Wait a moment for background task to finish
        sleep(0.2)
    end
end

end # module StreamUtilitiesTest
