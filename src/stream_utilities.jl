using FixedSizeArrays: FixedSizeMatrixDefault

# Helper for turning a matrix into a tuple of views, for use with the SoapySDR API.
function split_matrix(m::AbstractMatrix{T}) where {T<:Number}
    return [view(m, :, idx) for idx = 1:size(m, 2)]
end

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

"""
    generate_stream(gen_buff!::Function, num_samples, num_antenna_channels=1; wrapper=identity, buffers_in_flight=1, T=ComplexF32)

Returns a `SignalChannel` that generates buffers using the provided function.

# Arguments
- `gen_buff!::Function`: Function that fills a buffer. Should return:
  - `true` to push the buffer and continue
  - `false` to stop streaming
- `num_samples::Integer`: Number of samples per buffer
- `num_antenna_channels::Integer`: Number of antenna channels (default: 1)
- `wrapper::Function`: Optional wrapper function for setup/teardown (default: identity)
- `buffers_in_flight::Integer`: Number of buffers that can be in flight (default: 1)
- `T`: Data type (default: ComplexF32)

# Examples
```julia
# Generate single-channel signal (shape: 1024×1)
chan = generate_stream(1024) do buff
    buff .= rand(ComplexF32, size(buff))
    return true  # Continue generating
end

# Generate multi-channel signal (shape: 1024×4)
chan = generate_stream(1024, 4) do buff
    buff .= rand(ComplexF32, size(buff))
    return true  # Continue generating
end
```
"""
function generate_stream(gen_buff!::Function, num_samples::Integer, num_antenna_channels::Integer = 1;
                         wrapper::Function = (f) -> f(),
                         buffers_in_flight::Integer = 1,
                         T = ComplexF32)
    return spawn_signal_channel_thread(;T, num_samples, num_antenna_channels, buffers_in_flight) do c
        wrapper() do
            # Pre-allocate a pool of buffers to avoid allocations during streaming.
            # We need buffers_in_flight + 1 buffers: one for each slot in the channel
            # plus one for the current write operation.
            num_buffers = buffers_in_flight + 1
            buffer_pool = [FixedSizeMatrixDefault{T}(undef, num_samples, num_antenna_channels) for _ in 1:num_buffers]
            buffer_idx = 1

            # Keep on generating buffers until `gen_buff!()` returns `false`.
            while true
                buff = buffer_pool[buffer_idx]
                result = gen_buff!(buff)

                result === false && break

                # Push the buffer and rotate to the next one
                put!(c, buff)
                buffer_idx = mod1(buffer_idx + 1, num_buffers)
            end
        end
    end
end
