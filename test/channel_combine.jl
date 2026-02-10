module ChannelCombineTest

using Test: @test, @testset, @test_throws
using SignalChannels: SignalChannel, mux, add
using FixedSizeArrays: FixedSizeMatrixDefault

@testset "Channel Combine" begin
    @testset "mux" begin
        @testset "Basic sequential forwarding with sync" begin
            chunk_size = 100
            ch1 = SignalChannel{ComplexF32,1}(chunk_size, 10)
            ch2 = SignalChannel{ComplexF32,1}(chunk_size, 10)

            task1 = Threads.@spawn begin
                for _ = 1:3
                    chunk = FixedSizeMatrixDefault{ComplexF32}(
                        fill(ComplexF32(1.0), chunk_size, 1),
                    )
                    put!(ch1, chunk)
                end
                close(ch1)
            end

            task2 = Threads.@spawn begin
                for i = 1:5
                    chunk = FixedSizeMatrixDefault{ComplexF32}(
                        fill(ComplexF32(Float32(i)), chunk_size, 1),
                    )
                    put!(ch2, chunk)
                end
                close(ch2)
            end

            muxed = mux(ch1, ch2)
            chunks = collect(muxed)

            @test length(chunks) == 5
            @test real(chunks[1][1]) == 1.0f0
            @test real(chunks[2][1]) == 1.0f0
            @test real(chunks[3][1]) == 1.0f0
            @test real(chunks[4][1]) == 4.0f0
            @test real(chunks[5][1]) == 5.0f0
        end

        @testset "Empty ch1 - immediately forwards ch2" begin
            chunk_size = 100
            ch1 = SignalChannel{ComplexF32,1}(chunk_size, 10)
            ch2 = SignalChannel{ComplexF32,1}(chunk_size, 10)

            close(ch1)

            task2 = Threads.@spawn begin
                for _ = 1:3
                    chunk = FixedSizeMatrixDefault{ComplexF32}(
                        fill(ComplexF32(2.0), chunk_size, 1),
                    )
                    put!(ch2, chunk)
                end
                close(ch2)
            end

            muxed = mux(ch1, ch2)
            chunks = collect(muxed)

            @test length(chunks) == 3
            @test all(real(c[1]) == 2.0f0 for c in chunks)
        end

        @testset "Empty ch2 - forwards ch1 then closes" begin
            chunk_size = 100
            ch1 = SignalChannel{ComplexF32,1}(chunk_size, 10)
            ch2 = SignalChannel{ComplexF32,1}(chunk_size, 10)

            task1 = Threads.@spawn begin
                for _ = 1:3
                    chunk = FixedSizeMatrixDefault{ComplexF32}(
                        fill(ComplexF32(1.0), chunk_size, 1),
                    )
                    put!(ch1, chunk)
                end
                close(ch1)
            end

            close(ch2)

            muxed = mux(ch1, ch2)
            chunks = collect(muxed)

            @test length(chunks) == 3
            @test all(real(c[1]) == 1.0f0 for c in chunks)
        end

        @testset "Order preserved" begin
            chunk_size = 10
            ch1 = SignalChannel{ComplexF32,1}(chunk_size, 10)
            ch2 = SignalChannel{ComplexF32,1}(chunk_size, 10)

            task1 = Threads.@spawn begin
                for i = 1:3
                    chunk = FixedSizeMatrixDefault{ComplexF32}(
                        fill(ComplexF32(Float32(i)), chunk_size, 1),
                    )
                    put!(ch1, chunk)
                end
                close(ch1)
            end

            task2 = Threads.@spawn begin
                for i = 1:5
                    chunk = FixedSizeMatrixDefault{ComplexF32}(
                        fill(ComplexF32(Float32(10 + i)), chunk_size, 1),
                    )
                    put!(ch2, chunk)
                end
                close(ch2)
            end

            muxed = mux(ch1, ch2)
            chunks = collect(muxed)

            @test length(chunks) == 5
            @test real(chunks[1][1]) == 1.0f0
            @test real(chunks[2][1]) == 2.0f0
            @test real(chunks[3][1]) == 3.0f0
            @test real(chunks[4][1]) == 14.0f0
            @test real(chunks[5][1]) == 15.0f0
        end

        @testset "Works with Complex{Int16}" begin
            chunk_size = 50
            ch1 = SignalChannel{Complex{Int16},1}(chunk_size, 10)
            ch2 = SignalChannel{Complex{Int16},1}(chunk_size, 10)

            task1 = Threads.@spawn begin
                chunk = FixedSizeMatrixDefault{Complex{Int16}}(
                    fill(Complex{Int16}(100, 0), chunk_size, 1),
                )
                put!(ch1, chunk)
                close(ch1)
            end

            task2 = Threads.@spawn begin
                for i = 1:2
                    chunk = FixedSizeMatrixDefault{Complex{Int16}}(
                        fill(Complex{Int16}(100 * (i + 1), 0), chunk_size, 1),
                    )
                    put!(ch2, chunk)
                end
                close(ch2)
            end

            muxed = mux(ch1, ch2)
            chunks = collect(muxed)

            @test length(chunks) == 2
            @test real(chunks[1][1]) == Int16(100)
            @test real(chunks[2][1]) == Int16(300)
        end

        @testset "Errors on mismatched num_samples" begin
            ch1 = SignalChannel{ComplexF32,1}(100, 10)
            ch2 = SignalChannel{ComplexF32,1}(200, 10)

            @test_throws ErrorException mux(ch1, ch2)

            close(ch1)
            close(ch2)
        end

        @testset "sync=false does not consume ch2 during ch1" begin
            chunk_size = 100
            ch1 = SignalChannel{ComplexF32,1}(chunk_size, 10)
            ch2 = SignalChannel{ComplexF32,1}(chunk_size, 10)

            task1 = Threads.@spawn begin
                for _ = 1:3
                    chunk = FixedSizeMatrixDefault{ComplexF32}(
                        fill(ComplexF32(1.0), chunk_size, 1),
                    )
                    put!(ch1, chunk)
                end
                close(ch1)
            end

            task2 = Threads.@spawn begin
                for i = 1:5
                    chunk = FixedSizeMatrixDefault{ComplexF32}(
                        fill(ComplexF32(Float32(i)), chunk_size, 1),
                    )
                    put!(ch2, chunk)
                end
                close(ch2)
            end

            muxed = mux(ch1, ch2; sync = false)
            chunks = collect(muxed)

            # Without sync: 3 from ch1 + all 5 from ch2 = 8 total
            @test length(chunks) == 8
            # First 3 from ch1
            @test all(real(chunks[i][1]) == 1.0f0 for i = 1:3)
            # Then all 5 from ch2 (none were discarded)
            @test real(chunks[4][1]) == 1.0f0
            @test real(chunks[5][1]) == 2.0f0
            @test real(chunks[6][1]) == 3.0f0
            @test real(chunks[7][1]) == 4.0f0
            @test real(chunks[8][1]) == 5.0f0
        end
    end

    @testset "add" begin
        @testset "Basic 2-channel addition" begin
            chunk_size = 100
            ch1 = SignalChannel{ComplexF32,1}(chunk_size, 10)
            ch2 = SignalChannel{ComplexF32,1}(chunk_size, 10)

            task1 = Threads.@spawn begin
                for _ = 1:3
                    put!(
                        ch1,
                        FixedSizeMatrixDefault{ComplexF32}(
                            fill(ComplexF32(1.0), chunk_size, 1),
                        ),
                    )
                end
                close(ch1)
            end

            task2 = Threads.@spawn begin
                for _ = 1:3
                    put!(
                        ch2,
                        FixedSizeMatrixDefault{ComplexF32}(
                            fill(ComplexF32(2.0), chunk_size, 1),
                        ),
                    )
                end
                close(ch2)
            end

            added = add(ch1, ch2)
            chunks = collect(added)

            @test length(chunks) == 3
            @test all(real(c[1]) == 3.0f0 for c in chunks)
        end

        @testset "3-channel addition" begin
            chunk_size = 50
            ch1 = SignalChannel{ComplexF32,1}(chunk_size, 10)
            ch2 = SignalChannel{ComplexF32,1}(chunk_size, 10)
            ch3 = SignalChannel{ComplexF32,1}(chunk_size, 10)

            task1 = Threads.@spawn begin
                for _ = 1:2
                    put!(
                        ch1,
                        FixedSizeMatrixDefault{ComplexF32}(
                            fill(ComplexF32(1.0), chunk_size, 1),
                        ),
                    )
                end
                close(ch1)
            end

            task2 = Threads.@spawn begin
                for _ = 1:2
                    put!(
                        ch2,
                        FixedSizeMatrixDefault{ComplexF32}(
                            fill(ComplexF32(2.0), chunk_size, 1),
                        ),
                    )
                end
                close(ch2)
            end

            task3 = Threads.@spawn begin
                for _ = 1:2
                    put!(
                        ch3,
                        FixedSizeMatrixDefault{ComplexF32}(
                            fill(ComplexF32(3.0), chunk_size, 1),
                        ),
                    )
                end
                close(ch3)
            end

            added = add(ch1, ch2, ch3)
            chunks = collect(added)

            @test length(chunks) == 2
            @test all(real(c[1]) == 6.0f0 for c in chunks)
        end

        @testset "Multi-antenna channels (N=2)" begin
            chunk_size = 50
            ch1 = SignalChannel{ComplexF32,2}(chunk_size, 10)
            ch2 = SignalChannel{ComplexF32,2}(chunk_size, 10)

            task1 = Threads.@spawn begin
                for _ = 1:2
                    put!(
                        ch1,
                        FixedSizeMatrixDefault{ComplexF32}(
                            fill(ComplexF32(1.0, 0.0), chunk_size, 2),
                        ),
                    )
                end
                close(ch1)
            end

            task2 = Threads.@spawn begin
                for _ = 1:2
                    put!(
                        ch2,
                        FixedSizeMatrixDefault{ComplexF32}(
                            fill(ComplexF32(0.0, 1.0), chunk_size, 2),
                        ),
                    )
                end
                close(ch2)
            end

            added = add(ch1, ch2)
            chunks = collect(added)

            @test length(chunks) == 2
            @test all(c[1, 1] == ComplexF32(1.0, 1.0) for c in chunks)
            @test all(c[1, 2] == ComplexF32(1.0, 1.0) for c in chunks)
        end

        @testset "Works with Complex{Int16}" begin
            chunk_size = 50
            ch1 = SignalChannel{Complex{Int16},1}(chunk_size, 10)
            ch2 = SignalChannel{Complex{Int16},1}(chunk_size, 10)

            task1 = Threads.@spawn begin
                put!(
                    ch1,
                    FixedSizeMatrixDefault{Complex{Int16}}(
                        fill(Complex{Int16}(100, 0), chunk_size, 1),
                    ),
                )
                close(ch1)
            end

            task2 = Threads.@spawn begin
                put!(
                    ch2,
                    FixedSizeMatrixDefault{Complex{Int16}}(
                        fill(Complex{Int16}(200, 50), chunk_size, 1),
                    ),
                )
                close(ch2)
            end

            added = add(ch1, ch2)
            chunks = collect(added)

            @test length(chunks) == 1
            @test chunks[1][1] == Complex{Int16}(300, 50)
        end

        @testset "Errors on mismatched num_samples" begin
            ch1 = SignalChannel{ComplexF32,1}(100, 10)
            ch2 = SignalChannel{ComplexF32,1}(200, 10)

            @test_throws ErrorException add(ch1, ch2)

            close(ch1)
            close(ch2)
        end

        @testset "Errors on fewer than 2 channels" begin
            ch1 = SignalChannel{ComplexF32,1}(100, 10)

            @test_throws ArgumentError add(ch1)

            close(ch1)
        end
    end
end

end # module ChannelCombineTest
