# SignalChannels.jl

A Julia package for streaming signal processing with multi-channel support. SignalChannels provides type-safe channel abstractions and utilities for handling matrix-shaped data streams from various sources including SDR hardware, files, and synthetic signal generators.

## Features

- **SignalChannel**: Type-safe channels that enforce matrix dimensions for multi-antenna/multi-channel data
- **Channel Utilities**: Tools for consuming, splitting (tee), rechunking, and file I/O
- **Stream Utilities**: Helpers for generating and buffering signal streams
- **Periodogram Analysis**: Real-time spectrum analysis with live visualization and warning capture
- **SoapySDR Extension**: Optional integration with SoapySDR for SDR recording and real-time streaming
- **Thread-Safe**: Built on Julia's native concurrency primitives
- **Flexible Sources**: Works with SDR hardware, file streams, or programmatically generated signals

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaGNSS/SignalChannels.jl.git")
```

## Quick Start

### Creating a SignalChannel

```julia
using SignalChannels

# Create a channel for 1024 samples across 4 antenna channels
chan = SignalChannel{ComplexF32}(1024, 4)

# Producer task
@async begin
    for i in 1:10
        data = rand(ComplexF32, 1024, 4)
        put!(chan, data)
    end
    close(chan)
end

# Consumer
for data in chan
    # Process each 1024x4 matrix
    println("Received $(size(data)) matrix")
end
```

### Rechunking

```julia
# Convert 512-sample chunks to 2048-sample chunks
input = SignalChannel{ComplexF32}(512, 4)
output = rechunk(input, 2048)
```

### Tee (Split) a Stream

```julia
input = SignalChannel{ComplexF32}(1024, 4)
out1, out2 = tee(input)

# Both out1 and out2 receive the same data
```

### File I/O

```julia
# Writing to files
chan = SignalChannel{ComplexF32}(1024, 4)
write_to_file(chan, "/home/user/data_path_")
# Creates: /home/user/data_path_ComplexF321.dat, /home/user/data_path_ComplexF322.dat, etc.

# Reading from files
output_chan = read_from_file("/home/user/data_path_", 1024, 4; T=ComplexF32)
for data in output_chan
    # Process data
end
```

### Buffering for Real-Time Applications

```julia
# Add buffering to handle bursty data
buffered = membuffer(input_chan, 32)  # Buffer up to 32 matrices
```

### SoapySDR Integration (Extension)

When you have SoapySDR.jl installed, SignalChannels automatically loads additional functionality for streaming from SDR hardware.

**Note:** The SoapySDR extension requires Julia to be started with multiple threads (`julia --threads=auto` or set `JULIA_NUM_THREADS=auto`).

```julia
using SignalChannels
using SoapySDR  # Extension loads automatically
using Unitful

# Configure SDR channel with SDRChannelConfig
config = SDRChannelConfig(
    sample_rate = 2.5e6u"Hz",
    frequency = 1.5e9u"Hz",
    gain = 40u"dB"
)

# Stream a fixed number of samples
data_channel, warning_channel = stream_data(first(Devices()), config, 10_000_000)

# Or use an Event to control streaming duration
stop_event = Base.Event()
data_channel, warning_channel = stream_data(first(Devices()), config, stop_event)

# Process data
for data in data_channel
    # Process SDR data
    if should_stop
        notify(stop_event)
        break
    end
end
```

### High-Level SDR Functions

For common SDR workflows, use these convenience functions:

```julia
using SignalChannels
using SoapySDR

# Quick spectrum analysis with live plot
sdr_periodogram_liveplot(
    center_freq = 1.57542e9u"Hz",
    sampling_freq = 5e6u"Hz",
    gain = 50u"dB"
)

# Record SDR data directly to file
sdr_record_to_file(
    "my_recording",
    num_samples = 10_000_000,
    center_freq = 2.4e9u"Hz"
)
```

The extension provides:
- `SDRChannelConfig` - Configuration struct for SDR channels (sample_rate, frequency, gain, bandwidth, antenna)
- `TxStats` - Statistics struct for TX streams (total_samples transmitted)
- `stream_data(dev_args, config, end_condition)` - Stream RX data from SoapySDR devices (returns data and warning channels)
- `stream_data(dev_args, config, input_channel)` - Stream TX data to SoapySDR devices (returns stats and warning channels)
- `sdr_periodogram_liveplot(...)` - Live spectrum analysis with real-time plotting
- `sdr_record_to_file(path, ...)` - One-line SDR recording to files

## API Reference

### Core Types

#### `SignalChannel{T}`
A channel that enforces matrix dimensions for type safety in multi-channel signal processing.

**Constructors:**
- `SignalChannel{T}(num_samples, num_antenna_channels, [buffer_size])`
- `SignalChannel{T}(func, num_samples, num_antenna_channels, [buffer_size])`

### Channel Utilities

- `consume_channel(f, channel, args...)` - Process all data from a channel until it closes
- `consume_channel_with_warnings(f, channel; max_warnings=20)` - Process data while capturing stderr warnings
- `tee(channel)` - Split a channel into two synchronized outputs
- `rechunk(channel, new_size)` - Convert chunk sizes in a stream
- `write_to_file(channel, filepath)` - Write channel data to files
- `read_from_file(filepath, num_samples, num_channels; T=ComplexF32)` - Read data from files into a channel

### Stream Utilities

- `spawn_signal_channel_thread(f; T, num_samples, num_antenna_channels, buffers_in_flight)` - Run function in separate thread with SignalChannel output
- `membuffer(channel, max_size)` - Add buffering for real-time applications

### Periodogram Analysis

- `PeriodogramData` - Data structure containing frequency bins, power values, and timestamp
- `calculate_periodogram(channel, sampling_freq; window=hamming, push_roughly_every=100u"ms")` - Compute periodograms from signal stream
- `periodogram_liveplot(periodogram_channel)` - Display live periodogram with warning capture

## Use Cases

- **Multi-antenna GNSS receivers**: Process signals from multiple antennas simultaneously
- **Software Defined Radio (SDR)**: Handle real-time SDR data streams with recording and visualization
- **Spectrum analysis**: Real-time periodogram visualization with warning monitoring
- **Signal processing pipelines**: Chain processing stages with type-safe channels
- **File-based signal processing**: Read and write multi-channel signal data
- **Testing and simulation**: Generate synthetic multi-channel signals

## Thread Safety

SignalChannels is built on Julia's thread-safe `Channel` primitive. All operations are safe for concurrent access from multiple tasks/threads.

## Performance Considerations

- **Zero-copy views**: Use views when possible to avoid unnecessary allocations
- **Buffer sizing**: Tune `buffers_in_flight` parameter for your workload
- **Rechunking overhead**: Minimize rechunking operations in hot paths
- **Thread spawning**: Use `spawn=true` to distribute work across threads

## Related Packages

- [SoapySDR.jl](https://github.com/JuliaTelecom/SoapySDR.jl) - Julia bindings for SoapySDR
- [DSP.jl](https://github.com/JuliaDSP/DSP.jl) - Digital signal processing in Julia
- [LiveLayoutUnicodePlots.jl](https://github.com/zsoerenm/LiveLayoutUnicodePlots.jl) - Live plotting in the terminal

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
