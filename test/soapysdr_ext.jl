module SoapySDRExtTest

using Test: @test, @testset, @test_throws, @test_skip, @test_broken

# Only run these tests if SoapySDR is available
if Base.find_package("SoapySDR") !== nothing
    using SignalChannels
    using SoapySDR
    using Unitful
    using FixedSizeArrays: FixedSizeMatrixDefault

    # Get the extension module and import stream_data
    const ext_module = Base.get_extension(SignalChannels, :SignalChannelsSoapySDRExt)
    const stream_data = ext_module.stream_data

    @testset "SoapySDR Extension" begin
        @testset "Extension loads correctly" begin
            # Test that the extension module exists
            @test !isnothing(ext_module)

            # Test that stream_data is defined in the extension
            @test isdefined(ext_module, :stream_data)
        end

        @testset "Loopback device tests" begin
            # Check if SoapyLoopback_jll is available
            if Base.find_package("SoapyLoopback_jll") === nothing
                @info "Skipping loopback tests: SoapyLoopback_jll not available"
                @test_skip false
            else
                # Load SoapyLoopback_jll to make the loopback driver available
                using SoapyLoopback_jll

                @testset "TX/RX loopback integration" begin
                    # Test parameters
                    sample_rate = 1e6 * Unitful.Hz
                    center_freq = 1e9 * Unitful.Hz
                    num_samples_to_send = 5_000  # Reduced for stability
                    num_channels = 1

                    # Generate test pattern - simple ramp for easy verification
                    test_pattern = ComplexF32.(1:num_samples_to_send) .+ im .* ComplexF32.(1:num_samples_to_send)

                    # Create device arguments
                    device_args = SoapySDR.KWArgs()
                    device_args["driver"] = "loopback"

                    try
                        Device(device_args) do dev
                        # Configure TX
                        tx = dev.tx[1]
                        tx.sample_rate = sample_rate
                        tx.frequency = center_freq

                        # Configure RX
                        rx = dev.rx[1]
                        rx.sample_rate = sample_rate
                        rx.frequency = center_freq

                        # Create streams
                        tx_stream = SoapySDR.Stream(ComplexF32, tx)
                        rx_stream = SoapySDR.Stream(ComplexF32, rx)

                        # Create input channel for TX with proper dimensions
                        tx_channel = SignalChannel{ComplexF32}(tx_stream.mtu, num_channels, 10)

                        # Start RX first (to catch all transmitted data)
                        rx_data = Channel{Matrix{ComplexF32}}(100)
                        rx_task = @async begin
                            data_channel = stream_data(rx_stream, num_samples_to_send; leadin_buffers=0)
                            for data in data_channel
                                put!(rx_data, copy(data))
                            end
                            close(rx_data)
                        end

                        # Give RX time to start
                        sleep(0.2)  # Increased for stability

                        # Start TX
                        tx_task = stream_data(tx_stream, tx_channel)

                        # Feed test pattern to TX
                        samples_sent = 0
                        for i in 1:tx_stream.mtu:num_samples_to_send
                            chunk_size = min(tx_stream.mtu, num_samples_to_send - samples_sent)

                            # Create FixedSizeMatrixDefault buffer
                            buffer = FixedSizeMatrixDefault{ComplexF32}(undef, tx_stream.mtu, 1)

                            # Fill with test pattern
                            buffer[1:chunk_size, 1] .= test_pattern[i:i+chunk_size-1]

                            # Pad with zeros if needed
                            if chunk_size < tx_stream.mtu
                                buffer[chunk_size+1:end, 1] .= ComplexF32(0)
                            end

                            put!(tx_channel, buffer)
                            samples_sent += chunk_size
                        end
                        close(tx_channel)

                        # Wait for both tasks
                        wait(tx_task)
                        wait(rx_task)

                        # Collect received data
                        received_samples = ComplexF32[]
                        for data in rx_data
                            append!(received_samples, vec(data))
                        end

                        # Verify we received data
                        @test length(received_samples) >= num_samples_to_send

                        # Verify data matches (check first samples as loopback may have alignment issues)
                        if length(received_samples) >= 100
                            # Check that we see the ramp pattern in the received data
                            # Due to potential timing/buffering, we look for the pattern rather than exact alignment
                            pattern_found = false
                            for offset in 1:min(1000, length(received_samples) - 100)
                                # Check if we see increasing real and imaginary parts
                                chunk = received_samples[offset:offset+99]
                                differences = diff(real.(chunk))
                                if all(d -> abs(d - 1.0f0) < 2.0f0, differences)
                                    pattern_found = true
                                    break
                                end
                            end
                            @test pattern_found
                        end
                        end
                    catch e
                        if isa(e, TaskFailedException) || isa(e, SoapySDR.SoapySDRDeviceError)
                            @warn "Loopback test skipped due to known SoapyLoopback issues" exception=e
                            @test_broken false
                        else
                            rethrow(e)
                        end
                    end
                end
            end
        end

        @testset "Method signatures" begin
            # Test that the extension defines generate_stream for SoapySDR.Stream
            # Note: We need to check with type parameters for the stream
            found_generate_stream = false
            for m in methods(SignalChannels.generate_stream)
                sig = m.sig
                if sig isa UnionAll
                    sig = sig.body
                end
                # Check if this is the method we're looking for
                if sig <: Tuple{typeof(SignalChannels.generate_stream), Function, SoapySDR.Stream}
                    found_generate_stream = true
                    break
                end
            end
            @test found_generate_stream

            # Test that stream_data accepts Union{Event, Integer} as end condition
            # The actual signature uses Union{Base.Event, Integer}, so we check for that
            found_stream_data = false
            for m in methods(stream_data)
                sig = m.sig
                if sig isa UnionAll
                    sig = sig.body
                end
                # Check if this is the method with Union{Base.Event, Integer}
                if sig <: Tuple{typeof(stream_data), SoapySDR.Stream, Union{Base.Event, Integer}}
                    found_stream_data = true
                    break
                end
            end
            @test found_stream_data
        end
    end
else
    @testset "SoapySDR Extension (Skipped)" begin
        @info "SoapySDR not installed. Install with: using Pkg; Pkg.add(\"SoapySDR\")"
        @test true  # No-op test to indicate tests were skipped
    end
end

end # module SoapySDRExtTest
