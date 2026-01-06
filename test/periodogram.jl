module PeriodogramTest

using Test: @test, @testset, @test_throws
using SignalChannels: SignalChannel, PeriodogramData, calculate_periodogram, periodogram_liveplot
using FixedSizeArrays: FixedSizeMatrixDefault
using Unitful
using DSP

@testset "PeriodogramData" begin
    @testset "Construction" begin
        freqs = [1.0, 2.0, 3.0]
        powers = [10.0, 20.0, 30.0]
        timestamp = 1.5

        pgram = PeriodogramData(freqs, powers, timestamp)

        @test pgram.freqs == freqs
        @test pgram.powers == powers
        @test pgram.timestamp == timestamp
    end
end

@testset "calculate_periodogram" begin
    @testset "Basic functionality" begin
        data_chan = SignalChannel{ComplexF32,1}(1024, 10)
        sampling_freq = 1u"MHz"
        pgram_chan = calculate_periodogram(data_chan, sampling_freq; push_roughly_every=10u"ms")

        task = @async begin
            for i in 1:3
                data = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 1024, 1))
                put!(data_chan, data)
            end
            close(data_chan)
        end

        results = collect(pgram_chan)
        wait(task)

        @test length(results) > 0
        @test results[1] isa PeriodogramData
        @test length(results[1].freqs) == length(results[1].powers)
    end

    @testset "Multi-channel input" begin
        data_chan = SignalChannel{ComplexF32,4}(512, 10)
        sampling_freq = 2u"MHz"
        pgram_chan = calculate_periodogram(data_chan, sampling_freq)

        task = @async begin
            for i in 1:2
                data = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 512, 4))
                put!(data_chan, data)
            end
            close(data_chan)
        end

        results = collect(pgram_chan)
        wait(task)
        @test length(results) > 0
    end

    @testset "Channel closes properly" begin
        data_chan = SignalChannel{ComplexF32,1}(512, 5)
        sampling_freq = 1u"MHz"
        pgram_chan = calculate_periodogram(data_chan, sampling_freq)

        task = @async begin
            for i in 1:2
                data = FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 512, 1))
                put!(data_chan, data)
            end
            close(data_chan)
        end

        results = collect(pgram_chan)
        wait(task)
        @test !isopen(pgram_chan)
    end
end

end # module PeriodogramTest
