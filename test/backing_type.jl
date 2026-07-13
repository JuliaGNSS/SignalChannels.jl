module BackingTypeTest

using Test: @test, @testset
using SignalChannels: SignalChannel, rechunk, mux, add, num_antenna_channels
using FixedSizeArrays: FixedSizeMatrixDefault

const FSM = FixedSizeMatrixDefault

@testset "Backing matrix type parameter" begin
    @testset "Default backing type is Matrix" begin
        chan = SignalChannel{ComplexF32,4}(1024)
        @test eltype(chan) == Matrix{ComplexF32}

        single = SignalChannel{ComplexF32}(1024)
        @test eltype(single) == Matrix{ComplexF32}
    end

    @testset "Opt-in FixedSizeArrays backing" begin
        chan = SignalChannel{ComplexF32,4,FSM{ComplexF32}}(1024)
        @test eltype(chan) == FSM{ComplexF32}
        @test num_antenna_channels(chan) == 4

        data = FSM{ComplexF32}(rand(ComplexF32, 1024, 4))
        @async put!(chan, data)
        received = take!(chan)
        @test received isa FSM{ComplexF32}
        @test received == data
    end

    @testset "put! converts a plain matrix into the backing type" begin
        # A FixedSizeArrays-backed channel accepts a plain Matrix and stores it
        # as the backing type via convert.
        chan = SignalChannel{Float64,1,FSM{Float64}}(50, 4)
        @async put!(chan, fill(1.5, 50, 1))  # plain Matrix
        received = take!(chan)
        @test received isa FSM{Float64}
        @test all(received .== 1.5)
    end

    @testset "similar preserves backing type" begin
        chan = SignalChannel{ComplexF32,2,FSM{ComplexF32}}(256, 8)
        s = similar(chan)
        @test eltype(s) == FSM{ComplexF32}
        @test s.num_samples == 256
    end

    @testset "rechunk preserves backing type" begin
        src = SignalChannel{ComplexF32,1,FSM{ComplexF32}}(512, 100) do ch
            for i in 1:4
                put!(ch, FSM{ComplexF32}(fill(ComplexF32(i, 0), 512, 1)))
            end
        end
        out = rechunk(src, 1024)
        @test eltype(out) == FSM{ComplexF32}
        buf = take!(out)
        @test buf isa FSM{ComplexF32}
        @test size(buf) == (1024, 1)
    end

    @testset "add/mux preserve backing type" begin
        mk() = SignalChannel{Float64,1,FSM{Float64}}(10, 5)
        @test eltype(add(mk(), mk())) == FSM{Float64}
        @test eltype(mux(mk(), mk())) == FSM{Float64}
    end
end

end # module BackingTypeTest
