using BenchmarkTools
using SignalChannels
using FixedSizeArrays: FixedSizeMatrixDefault
using Test: @testset, @test

# SoapySDR benchmarks - only run when SoapySDR and a loopback driver are available
# These benchmarks test allocation-free streaming in the hot path
#
# Run with:
#   SOAPY_SDR_PLUGIN_PATH=/path/to/build julia --threads=auto --project=. -e 'using Pkg; Pkg.benchmark()'
#
# Or run directly for allocation checks:
#   SOAPY_SDR_PLUGIN_PATH=/path/to/build julia --threads=auto --project=. benchmark/soapysdr_benchmarks.jl

# Check if we can run these benchmarks
const SOAPYSDR_AVAILABLE = Base.find_package("SoapySDR") !== nothing
const HAS_LOOPBACK_DRIVER = haskey(ENV, "SOAPY_SDR_PLUGIN_PATH") ||
                            Base.find_package("SoapyLoopback_jll") !== nothing

# Check if we're being run via the benchmark suite (SUITE is defined) or standalone
const IS_BENCHMARK_SUITE = @isdefined(SUITE)

if SOAPYSDR_AVAILABLE && HAS_LOOPBACK_DRIVER
    using SoapySDR
    using Unitful
    using SignalChannels: stream_data, SDRChannelConfig

    # Load SoapyLoopback_jll if not using custom plugin path
    if !haskey(ENV, "SOAPY_SDR_PLUGIN_PATH") && Base.find_package("SoapyLoopback_jll") !== nothing
        @eval using SoapyLoopback_jll
    end

    # Benchmark configuration
    const SOAPY_NUM_BUFFERS = 100  # Number of buffers to transfer per benchmark
    const SOAPY_SAMPLE_RATE = 1e6  # 1 MHz sample rate

    # Get device MTU for the loopback driver
    function get_loopback_mtu()
        device_args = SoapySDR.KWArgs()
        device_args["driver"] = "loopback"
        mtu = nothing
        SoapySDR.Device(device_args) do dev
            tx_ch = dev.tx[1]
            tx_ch.sample_rate = SOAPY_SAMPLE_RATE * Unitful.Hz
            stream = SoapySDR.Stream(ComplexF32, [tx_ch])
            mtu = Int(stream.mtu)
        end
        return mtu
    end

    # Setup for standalone SignalChannel benchmark (no SDR)
    # Tests the PipeChannel put!/take! path in isolation
    function setup_channel_benchmark(chunk_size::Int, buffer_size::Int=256)
        channel = SignalChannel{ComplexF32}(chunk_size, 1, buffer_size)

        # Pre-allocate test data
        data = FixedSizeMatrixDefault{ComplexF32}(zeros(ComplexF32, chunk_size, 1))
        for i in 1:chunk_size
            data[i, 1] = ComplexF32(i / chunk_size, 0.5f0)
        end

        return (channel, data)
    end

    # Setup channel with consumer task for put! benchmarks
    function setup_channel_put_benchmark(chunk_size::Int)
        channel, data = setup_channel_benchmark(chunk_size)
        # Start consumer to drain the channel
        consumer = Threads.@spawn begin
            for buf in channel
                # discard
            end
        end
        # Warm up
        for idx in 1:50
            put!(channel, data)
        end
        sleep(0.05)
        return (channel, data, consumer)
    end

    # Setup channel with producer task for take! benchmarks
    function setup_channel_take_benchmark(chunk_size::Int)
        channel, data = setup_channel_benchmark(chunk_size)
        # Start producer to feed the channel
        producer = Threads.@spawn begin
            try
                for i in 1:1000
                    isopen(channel) || break
                    put!(channel, data)
                end
            catch e
                # Ignore InvalidStateException when channel closes
                e isa InvalidStateException || rethrow()
            end
        end
        # Wait for channel to have data
        sleep(0.05)
        return (channel, producer)
    end

    # Benchmark: Single put! operation on SignalChannel
    # Should show zero or constant allocations per call
    function benchmark_single_put!(channel::SignalChannel{ComplexF32}, data::FixedSizeMatrixDefault{ComplexF32})
        put!(channel, data)
        return nothing
    end

    # Benchmark: Single take! operation on SignalChannel
    # Should show zero or constant allocations per call
    function benchmark_single_take!(channel::SignalChannel{ComplexF32})
        take!(channel)
        return nothing
    end

    # Setup TX→RX loopback benchmark
    # Returns (tx_channel, rx_data_channel, test_data, cleanup_func)
    function setup_loopback_benchmark(chunk_size::Int; prime_buffers::Int=0)
        device_args = SoapySDR.KWArgs()
        device_args["driver"] = "loopback"

        config = SDRChannelConfig(
            sample_rate=SOAPY_SAMPLE_RATE * Unitful.Hz,
            frequency=100e6 * Unitful.Hz,
        )

        # Setup RX stream
        stop_event = Base.Event()
        rx_data_channel, rx_warning_channel = stream_data(
            ComplexF32,
            device_args,
            config,
            stop_event;
            chunk_size=chunk_size,
            leadin_buffers=0,
        )

        # Setup TX stream
        tx_channel = SignalChannel{ComplexF32}(chunk_size, 1, 256)
        tx_stats_channel, tx_warning_channel = stream_data(device_args, config, tx_channel)

        # Create test data buffer
        test_data = FixedSizeMatrixDefault{ComplexF32}(zeros(ComplexF32, chunk_size, 1))
        for i in 1:chunk_size
            test_data[i, 1] = ComplexF32(i / chunk_size, (chunk_size - i) / chunk_size)
        end

        # Prime the loopback if requested
        if prime_buffers > 0
            for idx in 1:prime_buffers
                put!(tx_channel, test_data)
            end
            sleep(0.3)
            while isready(rx_data_channel)
                take!(rx_data_channel)
            end
        end

        cleanup = () -> begin
            close(tx_channel)
            notify(stop_event)
            for buf in tx_stats_channel end
            for buf in tx_warning_channel end
            for buf in rx_data_channel end
            for buf in rx_warning_channel end
        end

        return (tx_channel, rx_data_channel, test_data, stop_event, cleanup)
    end

    # Benchmark: Full TX→RX loopback throughput
    # Producer sends data, consumer receives it
    function benchmark_loopback!(
        tx_channel::SignalChannel{ComplexF32},
        rx_channel::SignalChannel{ComplexF32},
        data::FixedSizeMatrixDefault{ComplexF32},
        num_buffers::Int,
    )
        # Start producer
        producer = Threads.@spawn begin
            for _ in 1:num_buffers
                put!(tx_channel, data)
            end
        end

        # Consumer receives data
        received = 0
        while received < num_buffers
            if isready(rx_channel)
                take!(rx_channel)
                received += 1
            else
                yield()
            end
        end

        wait(producer)
        return nothing
    end

    # Benchmark: Single take! from RX loopback channel
    # Tests the complete SDR pipeline allocation behavior
    function benchmark_loopback_single_take!(
        tx_channel::SignalChannel{ComplexF32},
        rx_channel::SignalChannel{ComplexF32},
        data::FixedSizeMatrixDefault{ComplexF32},
    )
        # Send one buffer via TX
        put!(tx_channel, data)
        # Wait for it to appear on RX
        while !isready(rx_channel)
            yield()
        end
        take!(rx_channel)
        return nothing
    end

    # Only create SUITE entries when running via benchmark framework
    if IS_BENCHMARK_SUITE
        SUITE["soapysdr"] = BenchmarkGroup()

        # Try to get MTU, skip benchmarks if loopback device is not working
        local mtu
        try
            mtu = get_loopback_mtu()
        catch e
            @warn "Could not get loopback MTU, skipping SoapySDR benchmarks" exception = e
            mtu = nothing
        end

        if mtu !== nothing
            # Test different chunk sizes relative to MTU
            chunk_sizes = [
                ("mtu_quarter", mtu ÷ 4),
                ("mtu_equal", mtu),
                ("mtu_double", mtu * 2),
            ]

            # =========================================================================
            # SignalChannel benchmarks (no SDR) - tests PipeChannel overhead
            # =========================================================================
            SUITE["soapysdr"]["channel"] = BenchmarkGroup()

            for (name, chunk_size) in chunk_sizes
                # Single put! benchmark - should show 0 allocations
                SUITE["soapysdr"]["channel"]["put!_$name"] = @benchmarkable(
                    benchmark_single_put!(channel, data),
                    setup = (channel, data, consumer) = setup_channel_put_benchmark($chunk_size),
                    teardown = (close(channel); wait(consumer)),
                    evals = 100,
                    samples = 10,
                )

                # Single take! benchmark - should show 0 allocations
                SUITE["soapysdr"]["channel"]["take!_$name"] = @benchmarkable(
                    benchmark_single_take!(channel),
                    setup = (channel, producer) = setup_channel_take_benchmark($chunk_size),
                    teardown = (close(channel); wait(producer)),
                    evals = 100,
                    samples = 10,
                )
            end

            # =========================================================================
            # Full TX→RX loopback benchmarks (with SDR)
            # NOTE: Loopback benchmarks are only available in standalone mode
            # (run benchmark/soapysdr_benchmarks.jl directly) because the
            # streaming tasks don't interact well with BenchmarkTools setup/teardown.
            # =========================================================================
        end
    end
elseif IS_BENCHMARK_SUITE
    # Placeholder when SoapySDR is not available but running via benchmark suite
    SUITE["soapysdr"] = BenchmarkGroup()
    # No benchmarks added - group will be empty
end

# ============================================================================
# Direct execution: Run allocation tests
# ============================================================================
if abspath(PROGRAM_FILE) == @__FILE__
    if !SOAPYSDR_AVAILABLE
        error("SoapySDR not installed. Install with: using Pkg; Pkg.add(\"SoapySDR\")")
    end

    if !HAS_LOOPBACK_DRIVER
        error("No loopback driver available. Set SOAPY_SDR_PLUGIN_PATH or install SoapyLoopback_jll")
    end

    if Threads.nthreads() < 2
        error("This test requires multiple threads. Start Julia with --threads=auto")
    end

    mtu = get_loopback_mtu()
    @info "Device MTU: $mtu samples"

    chunk_sizes = [
        ("MTU/4", mtu ÷ 4),
        ("MTU", mtu),
        ("MTU*2", mtu * 2),
    ]

    println("\n" * "="^70)
    println("SoapySDR Allocation Tests (using BenchmarkTools)")
    println("="^70)
    println("\nThese tests verify that put!/take! operations don't allocate.")
    println("Zero allocations means the hot path is allocation-free.\n")

    @testset "SoapySDR Allocation Tests" begin
        @testset "SignalChannel (no SDR)" begin
            for (name, chunk_size) in chunk_sizes
                @testset "$name ($chunk_size samples)" begin
                    # Test put! allocations
                    channel, data = setup_channel_benchmark(chunk_size)
                    consumer = Threads.@spawn begin
                        for _ in channel end
                    end

                    # Warm up
                    for _ in 1:100
                        put!(channel, data)
                    end
                    sleep(0.1)

                    # Benchmark single put!
                    result = @benchmark benchmark_single_put!($channel, $data) evals = 100 samples = 10
                    put_allocs = result.allocs
                    put_time_ns = median(result.times)

                    close(channel)
                    wait(consumer)

                    @test put_allocs == 0

                    # Test take! allocations
                    channel, data = setup_channel_benchmark(chunk_size)
                    producer = Threads.@spawn begin
                        try
                            for idx in 1:2000
                                isopen(channel) || break
                                put!(channel, data)
                            end
                        catch e
                            # Ignore InvalidStateException when channel closes
                            e isa InvalidStateException || rethrow()
                        end
                    end
                    sleep(0.1)

                    # Warm up
                    for idx in 1:100
                        take!(channel)
                    end

                    result = @benchmark benchmark_single_take!($channel) evals = 100 samples = 10
                    take_allocs = result.allocs
                    take_time_ns = median(result.times)

                    close(channel)
                    wait(producer)

                    @test take_allocs == 0

                    # Print timing and allocation results
                    put_status = put_allocs == 0 ? "PASS" : "FAIL"
                    take_status = take_allocs == 0 ? "PASS" : "FAIL"
                    println("  put!:  $(round(put_time_ns, digits=1)) ns, allocs=$put_allocs ($put_status)")
                    println("  take!: $(round(take_time_ns, digits=1)) ns, allocs=$take_allocs ($take_status)")
                end
            end
        end

        if haskey(ENV, "SOAPY_SDR_PLUGIN_PATH")
            @testset "Full TX→RX loopback (with SDR)" begin
                for (name, chunk_size) in chunk_sizes
                    @testset "$name ($chunk_size samples)" begin
                        tx_ch, rx_ch, data, stop_event, cleanup = setup_loopback_benchmark(chunk_size)

                        # Prime the loopback with a few round trips
                        for _ in 1:5
                            put!(tx_ch, data)
                        end
                        sleep(0.3)

                        # Drain any received data from warmup
                        while isready(rx_ch)
                            take!(rx_ch)
                        end

                        # Benchmark single TX→RX round trip
                        # Each iteration sends one buffer and waits for it on RX
                        # Note: Some allocations are expected from the rechunk view() and
                        # SoapySDR operations. The important metric is that allocations
                        # are constant (not proportional to data size).
                        result = @benchmark benchmark_loopback_single_take!($tx_ch, $rx_ch, $data) evals = 10 samples = 3
                        allocs = result.allocs
                        median_time_us = median(result.times) / 1000  # ns to μs
                        throughput_msps = chunk_size / (median_time_us / 1e6) / 1e6  # MSamples/s

                        cleanup()

                        # Loopback path has some overhead from rechunking and SoapySDR
                        # Allow up to 20 allocations per round-trip (mostly from view())
                        @test allocs <= 20
                        status = allocs <= 20 ? "PASS" : "FAIL"
                        println("  loopback round-trip: $(round(median_time_us, digits=1)) μs, $(round(throughput_msps, digits=1)) MSamples/s")
                        println("  loopback allocations: $allocs ($status, threshold: ≤20)")
                    end
                end
            end
        else
            @info "Skipping loopback tests: requires SOAPY_SDR_PLUGIN_PATH for TX support"
        end
    end

    println("\n" * "="^70)
    println("Done")
    println("="^70 * "\n")
end
