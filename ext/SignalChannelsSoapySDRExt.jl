module SignalChannelsSoapySDRExt

using SignalChannels
using SoapySDR
using Unitful
using FixedSizeArrays: FixedSizeMatrixDefault
using DSP: hamming

# Helper for turning a matrix into a tuple of views, for use with the SoapySDR API.
function split_matrix(m::AbstractMatrix{T}) where {T<:Number}
    return [view(m, :, idx) for idx = 1:size(m, 2)]
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

"""
    stream_data(s_rx::SoapySDR.Stream{T}, end_condition::Union{Integer,Base.Event}; leadin_buffers=16, warning_buffer_size=16, buffers_in_flight=1) where {T <: Number}

Returns a tuple of `(SignalChannel, Channel{StreamWarning})` for streaming data and receiving warnings.
The signal channel will yield buffers of data to be processed of size `s_rx.mtu`.
Starts an asynchronous task that reads from the stream until the requested number of samples
are read, or the given `Event` is notified.

This function uses direct C API calls for better performance. Errors (overflow, timeout, etc.)
are pushed to the warning channel with timing information, rather than being logged directly.

## Error handling

On read errors (overflow, timeout, etc.), the buffer is still pushed to the channel even though
it may contain partial new data mixed with stale data from the previous read. This is intentional:
applications like GNSS receivers rely on a steady stream of samples and can often recover from
corrupted data, but gaps in the stream cause them to lose signal tracking.

Warnings are pushed to the warning channel without blocking. If the warning channel is full,
the warning is silently dropped to avoid impacting real-time streaming performance.

# Arguments
- `s_rx::SoapySDR.Stream{T}`: SoapySDR receive stream
- `end_condition::Union{Integer,Base.Event}`: Either total number of samples to read, or an Event to signal stop
- `leadin_buffers::Integer`: Number of initial buffers to discard (default: 16)
- `warning_buffer_size::Integer`: Size of the warning channel buffer (default: 16)
- `buffers_in_flight::Integer`: Number of buffers that can be in flight (default: 1)

# Returns
- `Tuple{SignalChannel{T}, Channel{StreamWarning}}`: Tuple of (signal channel, warning channel)

# Examples
```julia
using SignalChannels
using SoapySDR

Device(args) do dev
    stream = SoapySDR.Stream(ComplexF32, dev.rx[1])

    # Read 10 million samples
    data_channel, warning_channel = stream_data(stream, 10_000_000)

    # Process data in one task
    @async for data in data_channel
        # Process data
    end

    # Monitor warnings in another task
    @async for warning in warning_channel
        @warn "Stream warning" type=warning.type time=warning.time_str
    end
end
```
"""
function SignalChannels.stream_data(s_rx::SoapySDR.Stream{T}, end_condition::Union{Integer,Base.Event};
    leadin_buffers::Integer=16,
    warning_buffer_size::Integer=16,
    buffers_in_flight::Integer=1) where {T<:Number}

    # Create channels
    signal_channel = SignalChannel{T}(s_rx.mtu, s_rx.nchannels, buffers_in_flight)
    warning_channel = Channel{SignalChannels.StreamWarning}(warning_buffer_size)

    sample_rate = first(s_rx.d.rx).sample_rate

    task = Threads.@spawn begin
        # Pre-allocate a pool of buffers to avoid allocations during streaming.
        # We need buffers_in_flight + 1 buffers: one for each slot in the channel
        # plus one for the current write operation.
        num_buffers = buffers_in_flight + 1
        buffer_pool = [FixedSizeMatrixDefault{T}(undef, s_rx.mtu, s_rx.nchannels) for _ in 1:num_buffers]
        buffer_idx = 1
        total_samples_read = 0
        buff_idx = 0

        SoapySDR.activate!(s_rx) do
            # Let the stream come online for a bit (leadin) - reuse first buffer from pool
            for _ in 1:leadin_buffers
                read!(s_rx, split_matrix(buffer_pool[1]))
            end

            # Read streams until we read the number of samples, or the given event is triggered
            timeout_us = uconvert(u"μs", 0.9u"s").val

            while true
                # Check end condition
                if isa(end_condition, Integer)
                    buff_idx * s_rx.mtu >= end_condition && break
                else
                    end_condition.set && break
                end

                buff = buffer_pool[buffer_idx]

                # Read directly using the C API to avoid exception overhead
                buffers = split_matrix(buff)
                samples_to_read = length(first(buffers))
                total_nread = 0

                GC.@preserve buffers while total_nread < samples_to_read
                    buff_ptrs = pointer(map(b -> pointer(b, total_nread + 1), buffers))
                    out_flags = Ref{Cint}()
                    timens = Ref{Clonglong}()
                    nread = SoapySDR.SoapySDRDevice_readStream(
                        s_rx.d,
                        s_rx,
                        buff_ptrs,
                        samples_to_read - total_nread,
                        out_flags,
                        timens,
                        timeout_us,
                    )

                    # Check for errors in the return value
                    if nread < 0
                        # Calculate expected sample time based on sample rate
                        expected_sample_seconds = total_samples_read / uconvert(u"Hz", sample_rate).val
                        time_str = format_time(expected_sample_seconds)

                        if nread == SoapySDR.SOAPY_SDR_OVERFLOW
                            push_warning!(warning_channel, SignalChannels.StreamWarning(:overflow, time_str))
                        elseif nread == SoapySDR.SOAPY_SDR_TIMEOUT
                            push_warning!(warning_channel, SignalChannels.StreamWarning(:timeout, time_str))
                        else
                            push_warning!(warning_channel, SignalChannels.StreamWarning(:error, time_str, Int(nread), SoapySDR.error_to_string(nread)))
                        end
                        # On error, we still push the buffer even though it may contain partial new data
                        # mixed with stale data from the previous read. This is intentional: applications
                        # like GNSS receivers rely on a steady stream of samples and can often recover
                        # from corrupted data, but gaps in the stream cause them to lose signal tracking.
                        break
                    else
                        total_nread += nread
                        total_samples_read += nread
                    end
                end

                # Push the buffer and rotate to the next one
                put!(signal_channel, buff)
                buffer_idx = mod1(buffer_idx + 1, num_buffers)
                buff_idx += 1
            end
        end

        close(signal_channel)
        close(warning_channel)
    end

    bind(signal_channel, task)
    bind(warning_channel, task)

    return (signal_channel, warning_channel)
end

"""
    stream_data(s_tx::SoapySDR.Stream{T}, in::SignalChannel{T}; warning_buffer_size=16) where {T <: Number}

Feed data from a `SignalChannel` out onto the airwaves via a given `SoapySDR.Stream`.
We suggest using `rechunk()` to convert to `s_tx.mtu`-sized buffers for maximum efficiency.

This function uses direct C API calls for better performance. Errors (underflow, timeout, etc.)
are pushed to the warning channel with timing information, rather than being logged directly.

The transmission runs asynchronously in a spawned task. The warning channel is bound to the task,
so it will be closed automatically when the task completes (and any exceptions will be propagated).

Warnings are pushed to the warning channel without blocking. If the warning channel is full,
the warning is silently dropped to avoid impacting real-time streaming performance.

# Arguments
- `s_tx::SoapySDR.Stream{T}`: SoapySDR transmit stream
- `in::SignalChannel{T}`: Input channel containing data to transmit
- `warning_buffer_size::Integer`: Size of the warning channel buffer (default: 16)

# Returns
- `Channel{StreamWarning}`: Warning channel (closes when transmission completes)

# Examples
```julia
using SignalChannels
using SoapySDR

Device(args) do dev
    stream = SoapySDR.Stream(ComplexF32, dev.tx[1])

    # Create a channel with data to transmit
    data_channel = SignalChannel{ComplexF32}(stream.mtu, stream.nchannels)

    # Start transmission
    warning_channel = stream_data(stream, data_channel)

    # Monitor warnings in another task
    @async for warning in warning_channel
        @warn "TX warning" type=warning.type time=warning.time_str
    end

    # Feed data into the channel
    for i in 1:100
        data = generate_transmission_data()
        put!(data_channel, data)
    end
    close(data_channel)

    # Wait for transmission to complete by waiting for warning channel to close
    for warning in warning_channel
        @warn "TX warning" type=warning.type time=warning.time_str
    end
end
```
"""
function SignalChannels.stream_data(s_tx::SoapySDR.Stream{T}, in::SignalChannel{T}; warning_buffer_size::Integer=16) where {T<:Number}
    # Track total samples written for timing calculations
    total_samples_written = 0
    sample_rate = first(s_tx.d.tx).sample_rate

    # Create warning channel - non-blocking pushes, silently drop if full
    warning_channel = Channel{SignalChannels.StreamWarning}(warning_buffer_size)

    task = Threads.@spawn begin
        SoapySDR.activate!(s_tx) do
            # Consume channel and transmit data via s_tx
            SignalChannels.consume_channel(in) do buff
                # Write with a custom wrapper to intercept errors without exceptions
                buffers = split_matrix(buff)
                samples_to_write = length(first(buffers))
                total_nwritten = 0
                timeout_us = uconvert(u"μs", 0.9u"s").val

                GC.@preserve buffers while total_nwritten < samples_to_write
                    buff_ptrs = pointer(map(b -> pointer(b, total_nwritten + 1), buffers))
                    out_flags = Ref{Cint}(0)
                    nwritten = SoapySDR.SoapySDRDevice_writeStream(
                        s_tx.d,
                        s_tx,
                        buff_ptrs,
                        samples_to_write - total_nwritten,
                        out_flags,
                        0,
                        timeout_us,
                    )

                    # Check for errors in the return value
                    if nwritten < 0
                        # Calculate expected sample time based on sample rate
                        expected_sample_seconds = total_samples_written / uconvert(u"Hz", sample_rate).val
                        time_str = format_time(expected_sample_seconds)

                        if nwritten == SoapySDR.SOAPY_SDR_UNDERFLOW
                            push_warning!(warning_channel, SignalChannels.StreamWarning(:underflow, time_str))
                        elseif nwritten == SoapySDR.SOAPY_SDR_TIMEOUT
                            push_warning!(warning_channel, SignalChannels.StreamWarning(:timeout, time_str))
                        else
                            push_warning!(warning_channel, SignalChannels.StreamWarning(:error, time_str, Int(nwritten), SoapySDR.error_to_string(nwritten)))
                        end
                        break  # Exit on error
                    else
                        total_nwritten += nwritten
                        total_samples_written += nwritten
                    end
                end
            end

            # We need to sleep() until we're done transmitting,
            # otherwise we deactivate!() a little bit too eagerly.
            sleep(1)
        end
    end
    bind(warning_channel, task)
    Base.errormonitor(task)
    return warning_channel
end

"""
    sdr_periodogram_liveplot(;
        sampling_freq = 5e6u"Hz",
        run_time = 40u"s",
        dev_args = first(Devices()),
        center_freq = 1.5754e9u"Hz",
        gain::Union{Nothing,<:Unitful.Gain} = 50u"dB",
        num_samples_per_chunk = 8192,
        window = hamming,
        update_rate = 100u"ms",
    )

Convenience function to stream SDR data and display a live periodogram with warning capture.

This high-level function combines all the pieces needed for real-time spectrum analysis:
- Configures an SDR device
- Creates a data stream
- Buffers incoming data
- Rechunks to desired size
- Computes periodograms
- Displays live plot with captured warnings

# Arguments
- `sampling_freq`: Sampling frequency (default: 5 MHz)
- `run_time`: Total runtime for data collection (default: 40 seconds)
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
    run_time=40u"s",
    dev_args=first(Devices()),
    center_freq=1.57542e9u"Hz",
    gain::Union{Nothing,<:Unitful.Gain}=50u"dB",
    num_samples_per_chunk=8192,
    window=hamming,
    update_rate=100u"ms",
)
    eval_num_samples = Int(upreferred(sampling_freq * run_time))

    Device(dev_args) do dev
        # Configure receiver
        rx = dev.rx[1]
        rx.sample_rate = sampling_freq
        rx.bandwidth = sampling_freq
        rx.frequency = center_freq

        if isnothing(gain)
            rx.gain_mode = true
        else
            rx.gain = gain
        end

        # Create stream
        stream = SoapySDR.Stream(rx.native_stream_format, rx)

        # Getting samples in chunks
        data_stream, warning_channel = SignalChannels.stream_data(stream, eval_num_samples)

        # Rechunk to desired size
        rechunked_stream = SignalChannels.rechunk(data_stream, num_samples_per_chunk)

        # Create periodogram processing channel
        pgram_channel =
            SignalChannels.calculate_periodogram(rechunked_stream, sampling_freq; window, push_roughly_every=update_rate)

        # Display the GUI using LivePlot with warning display
        SignalChannels.periodogram_liveplot(pgram_channel; warning_channel)
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
    Device(dev_args) do dev
        # Configure receiver
        rx = dev.rx[1]
        rx.sample_rate = sampling_freq
        rx.bandwidth = sampling_freq
        rx.frequency = center_freq

        if isnothing(gain)
            rx.gain_mode = true
        else
            rx.gain = gain
        end

        # Create stream
        stream = SoapySDR.Stream(rx.native_stream_format, rx)

        # Getting samples in chunks (ignore warning channel for this convenience function)
        data_stream, _ = SignalChannels.stream_data(stream, num_samples)

        # Write directly to file
        task = SignalChannels.write_to_file(data_stream, file_path)
        wait(task)
    end
end

end # module SignalChannelsSoapySDRExt
