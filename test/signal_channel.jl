module MatrixChannelTest

using Test: @test, @testset, @test_throws
using SignalChannels: SignalChannel
using FixedSizeArrays: FixedSizeMatrixDefault

@testset "SignalChannel" begin
    @testset "Construction" begin
        chan = SignalChannel{ComplexF32}(1024, 4)
        @test chan.num_samples == 1024
        @test chan.num_antenna_channels == 4
        @test isopen(chan)
    end

    @testset "Construction with buffer size" begin
        chan = SignalChannel{ComplexF32}(512, 2, 10)
        @test chan.num_samples == 512
        @test chan.num_antenna_channels == 2
        @test isopen(chan)
    end

    @testset "Put and take with correct dimensions" begin
        chan = SignalChannel{ComplexF32}(1024, 4)
        data = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 1024, 4))

        @async put!(chan, data)
        received = take!(chan)

        @test size(received) == (1024, 4)
        @test received == data
    end

    @testset "Put with incorrect dimensions throws error" begin
        chan = SignalChannel{ComplexF32}(1024, 4)
        wrong_data = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 512, 4))  # Wrong number of samples

        @test_throws ArgumentError put!(chan, wrong_data)

        wrong_data2 = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 1024, 2))  # Wrong number of channels
        @test_throws ArgumentError put!(chan, wrong_data2)
    end

    @testset "Channel state operations" begin
        chan = SignalChannel{ComplexF32}(1024, 4, 1)  # Buffer size of 1
        @test isopen(chan)
        @test isempty(chan)
        @test !isready(chan)

        data = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 1024, 4))
        put!(chan, data)

        @test isready(chan)
        @test !isempty(chan)

        close(chan)
        @test !isopen(chan)
    end

    @testset "Construction with function" begin
        chan = SignalChannel{ComplexF32}(1024, 4, 5) do c
            for i in 1:3
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 1024, 4))
                put!(c, data)
            end
        end

        result1 = take!(chan)
        @test all(result1 .== ComplexF32(1, 0))

        result2 = take!(chan)
        @test all(result2 .== ComplexF32(2, 0))

        result3 = take!(chan)
        @test all(result3 .== ComplexF32(3, 0))
    end

    @testset "Iteration" begin
        chan = SignalChannel{ComplexF32}(1024, 4, 5) do c
            for i in 1:3
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 1024, 4))
                put!(c, data)
            end
        end

        count = 0
        for data in chan
            count += 1
            @test size(data) == (1024, 4)
        end
        @test count == 3
    end

    @testset "Multiple put/take operations" begin
        chan = SignalChannel{Float64}(100, 2, 3)

        task = @async begin
            for i in 1:5
                data = FixedSizeMatrixDefault{Float64}(fill(Float64(i), 100, 2))
                put!(chan, data)
            end
            close(chan)
        end

        results = []
        for data in chan
            push!(results, data[1, 1])
        end

        @test results == [1.0, 2.0, 3.0, 4.0, 5.0]
        wait(task)
    end

    @testset "eltype" begin
        chan_f32 = SignalChannel{ComplexF32}(1024, 4)
        @test eltype(chan_f32) == FixedSizeMatrixDefault{ComplexF32}

        chan_f64 = SignalChannel{Float64}(512, 2)
        @test eltype(chan_f64) == FixedSizeMatrixDefault{Float64}

        # Test single channel
        chan_single = SignalChannel{ComplexF32}(1024)
        @test eltype(chan_single) == FixedSizeMatrixDefault{ComplexF32}
    end

    @testset "Single channel with matrices" begin
        chan = SignalChannel{ComplexF32}(1024)
        @test chan.num_samples == 1024
        @test chan.num_antenna_channels == 1
        @test isopen(chan)

        # Put and take matrix with shape (1024, 1)
        data = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 1024, 1))
        @async put!(chan, data)
        received = take!(chan)

        @test received isa FixedSizeMatrixDefault{ComplexF32}
        @test size(received) == (1024, 1)
        @test received == data
    end

    @testset "Single channel with function constructor" begin
        chan = SignalChannel{ComplexF32}(1024) do c
            for i in 1:3
                data = FixedSizeMatrixDefault{ComplexF32}(fill(ComplexF32(i, 0), 1024, 1))
                put!(c, data)
            end
        end

        result1 = take!(chan)
        @test result1 isa FixedSizeMatrixDefault{ComplexF32}
        @test size(result1) == (1024, 1)
        @test all(result1 .== ComplexF32(1, 0))

        result2 = take!(chan)
        @test all(result2 .== ComplexF32(2, 0))

        result3 = take!(chan)
        @test all(result3 .== ComplexF32(3, 0))
    end
end

end # module MatrixChannelTest
