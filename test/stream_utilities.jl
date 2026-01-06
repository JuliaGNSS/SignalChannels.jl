module StreamUtilitiesTest

using Test: @test, @testset
using SignalChannels: SignalChannel, PipeChannel, spawn_signal_channel_thread, membuffer, num_antenna_channels
using FixedSizeArrays: FixedSizeMatrixDefault

@testset "Stream Utilities" begin
    @testset "spawn_signal_channel_thread with SignalChannel" begin
        chan = spawn_signal_channel_thread(T=ComplexF32, num_samples=100, num_antenna_channels=2) do out
            for i in 1:3
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 100, 2))
                put!(out, data)
            end
        end

        @test chan isa SignalChannel{ComplexF32,2}
        @test chan.num_samples == 100
        @test num_antenna_channels(chan) == 2

        results = []
        for data in chan
            push!(results, data[1, 1])
        end

        @test results == [ComplexF32(1, 0), ComplexF32(2, 0), ComplexF32(3, 0)]
    end

    @testset "spawn_signal_channel_thread closes on completion" begin
        chan = spawn_signal_channel_thread(T=Float64, num_samples=50, num_antenna_channels=1) do out
            data = FixedSizeMatrixDefault{Float64}(fill(1.0, 50, 1))
            put!(out, data)
        end

        # Consume the channel
        take!(chan)

        # Give it a moment to close
        sleep(0.1)
        @test !isopen(chan)
    end

    @testset "spawn_signal_channel_thread closes on error" begin
        chan = spawn_signal_channel_thread(T=Float64, num_samples=50, num_antenna_channels=1) do out
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
        input_chan = SignalChannel{ComplexF32,2}(100)
        buffered_chan = membuffer(input_chan, 10)

        @test buffered_chan isa SignalChannel{ComplexF32,2}
        @test buffered_chan.num_samples == 100
        @test num_antenna_channels(buffered_chan) == 2

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
        input_chan = SignalChannel{Float64,1}(50)
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

    @testset "membuffer with generic PipeChannel" begin
        input_chan = PipeChannel{Int}(16)
        buffered_chan = membuffer(input_chan, 10)

        task = @async begin
            for i in 1:20
                put!(input_chan, i)
            end
            close(input_chan)
        end

        results = []
        for data in buffered_chan
            push!(results, data)
        end

        wait(task)
        @test results == collect(1:20)
        @test length(results) == 20
    end
end

end # module StreamUtilitiesTest
