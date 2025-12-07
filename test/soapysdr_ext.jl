module SoapySDRExtTest

using Test: @test, @testset, @test_throws, @test_skip, @test_broken

# Only run these tests if SoapySDR is available
if Base.find_package("SoapySDR") !== nothing
    using SignalChannels
    using SoapySDR
    using SoapySDR: Device, SoapySDRDeviceError
    using Unitful
    using FixedSizeArrays: FixedSizeMatrixDefault

    using SignalChannels: stream_data, SDRChannelConfig

    @testset "SoapySDR Extension" begin

        @testset "Loopback device tests" begin
            # Check if SoapyLoopback_jll is available
            if Base.find_package("SoapyLoopback_jll") === nothing
                @info "Skipping loopback tests: SoapyLoopback_jll not available"
                @test_skip false
            else
                # Load SoapyLoopback_jll to make the loopback driver available
                using SoapyLoopback_jll

                @testset "RX stream_data test" begin
                    # Test the high-level stream_data API that manages device lifecycle internally.
                    # Note: The loopback device only echoes TX->RX, so RX reads will timeout without
                    # an active TX stream. We test that the API works and handles timeouts gracefully.

                    device_args = SoapySDR.KWArgs()
                    device_args["driver"] = "loopback"

                    # Create SDRChannelConfig for high-level API
                    config = SDRChannelConfig(
                        sample_rate = 1e6 * Unitful.Hz,
                        frequency = 1e9 * Unitful.Hz,
                    )

                    # Use an Event to stop after a short time (loopback RX will timeout without TX)
                    stop_event = Base.Event()

                    # High-level API with explicit ComplexF32 format and SDRChannelConfig
                    data_channel, warning_channel = SignalChannels.stream_data(
                        ComplexF32,
                        device_args,
                        config,
                        stop_event;
                        leadin_buffers=0,
                    )

                    # Verify we got a valid MTU (accessible via signal channel)
                    @test data_channel.num_samples > 0

                    # Give it a moment to start, then stop (loopback won't produce data without TX)
                    sleep(0.1)
                    notify(stop_event)

                    # Drain any data that came through (likely none from loopback without TX)
                    for _ in data_channel end

                    # Drain warnings
                    for _ in warning_channel end

                    # Verify channels are closed after iteration completes
                    @test !isopen(data_channel)
                    @test !isopen(warning_channel)

                    # Test passes if no crash occurs - loopback RX doesn't produce data without TX
                    @test true
                end

                @testset "TX stream_data API test" begin
                    # Note: SoapyLoopback doesn't support actual TX (writeStream returns NOT_SUPPORTED),
                    # but we can test that the TX API doesn't crash and handles errors gracefully

                    sample_rate = 1e6 * Unitful.Hz
                    num_channels = 1
                    mtu = 1024  # Use a reasonable MTU for testing

                    device_args = SoapySDR.KWArgs()
                    device_args["driver"] = "loopback"

                    # Create SDRChannelConfig for TX
                    config = SDRChannelConfig(
                        sample_rate = sample_rate,
                        frequency = 1e9 * Unitful.Hz,
                    )

                    # Create input channel for TX
                    tx_channel = SignalChannel{ComplexF32}(mtu, num_channels, 10)

                    # Start TX task using the new high-level API (will encounter NOT_SUPPORTED but should handle gracefully)
                    println("Note: SoapyLoopback doesn't support actual TX (writeStream returns NOT_SUPPORTED)")
                    stats_channel, warning_channel = stream_data(device_args, config, tx_channel)

                    # Send some data using the convenience method
                    buffer = zeros(ComplexF32, mtu, 1)
                    buffer[1:10, 1] .= ComplexF32(1.0 + 1.0im)
                    put!(tx_channel, buffer)  # Tests the new AbstractMatrix put! method

                    close(tx_channel)

                    # Wait for transmission to complete by draining the channels
                    for _ in stats_channel end
                    for _ in warning_channel end

                    # Verify channels are closed after iteration completes
                    @test !isopen(stats_channel)
                    @test !isopen(warning_channel)

                    # Test passes if no crash occurs (errors are logged as warnings)
                    @test true
                end
            end
        end

        @testset "Method signatures" begin
            # Test that stream_data accepts SDRChannelConfig and Union{Event, Integer} as end condition
            found_stream_data = false
            for m in methods(stream_data)
                sig = m.sig
                if sig isa UnionAll
                    sig = sig.body
                end
                # Check if this is a method with SDRChannelConfig
                if sig <: Tuple{typeof(stream_data),Any,SignalChannels.SDRChannelConfig,Union{Base.Event,Integer}}
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
