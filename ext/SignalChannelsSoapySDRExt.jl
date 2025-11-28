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

"""
    generate_stream(f::Function, s::SoapySDR.Stream{T}; kwargs...) where {T <: Number}

Generate a stream from a SoapySDR Stream object. This is a convenience method that
automatically uses the stream's MTU and number of channels.

# Arguments
- `f::Function`: Buffer generation function
- `s::SoapySDR.Stream{T}`: SoapySDR stream object
- `kwargs...`: Additional arguments passed to `generate_stream`

# Examples
```julia
using SignalChannels
using SoapySDR

# Assuming you have a SoapySDR stream `s_rx`
chan = generate_stream(s_rx) do buff
    # Fill buffer with data
    read!(s_rx, split_matrix(buff))
    return true
end
```
"""
function SignalChannels.generate_stream(f::Function, s::SoapySDR.Stream{T}; kwargs...) where {T<:Number}
    return SignalChannels.generate_stream(f, s.mtu, s.nchannels; T, kwargs...)
end

"""
    stream_data(s_rx::SoapySDR.Stream{T}, end_condition::Union{Integer,Base.Event}; leadin_buffers=16, kwargs...) where {T <: Number}

Returns a `SignalChannel` which will yield buffers of data to be processed of size `s_rx.mtu`.
Starts an asynchronous task that reads from the stream until the requested number of samples
are read, or the given `Event` is notified.

This function uses direct C API calls for better performance and provides detailed error reporting
with timing information. Errors (overflow, timeout, etc.) are logged as warnings with the expected
sample time elapsed before the error occurred.

# Arguments
- `s_rx::SoapySDR.Stream{T}`: SoapySDR receive stream
- `end_condition::Union{Integer,Base.Event}`: Either total number of samples to read, or an Event to signal stop
- `leadin_buffers::Integer`: Number of initial buffers to discard (default: 16)
- `kwargs...`: Additional arguments passed to `generate_stream`

# Returns
- `SignalChannel{T}`: Channel yielding matrices of size (mtu, nchannels)

# Examples
```julia
using SignalChannels
using SoapySDR

Device(args) do dev
    stream = SoapySDR.Stream(ComplexF32, dev.rx[1])

    # Read 10 million samples
    data_channel = stream_data(stream, 10_000_000)

    for data in data_channel
        # Process data
    end
end
```
"""
function SignalChannels.stream_data(s_rx::SoapySDR.Stream{T}, end_condition::Union{Integer,Base.Event};
    leadin_buffers::Integer=16,
    kwargs...) where {T<:Number}
    # Track total samples read for timing calculations
    total_samples_read = 0
    sample_rate = first(s_rx.d.rx).sample_rate

    # Wrapper to activate/deactivate `s_rx`
    wrapper = (f) -> begin
        buff = FixedSizeMatrixDefault{T}(undef, s_rx.mtu, s_rx.nchannels)

        # Let the stream come online for a bit
        SoapySDR.activate!(s_rx) do
            while leadin_buffers > 0
                read!(s_rx, split_matrix(buff))
                leadin_buffers -= 1
            end

            # Invoke the rest of `generate_stream()`
            f()
        end
    end

    # Read streams until we read the number of samples, or the given event
    # is triggered
    buff_idx = 0
    return SignalChannels.generate_stream(s_rx.mtu, s_rx.nchannels; wrapper, T, kwargs...) do buff
        if isa(end_condition, Integer)
            if buff_idx * s_rx.mtu >= end_condition
                return false
            end
        else
            if end_condition.set
                return false
            end
        end

        # Read directly using the C API to avoid exception overhead
        buffers = split_matrix(buff)
        samples_to_read = length(first(buffers))
        total_nread = 0
        timeout_us = uconvert(u"μs", 0.9u"s").val

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
                    @warn("Overflow at $time_str")
                elseif nread == SoapySDR.SOAPY_SDR_TIMEOUT
                    @warn("Timeout at $time_str")
                else
                    @warn("Read error at $time_str", error_code = nread, error_string = SoapySDR.error_to_string(nread))
                end
                break  # Exit on error
            else
                total_nread += nread
                total_samples_read += nread
            end
        end

        buff_idx += 1
        return true
    end
end

"""
    stream_data(s_tx::SoapySDR.Stream{T}, in::SignalChannel{T}) where {T <: Number}

Feed data from a `SignalChannel` out onto the airwaves via a given `SoapySDR.Stream`.
We suggest using `rechunk()` to convert to `s_tx.mtu`-sized buffers for maximum efficiency.

This function uses direct C API calls for better performance and provides detailed error reporting
with timing information. Errors (underflow, timeout, etc.) are logged as warnings with the expected
sample time elapsed before the error occurred.

The transmission runs asynchronously in a spawned task. The task is bound to the input channel,
so if the task fails, the channel will be closed automatically.

# Arguments
- `s_tx::SoapySDR.Stream{T}`: SoapySDR transmit stream
- `in::SignalChannel{T}`: Input channel containing data to transmit

# Returns
- `Task`: Asynchronous task handle for the transmission process

# Examples
```julia
using SignalChannels
using SoapySDR

Device(args) do dev
    stream = SoapySDR.Stream(ComplexF32, dev.tx[1])

    # Create a channel with data to transmit
    data_channel = SignalChannel{ComplexF32}(stream.mtu, stream.nchannels)

    # Start transmission
    tx_task = stream_data(stream, data_channel)

    # Feed data into the channel
    for i in 1:100
        data = generate_transmission_data()
        put!(data_channel, data)
    end
    close(data_channel)

    # Wait for transmission to complete
    wait(tx_task)
end
```
"""
function SignalChannels.stream_data(s_tx::SoapySDR.Stream{T}, in::SignalChannel{T}) where {T<:Number}
    # Track total samples written for timing calculations
    total_samples_written = 0
    sample_rate = first(s_tx.d.tx).sample_rate

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
                            @warn("Underflow at $time_str")
                        elseif nwritten == SoapySDR.SOAPY_SDR_TIMEOUT
                            @warn("Timeout at $time_str")
                        else
                            @warn("Write error at $time_str", error_code = nwritten, error_string = SoapySDR.error_to_string(nwritten))
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
    bind(in, task)
    return task
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
        data_stream = SignalChannels.stream_data(stream, eval_num_samples)

        # Rechunk to desired size
        rechunked_stream = SignalChannels.rechunk(data_stream, num_samples_per_chunk)

        # Create periodogram processing channel
        pgram_channel =
            SignalChannels.calculate_periodogram(rechunked_stream, sampling_freq; window, push_roughly_every=update_rate)

        # Display the GUI using LivePlot
        SignalChannels.periodogram_liveplot(pgram_channel)
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

        # Getting samples in chunks
        data_stream = SignalChannels.stream_data(stream, num_samples)

        # Write directly to file
        SignalChannels.write_to_file(data_stream, file_path)
    end
end

end # module SignalChannelsSoapySDRExt
