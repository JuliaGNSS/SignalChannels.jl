# SignalChannels.jl

A Julia package for streaming signal processing with multi-channel support. SignalChannels provides type-safe channel abstractions and utilities for handling matrix-shaped data streams from various sources including SDR hardware, files, and synthetic signal generators.

## Features

- **SignalChannel**: Type-safe channels that enforce matrix dimensions for multi-antenna/multi-channel data
- **Channel Utilities**: Tools for consuming, splitting (tee), rechunking, and file I/O
- **Stream Utilities**: Helpers for generating and buffering signal streams
- **SoapySDR Extension**: Optional integration with SoapySDR for real-time SDR data streaming
- **Thread-Safe**: Built on Julia's native concurrency primitives
- **Flexible Sources**: Works with SDR hardware, file streams, or programmatically generated signals

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/yourusername/SignalChannels.jl")
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

### Stream Generation

```julia
# Generate a synthetic signal stream
chan = generate_stream(1024, 2; T=ComplexF32) do buff
    buff .= rand(ComplexF32, size(buff))
    return true  # Continue generating
end

# Process the stream
for data in chan
    # Process data
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

### Writing to Files

```julia
chan = SignalChannel{ComplexF32}(1024, 4)

# Writes to files: data_pathComplexF321.dat, data_pathComplexF322.dat, etc.
write_to_file(chan, "data_path")
```

### Buffering for Real-Time Applications

```julia
# Add buffering to handle bursty data
buffered = membuffer(input_chan, 32)  # Buffer up to 32 matrices
```

### SoapySDR Integration (Extension)

When you have SoapySDR.jl installed, SignalChannels automatically loads additional functionality for streaming from SDR hardware:

```julia
using SignalChannels
using SoapySDR  # Extension loads automatically

# Open SDR device
Device(first(Devices())) do dev
    # Configure receiver
    dev.rx[1].sample_rate = 2.5e6u"Hz"
    dev.rx[1].frequency = 1.5e9u"Hz"
    dev.rx[1].gain = 40u"dB"

    # Create stream
    stream = SoapySDR.Stream(ComplexF32, dev.rx[1])

    # Stream data from SDR
    data_channel = stream_data(stream, 10_000_000)  # Read 10M samples

    # Or use an Event to control streaming
    stop_event = Base.Event()
    data_channel = stream_data(stream, stop_event)

    # Process data
    for data in data_channel
        # Process SDR data
        if should_stop
            notify(stop_event)
            break
        end
    end
end
```

The extension provides:
- `stream_data(stream, end_condition; leadin_buffers=16)` - Stream data from SoapySDR devices
- `generate_stream(f, stream::SoapySDR.Stream)` - Convenience method for SoapySDR streams

## API Reference

### Core Types

#### `SignalChannel{T}`
A channel that enforces matrix dimensions for type safety in multi-channel signal processing.

**Constructors:**
- `SignalChannel{T}(num_samples, num_antenna_channels, [buffer_size])`
- `SignalChannel{T}(func, num_samples, num_antenna_channels, [buffer_size])`

### Channel Utilities

- `consume_channel(f, channel, args...)` - Process all data from a channel until it closes
- `tee(channel)` - Split a channel into two synchronized outputs
- `rechunk(channel, new_size)` - Convert chunk sizes in a stream
- `write_to_file(channel, filepath)` - Write channel data to files

### Stream Utilities

- `spawn_channel_thread(f; T, num_samples, num_antenna_channels, buffers_in_flight)` - Run function in separate thread with output channel
- `membuffer(channel, max_size)` - Add buffering for real-time applications
- `generate_stream(gen_func, num_samples, num_antenna_channels; kwargs...)` - Generate signal streams

## Use Cases

- **Multi-antenna GNSS receivers**: Process signals from multiple antennas simultaneously
- **Software Defined Radio (SDR)**: Handle real-time SDR data streams
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

This package was extracted from [GNSSReceiver.jl](https://github.com/yourusername/GNSSReceiver.jl) to provide reusable signal processing infrastructure.

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
