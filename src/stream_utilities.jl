"""
    spawn_signal_channel_thread(f::Function; T=ComplexF32, num_samples, num_antenna_channels=1, buffers_in_flight=0)

Convenience wrapper to invoke `f(out_channel)` on a separate thread, closing
`out_channel` when `f()` finishes.

# Arguments
- `f::Function`: Function to execute with the output channel
- `T`: Data type for the channel (default: ComplexF32)
- `num_samples`: Number of samples per buffer
- `num_antenna_channels`: Number of antenna channels (default: 1)
- `buffers_in_flight`: Channel buffer size

# Examples
```julia
# Single channel (shape: 1024×1)
chan = spawn_signal_channel_thread(T=ComplexF32, num_samples=1024) do out
    for i in 1:100
        data = rand(ComplexF32, 1024, 1)
        put!(out, data)
    end
end

# Multi-channel (shape: 1024×4)
chan = spawn_signal_channel_thread(T=ComplexF32, num_samples=1024, num_antenna_channels=4) do out
    for i in 1:100
        data = rand(ComplexF32, 1024, 4)
        put!(out, data)
    end
end
```
"""
function spawn_signal_channel_thread(f::Function; T::DataType = ComplexF32,
                              num_samples, num_antenna_channels = 1,
                              buffers_in_flight::Int = 0)
    SignalChannel{T}(num_samples, num_antenna_channels, buffers_in_flight, spawn=true) do out
        f(out)
    end
end

"""
    membuffer(in::AbstractChannel, max_size::Int = 16)

Provide buffering for realtime applications. Creates a buffered channel that can
hold up to `max_size` items in flight.

For `SignalChannel`, preserves the matrix dimensions.
For generic `Channel`, creates a buffered Channel of the same type.

# Examples
```julia
# With SignalChannel
input = SignalChannel{ComplexF32}(1024, 4)
buffered = membuffer(input, 32)  # Buffer up to 32 matrices

# With generic Channel
input = Channel{Int}(0)
buffered = membuffer(input, 32)  # Buffer up to 32 integers
```
"""
function membuffer(in::AbstractChannel, max_size::Int = 16)
    out = similar(in, max_size)
    task = Threads.@spawn begin
        for data in in
            put!(out, data)
        end
        close(out)
    end
    bind(out, task)
    bind(in, task)  # Propagate errors upstream
    return out
end
