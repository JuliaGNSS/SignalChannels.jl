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

    # TODO: always test with SoapyLoopback_jll once it supports TX -> RX
    # Depends on https://github.com/JuliaTelecom/SoapyLoopback/pull/3
    # and it needs to be roundtripped through Yggdrasil

    @testset "SoapySDR Extension" begin

        @testset "Loopback device tests" begin
            # Check if a loopback driver is available (either via JLL or SOAPY_SDR_PLUGIN_PATH)
            loopback_available = false
            has_tx_support = false

            # First check if custom plugin path provides loopback
            if haskey(ENV, "SOAPY_SDR_PLUGIN_PATH")
                # Custom plugin path - don't load JLL to avoid conflict
                # Assume if SOAPY_SDR_PLUGIN_PATH is set and points to a loopback build, it's available
                loopback_available = true
                has_tx_support = true  # Our custom build has TX support
            elseif Base.find_package("SoapyLoopback_jll") !== nothing
                # Load SoapyLoopback_jll to make the loopback driver available
                @eval using SoapyLoopback_jll
                loopback_available = true
                has_tx_support = false  # JLL driver doesn't have TX support
            end

            if !loopback_available
                @info "Skipping loopback tests: no loopback driver available"
                @test_skip false
            else
                @testset "TX→RX loopback test" begin
                    # Test full TX→RX loopback: data written to TX should appear on RX
                    # Note: This test requires a loopback driver with TX support (custom build)
                    # The JLL-provided driver only supports RX, so this test will be skipped

                    if !has_tx_support
                        @info "Skipping TX→RX loopback: JLL driver doesn't support TX (use custom build with SOAPY_SDR_PLUGIN_PATH)"
                        @test_skip false
                    else
                        device_args = SoapySDR.KWArgs()
                        device_args["driver"] = "loopback"

                        config = SDRChannelConfig(
                            sample_rate=1e6 * Unitful.Hz,
                            frequency=100e6 * Unitful.Hz,
                        )

                        # Setup RX stream first to get MTU
                        stop_event = Base.Event()
                        rx_data_channel, rx_warning_channel = SignalChannels.stream_data(
                            ComplexF32,
                            device_args,
                            config,
                            stop_event;
                            leadin_buffers=0,
                        )

                        mtu = rx_data_channel.num_samples
                        @test mtu > 0

                        # Setup TX stream
                        tx_channel = SignalChannel{ComplexF32,1}(mtu, 10)
                        tx_stats_channel, tx_warning_channel = stream_data(device_args, config, tx_channel)

                        # Create test pattern with recognizable data
                        test_pattern = FixedSizeMatrixDefault{ComplexF32}(zeros(ComplexF32, mtu, 1))
                        for i in 1:mtu
                            test_pattern[i, 1] = ComplexF32(i / mtu, (mtu - i) / mtu)
                        end

                        # Send test data via TX
                        put!(tx_channel, test_pattern)

                        # Wait for data to propagate through loopback
                        sleep(0.5)

                        # Receive data from RX
                        rx_buffer = nothing
                        for _ in 1:10
                            if isready(rx_data_channel)
                                rx_buffer = take!(rx_data_channel)
                                break
                            end
                            sleep(0.1)
                        end

                        # Cleanup
                        close(tx_channel)
                        notify(stop_event)

                        for _ in tx_stats_channel
                        end
                        for _ in tx_warning_channel
                        end
                        for _ in rx_data_channel
                        end
                        for _ in rx_warning_channel
                        end

                        # Verify loopback worked - TX data should match RX data exactly
                        @test rx_buffer !== nothing
                        if rx_buffer !== nothing
                            matches = sum(test_pattern[:, 1] .== rx_buffer[:, 1])
                            @test matches == mtu
                        end
                    end
                end

                @testset "RX-only stream_data test" begin
                    # Test that RX stream works and handles timeouts gracefully without TX
                    device_args = SoapySDR.KWArgs()
                    device_args["driver"] = "loopback"

                    config = SDRChannelConfig(
                        sample_rate=1e6 * Unitful.Hz,
                        frequency=1e9 * Unitful.Hz,
                    )

                    stop_event = Base.Event()
                    data_channel, warning_channel = SignalChannels.stream_data(
                        ComplexF32,
                        device_args,
                        config,
                        stop_event;
                        leadin_buffers=0,
                    )

                    @test data_channel.num_samples > 0

                    # Stop quickly - loopback RX will timeout without TX
                    sleep(0.1)
                    notify(stop_event)

                    for _ in data_channel
                    end
                    for _ in warning_channel
                    end

                    @test !isopen(data_channel)
                    @test !isopen(warning_channel)
                end

                @testset "TX-only stream_data test" begin
                    # Test that TX stream works independently
                    device_args = SoapySDR.KWArgs()
                    device_args["driver"] = "loopback"

                    config = SDRChannelConfig(
                        sample_rate=1e6 * Unitful.Hz,
                        frequency=1e9 * Unitful.Hz,
                    )

                    mtu = 1024
                    tx_channel = SignalChannel{ComplexF32,1}(mtu, 10)
                    stats_channel, warning_channel = stream_data(device_args, config, tx_channel)

                    # Send some data
                    buffer = FixedSizeMatrixDefault{ComplexF32}(zeros(ComplexF32, mtu, 1))
                    buffer[1:10, 1] .= ComplexF32(1.0 + 1.0im)
                    put!(tx_channel, buffer)

                    close(tx_channel)

                    for _ in stats_channel
                    end
                    for _ in warning_channel
                    end

                    @test !isopen(stats_channel)
                    @test !isopen(warning_channel)
                end

                @testset "TX→RX chunk size variations" begin
                    # Test loopback with different chunk sizes relative to MTU
                    # This tests the rechunking logic in both TX and RX paths

                    if !has_tx_support
                        @info "Skipping chunk size tests: JLL driver doesn't support TX"
                        @test_skip false
                    else
                        device_args = SoapySDR.KWArgs()
                        device_args["driver"] = "loopback"

                        config = SDRChannelConfig(
                            sample_rate=1e6 * Unitful.Hz,
                            frequency=100e6 * Unitful.Hz,
                        )

                        # First, discover the device MTU
                        mtu = nothing
                        SoapySDR.Device(device_args) do dev
                            tx_ch = dev.tx[1]
                            tx_ch.sample_rate = config.sample_rate
                            stream = SoapySDR.Stream(ComplexF32, [tx_ch])
                            mtu = Int(stream.mtu)
                        end
                        @test mtu !== nothing
                        @test mtu > 0

                        # Test configurations: (tx_chunk_size, rx_chunk_size, description)
                        # Each tests different rechunking scenarios
                        test_configs = [
                            (mtu ÷ 4, mtu ÷ 4, "both smaller than MTU"),
                            (mtu, mtu, "both equal to MTU"),
                            (mtu * 2, mtu * 2, "both larger than MTU"),
                            (mtu ÷ 2, mtu, "TX smaller, RX equal"),
                            (mtu, mtu ÷ 2, "TX equal, RX smaller"),
                            (mtu ÷ 4, mtu * 2, "TX smaller, RX larger"),
                        ]

                        for (tx_chunk, rx_chunk, desc) in test_configs
                            @testset "$desc (TX=$tx_chunk, RX=$rx_chunk)" begin
                                # Calculate how many samples to send for a complete test
                                # We need at least 2 RX buffers worth of data to properly test rechunking
                                # Calculate how many TX buffers needed to fill at least 2 RX buffers
                                min_samples_needed = rx_chunk * 2
                                num_tx_buffers = max(4, cld(min_samples_needed, tx_chunk))
                                total_samples = tx_chunk * num_tx_buffers

                                # Setup RX stream with specified chunk size
                                stop_event = Base.Event()
                                rx_data_channel, rx_warning_channel = SignalChannels.stream_data(
                                    ComplexF32,
                                    device_args,
                                    config,
                                    stop_event;
                                    chunk_size=rx_chunk,
                                    leadin_buffers=0,
                                )

                                @test rx_data_channel.num_samples == rx_chunk

                                # Setup TX stream with specified chunk size
                                tx_channel = SignalChannel{ComplexF32,1}(tx_chunk, 10)
                                tx_stats_channel, tx_warning_channel = stream_data(device_args, config, tx_channel)

                                # Create and send test data with recognizable patterns
                                # Each buffer has a unique pattern based on buffer index
                                sent_data = ComplexF32[]
                                for buf_idx in 1:num_tx_buffers
                                    buffer = FixedSizeMatrixDefault{ComplexF32}(zeros(ComplexF32, tx_chunk, 1))
                                    for i in 1:tx_chunk
                                        # Create pattern: real = buffer_idx, imag = sample position
                                        buffer[i, 1] = ComplexF32(buf_idx, i)
                                    end
                                    append!(sent_data, buffer[:, 1])
                                    put!(tx_channel, buffer)
                                end

                                # Wait for data to propagate
                                sleep(0.5)

                                # Collect received data
                                received_data = ComplexF32[]
                                timeout_count = 0
                                while length(received_data) < total_samples && timeout_count < 20
                                    if isready(rx_data_channel)
                                        rx_buffer = take!(rx_data_channel)
                                        append!(received_data, rx_buffer[:, 1])
                                        timeout_count = 0
                                    else
                                        sleep(0.1)
                                        timeout_count += 1
                                    end
                                end

                                # Cleanup
                                close(tx_channel)
                                notify(stop_event)

                                for _ in tx_stats_channel
                                end
                                for _ in tx_warning_channel
                                end
                                for _ in rx_data_channel
                                end
                                for _ in rx_warning_channel
                                end

                                # Verify we received the expected amount of data
                                @test length(received_data) >= total_samples

                                # Verify data integrity - the first total_samples should match
                                if length(received_data) >= total_samples
                                    matches = sum(sent_data .== received_data[1:total_samples])
                                    @test matches == total_samples
                                end
                            end
                        end
                    end
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
