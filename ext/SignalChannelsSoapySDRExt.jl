module SignalChannelsSoapySDRExt

using SignalChannels
using SoapySDR
using Unitful
using FixedSizeArrays: FixedSizeMatrixDefault
using DSP: hamming

# Helper to check if a value is within any of the given ranges
function in_any_range(value, ranges)
    for r in ranges
        if value in r
            return true
        end
    end
    return false
end

# Helper to format ranges for error messages
function format_ranges(ranges)
    return join(string.(ranges), ", ")
end

# Helper to validate SDRChannelConfig against a SoapySDR channel's capabilities
function validate_config!(channel::SoapySDR.Channel, config::SignalChannels.SDRChannelConfig, channel_idx::Int)
    direction = channel.direction == SoapySDR.SOAPY_SDR_RX ? "RX" : "TX"

    # Validate sample rate
    sr_ranges = SoapySDR.sample_rate_ranges(channel)
    if !isempty(sr_ranges) && !in_any_range(config.sample_rate, sr_ranges)
        error("$direction channel $channel_idx: sample_rate $(config.sample_rate) is outside supported range(s): $(format_ranges(sr_ranges))")
    end

    # Validate frequency
    freq_ranges = SoapySDR.frequency_ranges(channel)
    if !isempty(freq_ranges) && !in_any_range(config.frequency, freq_ranges)
        error("$direction channel $channel_idx: frequency $(config.frequency) is outside supported range(s): $(format_ranges(freq_ranges))")
    end

    # Validate bandwidth (use sample_rate if bandwidth not specified)
    bw = isnothing(config.bandwidth) ? config.sample_rate : config.bandwidth
    bw_ranges = SoapySDR.bandwidth_ranges(channel)
    if !isempty(bw_ranges) && !in_any_range(bw, bw_ranges)
        error("$direction channel $channel_idx: bandwidth $bw is outside supported range(s): $(format_ranges(bw_ranges))")
    end

    # Validate gain (if specified)
    # Note: We compare using ustrip to avoid type mismatch issues with Gain types
    # For Gain types (like 30u"dB"), ustrip(gain) returns the numeric value directly
    if !isnothing(config.gain)
        gain_range = SoapySDR.gainrange(channel)
        gain_val = ustrip(config.gain)
        gain_min = ustrip(first(gain_range))
        gain_max = ustrip(last(gain_range))
        if gain_val < gain_min || gain_val > gain_max
            error("$direction channel $channel_idx: gain $(config.gain) is outside supported range: $gain_range")
        end
    end

    return nothing
end

# Helper to apply SDRChannelConfig to a SoapySDR channel (works for both RX and TX)
function apply_config!(channel::SoapySDR.Channel, config::SignalChannels.SDRChannelConfig; channel_idx::Int=1)
    # Validate config against channel capabilities before applying
    validate_config!(channel, config, channel_idx)

    channel.sample_rate = config.sample_rate
    channel.bandwidth = isnothing(config.bandwidth) ? config.sample_rate : config.bandwidth
    channel.frequency = config.frequency

    if isnothing(config.gain)
        channel.gain_mode = true
    else
        channel.gain = config.gain
    end

    if !isnothing(config.antenna)
        channel.antenna = config.antenna
    end

    if !isnothing(config.frequency_correction)
        channel.frequency_correction = config.frequency_correction
    end

    return channel
end

# Helper for formatting time in a human-readable way
function format_time(seconds::Real)
    if seconds < 1e-3
        return string(round(seconds * 1e6, digits=1), "μs")
    elseif seconds < 1.0
        return string(round(seconds * 1e3, digits=1), "ms")
    elseif seconds < 60.0
        return string(round(seconds, digits=2), "s")
    else
        minutes = floor(Int, seconds / 60)
        remaining_seconds = seconds - minutes * 60
        return string(minutes, "m ", round(remaining_seconds, digits=1), "s")
    end
end

# Helper to push warning without blocking - silently drops if channel is full or closed
function push_warning!(channel::Channel{SignalChannels.StreamWarning}, warning::SignalChannels.StreamWarning)
    isopen(channel) && !isfull(channel) && put!(channel, warning)
    return nothing
end

# Helper to read a single buffer from the stream using the direct C API.
# Returns the number of samples read, or a negative error code.
# Uses pre-allocated buffers to avoid allocations in the hot path.
function read_buffer!(
    stream::SoapySDR.Stream,
    buff::AbstractMatrix{T},
    timeout_us::Integer,
    buff_ptrs::Vector{Ptr{T}},
    out_flags::Base.RefValue{Cint},
    timens::Base.RefValue{Clonglong},
) where {T}
    samples_to_read = size(buff, 1)
    nchannels = size(buff, 2)
    # Update pointers for current buffer columns
    for i in 1:nchannels
        buff_ptrs[i] = pointer(buff, (i - 1) * samples_to_read + 1)
    end
    GC.@preserve buff begin
        return SoapySDR.SoapySDRDevice_readStream(
            stream.d,
            stream,
            pointer(buff_ptrs),
            samples_to_read,
            out_flags,
            timens,
            timeout_us,
        )
    end
end

"""
    stream_data([T=ComplexF32], dev_args, config::SDRChannelConfig, end_condition::Union{Integer,Base.Event}; chunk_size=nothing, leadin_buffers=16, warning_buffer_size=16, buffer_time=1u"s")
    stream_data([T=ComplexF32], dev_args, configs::Tuple{SDRChannelConfig,...}, end_condition::Union{Integer,Base.Event}; chunk_size=nothing, leadin_buffers=16, warning_buffer_size=16, buffer_time=1u"s")

Creates an SDR device, configures it, and streams RX data.

The device lifecycle is managed internally - the device stays open as long as the streaming task
is running. When the output channel is closed (e.g., due to a downstream error), the streaming
task detects this, stops reading, and then closes the device cleanly.

# Arguments
- `T`: Stream format type (default: `ComplexF32`). Other options include `Complex{Int16}`, etc.
- `dev_args`: Device arguments (e.g., from `SoapySDR.Devices()[1]`)
- `config`: Single `SDRChannelConfig` for single-channel streaming
- `configs`: Tuple of `SDRChannelConfig` for multi-channel streaming (one per antenna channel)
- `end_condition::Union{Integer,Base.Event}`: Either total number of samples to read, or an Event to signal stop
- `chunk_size::Union{Integer,Nothing}`: Output chunk size. If `nothing` (default), uses the device MTU directly.
  If specified, rechunks the data to the given size. When `chunk_size` equals MTU, zero-copy passthrough is used.
- `leadin_buffers::Integer`: Number of initial buffers to discard (default: 16)
- `warning_buffer_size::Integer`: Size of the warning channel buffer (default: 16)
- `buffer_time`: Time duration of data to buffer (default: `1u"s"`). Provides headroom for downstream processing delays.

# Returns
- `Tuple{SignalChannel{T}, Channel{StreamWarning}}`: Tuple of (signal channel, warning channel).
  The chunk size can be accessed via `signal_channel.num_samples`.

# Examples
```julia
using SignalChannels
using SoapySDR

# Single channel streaming (defaults to ComplexF32, uses device MTU)
config = SDRChannelConfig(
    sample_rate = 5e6u"Hz",
    frequency = 1.57542e9u"Hz",
    gain = 50u"dB"
)
data_channel, warning_channel = stream_data(first(Devices()), config, 10_000_000)

# Stream with specific chunk size (useful for FFT-friendly sizes)
data_channel, warning_channel = stream_data(first(Devices()), config, 10_000_000; chunk_size=8192)

# Multi-channel streaming with different frequencies
configs = (
    SDRChannelConfig(sample_rate=5e6u"Hz", frequency=1.57542e9u"Hz"),
    SDRChannelConfig(sample_rate=5e6u"Hz", frequency=1.22760e9u"Hz"),
)
data_channel, warning_channel = stream_data(first(Devices()), configs, 10_000_000)

# Stream with explicit Complex{Int16} format
data_channel, warning_channel = stream_data(
    Complex{Int16},
    first(Devices()),
    config,
    10_000_000
)

# Process data - if an error occurs here, the device closes cleanly
for data in data_channel
    # Process data
end
```
"""
function SignalChannels.stream_data(
    dev_args,
    config::SignalChannels.SDRChannelConfig,
    end_condition::Union{Integer,Base.Event};
    chunk_size::Union{Integer,Nothing}=nothing,
    leadin_buffers::Integer=16,
    warning_buffer_size::Integer=16,
    buffer_time::Unitful.Time=1u"s",
)
    # Default to ComplexF32 for performance (avoids runtime type inference)
    return SignalChannels.stream_data(
        ComplexF32, dev_args, (config,), end_condition;
        chunk_size, leadin_buffers, warning_buffer_size, buffer_time
    )
end

function SignalChannels.stream_data(
    dev_args,
    configs::NTuple{N,SignalChannels.SDRChannelConfig},
    end_condition::Union{Integer,Base.Event};
    chunk_size::Union{Integer,Nothing}=nothing,
    leadin_buffers::Integer=16,
    warning_buffer_size::Integer=16,
    buffer_time::Unitful.Time=1u"s",
) where {N}
    # Default to ComplexF32 for performance (avoids runtime type inference)
    return SignalChannels.stream_data(
        ComplexF32, dev_args, configs, end_condition;
        chunk_size, leadin_buffers, warning_buffer_size, buffer_time
    )
end

function SignalChannels.stream_data(
    ::Type{T},
    dev_args,
    config::SignalChannels.SDRChannelConfig,
    end_condition::Union{Integer,Base.Event};
    chunk_size::Union{Integer,Nothing}=nothing,
    leadin_buffers::Integer=16,
    warning_buffer_size::Integer=16,
    buffer_time::Unitful.Time=1u"s",
) where {T<:Number}
    return SignalChannels.stream_data(
        T, dev_args, (config,), end_condition;
        chunk_size, leadin_buffers, warning_buffer_size, buffer_time
    )
end

function SignalChannels.stream_data(
    ::Type{T},
    dev_args,
    configs::NTuple{N,SignalChannels.SDRChannelConfig},
    end_condition::Union{Integer,Base.Event};
    chunk_size::Union{Integer,Nothing}=nothing,
    leadin_buffers::Integer=16,
    warning_buffer_size::Integer=16,
    buffer_time::Unitful.Time=1u"s",
) where {T<:Number,N}
    if Threads.nthreads() < 2
        error("stream_data requires Julia to be started with multiple threads. " *
              "Start Julia with `julia --threads=auto` or set JULIA_NUM_THREADS environment variable.")
    end

    sample_rate = first(configs).sample_rate
    for (i, config) in enumerate(configs)
        if config.sample_rate != sample_rate
            error("All SDRChannelConfigs must have the same sample_rate for multi-channel RX. " *
                  "Config 1 has $(sample_rate), config $i has $(config.sample_rate)")
        end
    end

    setup_channel = Channel{SignalChannel{T}}(1)
    warning_channel = Channel{SignalChannels.StreamWarning}(warning_buffer_size)

    task = Threads.@spawn begin
        SoapySDR.Device(dev_args) do dev
            rx_channels = [dev.rx[i] for i in 1:N]
            for (i, (rx, config)) in enumerate(zip(rx_channels, configs))
                apply_config!(rx, config; channel_idx=i)
            end

            stream = SoapySDR.Stream(T, rx_channels)
            mtu = stream.mtu
            nchannels = stream.nchannels

            # Use MTU as output chunk size if not specified
            # rechunk_foreach! handles zero-copy passthrough when mtu == output_chunk_size
            output_chunk_size = chunk_size === nothing ? Int(mtu) : Int(chunk_size)

            buffers_in_flight = ceil(Int, upreferred(buffer_time * sample_rate) / output_chunk_size)
            signal_channel = SignalChannel{T}(output_chunk_size, nchannels, buffers_in_flight)
            put!(setup_channel, signal_channel)
            close(setup_channel)

            buff_ptrs = Vector{Ptr{T}}(undef, nchannels)
            out_flags = Ref{Cint}()
            timens = Ref{Clonglong}()
            sample_rate_val = ustrip(u"Hz", sample_rate)
            total_samples_read = 0

            # RechunkState handles buffer pooling for output chunks
            # Max outputs per MTU read: could complete partial + produce full chunks
            max_outputs = cld(Int(mtu), output_chunk_size) + 1
            num_output_buffers = buffers_in_flight + max_outputs + 2
            rechunk_state = SignalChannels.RechunkState{T}(output_chunk_size, nchannels, num_output_buffers; max_outputs_per_input=max_outputs)

            # In passthrough mode (mtu == output_chunk_size), rechunk! returns the input
            # buffer directly without copying, so we need buffers_in_flight + 2 input buffers
            # to avoid overwriting buffers still in the channel or being read by consumers.
            # When not in passthrough mode, rechunk! copies to its internal buffer pool,
            # so fewer input buffers would suffice, but we use the same count for simplicity.
            num_input_buffers = buffers_in_flight + 2
            input_buffer_pool = [FixedSizeMatrixDefault{T}(fill(zero(T), mtu, nchannels)) for _ in 1:num_input_buffers]
            input_buffer_idx = 1

            SoapySDR.activate!(stream) do
                timeout_us = Int(uconvert(u"μs", 0.9u"s").val)

                # Leadin: discard initial buffers
                for _ in 1:leadin_buffers
                    read_buffer!(stream, input_buffer_pool[1], timeout_us, buff_ptrs, out_flags, timens)
                end

                while true
                    if isa(end_condition, Integer)
                        total_samples_read >= end_condition && break
                    else
                        end_condition.set && break
                    end
                    isopen(signal_channel) || break

                    buff = input_buffer_pool[input_buffer_idx]
                    nread = read_buffer!(stream, buff, timeout_us, buff_ptrs, out_flags, timens)

                    if nread < 0
                        handle_sdr_error!(warning_channel, nread, total_samples_read, sample_rate_val)
                        continue
                    end
                    total_samples_read += nread

                    # Rechunk and put outputs (zero-copy passthrough when mtu == output_chunk_size)
                    outputs = SignalChannels.rechunk!(rechunk_state, buff)
                    if !isempty(outputs)
                        put!(signal_channel.channel, outputs)
                    end
                    input_buffer_idx = mod1(input_buffer_idx + 1, num_input_buffers)
                end
            end
            close(signal_channel)
            close(warning_channel)
        end
    end

    bind(setup_channel, task)
    bind(warning_channel, task)
    signal_channel = take!(setup_channel)
    bind(signal_channel, task)

    return (signal_channel, warning_channel)
end

# Helper to handle SDR read errors
function handle_sdr_error!(warning_channel, nread, total_samples_read, sample_rate_val)
    time_str = format_time(total_samples_read / sample_rate_val)
    if nread == SoapySDR.SOAPY_SDR_OVERFLOW
        push_warning!(warning_channel, SignalChannels.StreamWarning(:overflow, time_str))
    elseif nread == SoapySDR.SOAPY_SDR_TIMEOUT
        push_warning!(warning_channel, SignalChannels.StreamWarning(:timeout, time_str))
    else
        push_warning!(warning_channel, SignalChannels.StreamWarning(:error, time_str, Int(nread), SoapySDR.error_to_string(nread)))
    end
    return nothing
end

"""
    stream_data(dev_args, config::SDRChannelConfig, in::SignalChannel{T}; warning_buffer_size=16, stats_buffer_size=1000) where {T}
    stream_data(dev_args, configs::Tuple{SDRChannelConfig,...}, in::SignalChannel{T}; warning_buffer_size=16, stats_buffer_size=1000) where {T}

Opens an SDR device, configures TX channel(s), and transmits data from a SignalChannel.

The device lifecycle is managed internally - the device stays open as long as the streaming task
is running. When the input channel is closed, the streaming task completes transmission,
then closes the device cleanly.

# Arguments
- `dev_args`: Device arguments (e.g., from `SoapySDR.Devices()[1]`)
- `config`: Single `SDRChannelConfig` applied to all TX channels
- `configs`: Tuple of `SDRChannelConfig` for multi-channel streaming (one per antenna channel)
- `in`: Input `SignalChannel` containing data to transmit (matrix with one column per antenna channel)
- `warning_buffer_size::Integer`: Size of the warning channel buffer (default: 16)
- `stats_buffer_size::Integer`: Size of the stats channel buffer (default: 1000)

# Returns
- `Tuple{Channel{TxStats}, Channel{StreamWarning}}`: Tuple of (stats channel, warning channel).
  The stats channel receives `TxStats` updates after each buffer is transmitted.
  Both channels close when transmission completes.

# Examples
```julia
using SignalChannels
using SoapySDR

# Single channel transmission
config = SDRChannelConfig(
    sample_rate = 5e6u"Hz",
    frequency = 2.4e9u"Hz",
    gain = -10u"dB"
)
data_channel = SignalChannel{ComplexF32}(8192, 1)
stats_channel, warning_channel = stream_data(first(Devices()), config, data_channel)

# Multi-channel with same config for all channels
data_channel_2ch = SignalChannel{ComplexF32}(8192, 2)
stats_channel, warning_channel = stream_data(first(Devices()), config, data_channel_2ch)

# Multi-channel with different configs per channel
configs = (
    SDRChannelConfig(sample_rate=5e6u"Hz", frequency=2.4e9u"Hz", gain=-10u"dB"),
    SDRChannelConfig(sample_rate=5e6u"Hz", frequency=2.5e9u"Hz", gain=-15u"dB"),
)
stats_channel, warning_channel = stream_data(first(Devices()), configs, data_channel_2ch)

# Feed data and monitor progress
@async for stats in stats_channel
    println("Transmitted \$(stats.total_samples) samples")
end
@async for warning in warning_channel
    @warn "TX warning" type=warning.type time=warning.time_str
end

for i in 1:100
    put!(data_channel, generate_transmission_data())
end
close(data_channel)
```
"""
# Single config version - uses same config for all antenna channels in the SignalChannel
function SignalChannels.stream_data(
    dev_args,
    config::SignalChannels.SDRChannelConfig,
    in::SignalChannel{T};
    warning_buffer_size::Integer=16,
    stats_buffer_size::Integer=1000,
) where {T<:Number}
    # Create a tuple of configs matching the number of antenna channels
    N = in.num_antenna_channels
    configs = ntuple(_ -> config, N)
    return SignalChannels.stream_data(dev_args, configs, in; warning_buffer_size, stats_buffer_size)
end

# Multi-config version - one config per antenna channel
function SignalChannels.stream_data(
    dev_args,
    configs::NTuple{N,SignalChannels.SDRChannelConfig},
    in::SignalChannel{T};
    warning_buffer_size::Integer=16,
    stats_buffer_size::Integer=1000,
) where {T<:Number,N}
    if Threads.nthreads() < 2
        error("stream_data requires Julia to be started with multiple threads. " *
              "Start Julia with `julia --threads=auto` or set JULIA_NUM_THREADS environment variable.")
    end

    if in.num_antenna_channels != N
        error("Number of configs ($N) must match number of antenna channels in SignalChannel ($(in.num_antenna_channels))")
    end

    # Validate all configs have the same sample_rate (required for multi-channel streams)
    sample_rate = first(configs).sample_rate
    for (i, config) in enumerate(configs)
        if config.sample_rate != sample_rate
            error("All SDRChannelConfigs must have the same sample_rate for multi-channel TX. " *
                  "Config 1 has $(sample_rate), config $i has $(config.sample_rate)")
        end
    end

    stats_channel = Channel{SignalChannels.TxStats}(stats_buffer_size)
    warning_channel = Channel{SignalChannels.StreamWarning}(warning_buffer_size)

    task = Threads.@spawn begin
        SoapySDR.Device(dev_args) do dev
            # Configure each TX channel with its config
            tx_channels = [dev.tx[i] for i in 1:N]
            for (i, (tx, config)) in enumerate(zip(tx_channels, configs))
                apply_config!(tx, config; channel_idx=i)
            end

            # Create stream with all configured channels
            stream = SoapySDR.Stream(T, tx_channels)
            mtu = stream.mtu
            nchannels = stream.nchannels
            total_samples_written = 0

            # Pre-allocate buffers to avoid allocations in the hot path
            buff_ptrs = Vector{Ptr{T}}(undef, nchannels)
            out_flags = Ref{Cint}(0)

            # Pre-compute sample_rate value to avoid allocations in hot path
            sample_rate_val = ustrip(u"Hz", sample_rate)

            # Batch take size: if input chunks are smaller than MTU, batch take enough
            # to fill at least one MTU. This reduces per-chunk overhead.
            input_chunk_size = in.num_samples
            batch_size = cld(Int(mtu), input_chunk_size)

            # RechunkState to convert input chunks to MTU-sized chunks for efficient SDR writes
            # rechunk! handles zero-copy passthrough when input chunk size == MTU
            # After batch take, we process batch_size * input_chunk_size samples at once
            max_outputs_per_batch = cld(batch_size * input_chunk_size, Int(mtu)) + 1
            # For TX we don't need as many buffers since we write synchronously
            num_buffers = max_outputs_per_batch + 2
            rechunk_state = SignalChannels.RechunkState{T}(Int(mtu), nchannels, num_buffers; max_outputs_per_input=max_outputs_per_batch)

            # Pre-allocate batch buffer for batch takes
            input_batch = Vector{FixedSizeMatrixDefault{T}}(undef, batch_size)

            SoapySDR.activate!(stream) do
                timeout_us = Int(uconvert(u"μs", 0.9u"s").val)

                while isopen(in) || isready(in)
                    # Check if output channels are closed - if so, stop transmitting
                    if !isopen(stats_channel) || !isopen(warning_channel)
                        break
                    end

                    # Batch take from input channel (blocks until all batch_size items available)
                    try
                        take!(in, input_batch)
                    catch e
                        e isa InvalidStateException && break
                        rethrow()
                    end

                    # Rechunk entire batch to MTU-sized buffers (zero-copy passthrough when sizes match)
                    outputs = SignalChannels.rechunk!(rechunk_state, input_batch)

                    for buff in outputs
                        samples_to_write = size(buff, 1)
                        total_nwritten = 0

                        GC.@preserve buff while total_nwritten < samples_to_write
                            # Update pointers for current write position
                            for j in 1:nchannels
                                buff_ptrs[j] = pointer(buff, (j - 1) * samples_to_write + total_nwritten + 1)
                            end
                            out_flags[] = Cint(0)
                            nwritten = SoapySDR.SoapySDRDevice_writeStream(
                                stream.d,
                                stream,
                                pointer(buff_ptrs),
                                samples_to_write - total_nwritten,
                                out_flags,
                                0,
                                timeout_us,
                            )

                            if nwritten < 0
                                expected_sample_seconds = total_samples_written / sample_rate_val
                                time_str = format_time(expected_sample_seconds)

                                if nwritten == SoapySDR.SOAPY_SDR_UNDERFLOW
                                    push_warning!(warning_channel, SignalChannels.StreamWarning(:underflow, time_str))
                                elseif nwritten == SoapySDR.SOAPY_SDR_TIMEOUT
                                    push_warning!(warning_channel, SignalChannels.StreamWarning(:timeout, time_str))
                                else
                                    push_warning!(warning_channel, SignalChannels.StreamWarning(:error, time_str, Int(nwritten), SoapySDR.error_to_string(nwritten)))
                                end
                                break
                            else
                                total_nwritten += nwritten
                                total_samples_written += nwritten
                            end
                        end
                    end

                    # Push stats after each batch is processed (blocking)
                    # If the channel is closed, this will throw and we exit
                    try
                        put!(stats_channel, SignalChannels.TxStats(total_samples_written))
                    catch e
                        e isa InvalidStateException && break
                        rethrow()
                    end
                end

                # Wait for transmission to complete before deactivating
                sleep(1)
            end
        end
        close(stats_channel)
        close(warning_channel)
    end

    bind(stats_channel, task)
    bind(warning_channel, task)
    bind(in, task) # Propagate errors upwards
    return (stats_channel, warning_channel)
end

"""
    sdr_periodogram_liveplot(;
        sampling_freq = 5e6u"Hz",
        dev_args = first(Devices()),
        center_freq = 1.5754e9u"Hz",
        gain::Union{Nothing,<:Unitful.Gain} = 50u"dB",
        num_samples_per_chunk = 8192,
        window = hamming,
        update_rate = 100u"ms",
    )

Convenience function to stream SDR data and display a live periodogram with warning capture.
Press Ctrl+C to stop.

This high-level function combines all the pieces needed for real-time spectrum analysis:
- Configures an SDR device
- Creates a data stream
- Buffers incoming data
- Rechunks to desired size
- Computes periodograms
- Displays live plot with captured warnings

# Arguments
- `sampling_freq`: Sampling frequency (default: 5 MHz)
- `dev_args`: Device arguments, defaults to first available device
- `center_freq`: Center frequency for SDR (default: 1.5754 GHz)
- `gain`: Receiver gain, or `nothing` for automatic gain control (default: 50 dB)
- `num_samples_per_chunk`: Number of samples per processing chunk (default: 8192)
- `window`: Window function for periodogram (default: `hamming`)
- `update_rate`: How often to update the periodogram display (default: 100 ms)

# Examples
```julia
using SignalChannels
using SoapySDR

# Use defaults (first device, 1.5754 GHz, 5 MHz sampling, 50 dB gain)
# Press Ctrl+C to stop
sdr_periodogram_liveplot()

# Custom frequency and gain
sdr_periodogram_liveplot(center_freq = 2.4e9u"Hz", gain = 40u"dB")

# Automatic gain control
sdr_periodogram_liveplot(gain = nothing)

# Different update rate
sdr_periodogram_liveplot(update_rate = 50u"ms")
```
"""
function SignalChannels.sdr_periodogram_liveplot(;
    sampling_freq=5e6u"Hz",
    dev_args=first(Devices()),
    center_freq=1.57542e9u"Hz",
    gain::Union{Nothing,<:Unitful.Gain}=50u"dB",
    num_samples_per_chunk=8192,
    window=hamming,
    update_rate=100u"ms",
)
    config = SignalChannels.SDRChannelConfig(
        sample_rate=sampling_freq,
        frequency=center_freq,
        gain=gain,
    )

    # Use an Event to allow stopping with Ctrl+C
    stop_event = Base.Event()

    # Getting samples in chunks - runs until stop_event is triggered
    data_stream, warning_channel = SignalChannels.stream_data(dev_args, config, stop_event)

    # Rechunk to desired size
    rechunked_stream = SignalChannels.rechunk(data_stream, num_samples_per_chunk)

    # Create periodogram processing channel
    pgram_channel =
        SignalChannels.calculate_periodogram(rechunked_stream, sampling_freq; window, push_roughly_every=update_rate)

    # Display the GUI using LivePlot with warning display
    try
        SignalChannels.periodogram_liveplot(pgram_channel; warning_channel, stop_instruction="Press Ctrl+C to stop")
    catch e
        notify(stop_event)
        if !isa(e, InterruptException)
            rethrow(e)
        end
    finally
        notify(stop_event)
        # Drain channels to allow clean shutdown
        for _ in pgram_channel
        end
        for _ in warning_channel
        end
    end
end

"""
    sdr_record_to_file(
        file_path::String;
        sampling_freq = 5e6u"Hz",
        num_samples = 10_000_000,
        dev_args = first(Devices()),
        center_freq = 1.5754e9u"Hz",
        gain::Union{Nothing,<:Unitful.Gain} = 50u"dB",
    )

Convenience function to record SDR data directly to file(s).

This high-level function combines all the pieces needed for recording:
- Configures an SDR device
- Creates a data stream
- Writes data to files

Files are created with the pattern: `{file_path}{Type}{channel_number}.dat`

# Arguments
- `file_path`: Base file path (without extension) for output files
- `sampling_freq`: Sampling frequency (default: 5 MHz)
- `num_samples`: Total number of samples to record (default: 10 million)
- `dev_args`: Device arguments, defaults to first available device
- `center_freq`: Center frequency for SDR (default: 1.5754 GHz)
- `gain`: Receiver gain, or `nothing` for automatic gain control (default: 50 dB)

# Examples
```julia
using SignalChannels
using SoapySDR

# Record 10 million samples at 1.5754 GHz to files
sdr_record_to_file("recording")

# Record 50 million samples at 2.4 GHz with custom gain
sdr_record_to_file("wifi_capture",
    num_samples = 50_000_000,
    center_freq = 2.4e9u"Hz",
    gain = 40u"dB"
)

# Record with automatic gain control
sdr_record_to_file("auto_gain_recording", gain = nothing)
```
"""
function SignalChannels.sdr_record_to_file(
    file_path::String;
    sampling_freq=5e6u"Hz",
    num_samples=10_000_000,
    dev_args=first(Devices()),
    center_freq=1.57542e9u"Hz",
    gain::Union{Nothing,<:Unitful.Gain}=50u"dB",
)
    config = SignalChannels.SDRChannelConfig(
        sample_rate=sampling_freq,
        frequency=center_freq,
        gain=gain,
    )

    # Getting samples in chunks
    data_stream, warning_channel = SignalChannels.stream_data(dev_args, config, num_samples)

    # Write directly to file
    write_task = SignalChannels.write_to_file(data_stream, file_path)
    wait(write_task)

    # Print any warnings that occurred during recording
    for warning in warning_channel
        @warn "SDR warning" type = warning.type time = warning.time_str
    end
end

end # module SignalChannelsSoapySDRExt
