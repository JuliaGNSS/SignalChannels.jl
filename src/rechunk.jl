"""
    RechunkState{T,N}

Mutable state for rechunking operations. Holds pre-allocated buffers and tracks
the current position in the output chunk being filled.

This struct enables zero-allocation rechunking in hot loops by pre-allocating
all necessary buffers upfront. The number of channels `N` is a type parameter,
enabling the compiler to unroll the per-channel copy loop for zero allocations.

# Type Parameters
- `T`: Element type of the data being rechunked
- `N`: Number of antenna channels (compile-time constant for loop unrolling)

# Fields
- `output_chunk_size::Int`: Number of samples per output chunk
- `buffer_pool::Vector{FixedSizeMatrixDefault{T}}`: Pre-allocated output buffers
- `buffer_idx::Int`: Current index into buffer_pool (cycles through)
- `chunk_filled::Int`: Number of samples currently in the buffer being filled
- `output_vector::Vector{FixedSizeMatrixDefault{T}}`: Pre-allocated vector for rechunk! results

# Examples
```julia
# Create state for rechunking to 1024 samples with 4 channels
state = RechunkState{ComplexF32,4}(1024, 10)

# Process input data
for input_buffer in input_stream
    outputs = rechunk!(state, input_buffer)
    for output_buffer in outputs
        # Process each completed output buffer
    end
end

# Get any remaining partial buffer (if needed)
partial = get_partial_buffer(state)
```
"""
mutable struct RechunkState{T,N}
    output_chunk_size::Int
    buffer_pool::Vector{FixedSizeMatrixDefault{T}}
    buffer_idx::Int
    chunk_filled::Int
    output_vector::Vector{FixedSizeMatrixDefault{T}}
    output_count::Int

    function RechunkState{T,N}(output_chunk_size::Integer, num_buffers::Integer, max_outputs_per_input::Integer) where {T,N}
        buffer_pool = [FixedSizeMatrixDefault{T}(undef, output_chunk_size, N) for _ in 1:num_buffers]
        output_vector = Vector{FixedSizeMatrixDefault{T}}(undef, max_outputs_per_input)
        return new{T,N}(output_chunk_size, buffer_pool, 1, 0, output_vector, 0)
    end
end

# Convenience constructor that takes nchannels as runtime value
# max_outputs_per_input defaults to num_buffers (conservative estimate)
# Note: This constructor may not fully specialize the inner loop. For best performance,
# use the Val-based constructor below.
function RechunkState{T}(output_chunk_size::Integer, nchannels::Integer, num_buffers::Integer; max_outputs_per_input::Integer=num_buffers) where {T}
    return RechunkState{T,nchannels}(output_chunk_size, num_buffers, max_outputs_per_input)
end

# Val-based constructor for compile-time specialization of channel count
# This ensures the per-channel copy loop is fully unrolled for zero allocations
function RechunkState{T}(output_chunk_size::Integer, ::Val{N}, num_buffers::Integer; max_outputs_per_input::Integer=num_buffers) where {T,N}
    return RechunkState{T,N}(output_chunk_size, num_buffers, max_outputs_per_input)
end

# Accessor for number of channels (from type parameter)
get_num_antenna_channels(::RechunkState{T,N}) where {T,N} = N

# Per-channel copy using ntuple for compile-time unrolling (zero allocations)
@inline function copy_channels!(
    output::AbstractMatrix{T},
    input::AbstractMatrix{T},
    dst_offset::Int,
    src_offset::Int,
    nsamples::Int,
    ::Val{N}
) where {T,N}
    ntuple(Val(N)) do ch
        @inbounds copyto!(
            view(output, :, ch), dst_offset,
            view(input, :, ch), src_offset,
            nsamples
        )
    end
    nothing
end

# Core rechunk step: copy samples and check for chunk completion.
# Returns (completed_buffer_or_nothing, samples_consumed).
@inline function rechunk_step!(
    state::RechunkState{T,N},
    input::AbstractMatrix{T},
    data_offset::Int,
    data_remaining::Int
) where {T,N}
    samples_taken = min(data_remaining, state.output_chunk_size - state.chunk_filled)

    # Per-channel copy with compile-time unrolling
    output_buff = state.buffer_pool[state.buffer_idx]
    copy_channels!(output_buff, input, state.chunk_filled + 1, data_offset + 1, samples_taken, Val(N))

    state.chunk_filled += samples_taken

    # Check if we completed a chunk
    if state.chunk_filled >= state.output_chunk_size
        state.buffer_idx = mod1(state.buffer_idx + 1, length(state.buffer_pool))
        state.chunk_filled = 0
        return (output_buff, samples_taken)
    end

    return (nothing, samples_taken)
end

# Process a single input matrix and append completed buffers to output_vector.
# Returns the new output_count after processing.
@inline function rechunk_one!(
    state::RechunkState{T,N},
    input::AbstractMatrix{T},
    output_count::Int
) where {T,N}
    # Zero-copy passthrough: if input exactly matches output size and no partial
    # data is buffered, include input directly without copying
    if state.chunk_filled == 0 && size(input, 1) == state.output_chunk_size
        output_count += 1
        state.output_vector[output_count] = input
        return output_count
    end

    data_offset = 0
    data_remaining = size(input, 1)

    while data_remaining > 0
        completed_buffer, samples_taken = rechunk_step!(state, input, data_offset, data_remaining)
        data_offset += samples_taken
        data_remaining -= samples_taken

        if completed_buffer !== nothing
            output_count += 1
            state.output_vector[output_count] = completed_buffer
        end
    end

    return output_count
end

"""
    rechunk!(state::RechunkState{T,N}, input::FixedSizeMatrixDefault{T}) where {T,N}

Process an input buffer through the rechunk state, returning a view of completed
output buffers.

Uses per-channel `copyto!` with compile-time loop unrolling for zero-allocation
performance (~600 M samples/s for ComplexF32).

**Zero-copy passthrough**: When `input` exactly matches the output chunk size and
no partial data is buffered, the input is included directly without copying.
This means the caller must not modify or reuse the input buffer after passing it
to `rechunk!` if they need the output to remain valid.

# Arguments
- `state`: RechunkState holding pre-allocated buffers and current position
- `input`: Input matrix to rechunk (samples × channels), must be `FixedSizeMatrixDefault{T}`

# Returns
A `SubArray` view into the state's output vector containing the completed buffers.
May contain zero buffers (if input doesn't complete the current chunk), one buffer,
or multiple buffers. The view is valid until the next call to `rechunk!`.

# Examples
```julia
state = RechunkState{ComplexF32}(1024, 4, 10)
input = rand(ComplexF32, 512, 4)

# Process and handle completed chunks
outputs = rechunk!(state, input)
put!(channel, outputs)  # Batch put all outputs at once
```
"""
@inline function rechunk!(state::RechunkState{T,N}, input::FixedSizeMatrixDefault{T}) where {T,N}
    output_count = rechunk_one!(state, input, 0)
    state.output_count = output_count
    return view(state.output_vector, 1:output_count)
end

"""
    rechunk!(state::RechunkState{T,N}, inputs::AbstractVector{<:FixedSizeMatrixDefault{T}}) where {T,N}

Process multiple input buffers through the rechunk state in a single call, returning
a view of all completed output buffers.

This batch version is more efficient than calling `rechunk!` repeatedly because:
- Single view allocation for all outputs
- Better cache locality when processing multiple inputs
- Reduced function call overhead

# Arguments
- `state`: RechunkState holding pre-allocated buffers and current position
- `inputs`: Vector (or view) of `FixedSizeMatrixDefault{T}` input matrices to rechunk

# Returns
A `SubArray` view into the state's output vector containing all completed buffers
from processing all inputs. The view is valid until the next call to `rechunk!`.

# Examples
```julia
state = RechunkState{ComplexF32}(1024, 4, 20; max_outputs_per_input=10)
input_batch = Vector{FixedSizeMatrixDefault{ComplexF32}}(undef, 4)
# ... fill input_batch ...
num_taken = take!(channel, input_batch)

# Use a view to process only the valid inputs
outputs = rechunk!(state, @view input_batch[1:num_taken])
put!(output_channel, outputs)
```
"""
@inline function rechunk!(state::RechunkState{T,N}, inputs::AbstractVector{<:FixedSizeMatrixDefault{T}}) where {T,N}
    output_count = 0
    for input in inputs
        output_count = rechunk_one!(state, input, output_count)
    end
    state.output_count = output_count
    return view(state.output_vector, 1:output_count)
end

"""
    get_partial_buffer(state::RechunkState{T,N}) where {T,N}

Returns the current partially-filled buffer and how many samples it contains,
or `nothing` if no partial data exists.

Use this at the end of processing to handle any remaining samples that didn't
fill a complete output chunk.

# Returns
- `(buffer, samples_filled)`: Tuple of the buffer and number of valid samples, or
- `nothing`: If no partial data exists (chunk_filled == 0)

# Examples
```julia
state = RechunkState{ComplexF32}(1024, 4, 10)
# ... process data ...

partial = get_partial_buffer(state)
if partial !== nothing
    buffer, n_samples = partial
    # Handle partial buffer (e.g., transmit or discard)
end
```
"""
function get_partial_buffer(state::RechunkState{T,N}) where {T,N}
    if state.chunk_filled > 0
        return (state.buffer_pool[state.buffer_idx], state.chunk_filled)
    end
    return nothing
end

"""
    reset!(state::RechunkState)

Reset the rechunk state to its initial condition, discarding any partial data.
The buffer pool is preserved (no new allocations).
"""
function reset!(state::RechunkState)
    state.buffer_idx = 1
    state.chunk_filled = 0
    state.output_count = 0
    return state
end

"""
    rechunk(in::SignalChannel{T,N}, chunk_size::Integer, channel_size=16) where {T<:Number,N}

Converts a stream of chunks with one size to a stream of chunks with a different size.
This is useful for adapting data chunk sizes between different processing stages.

The number of antenna channels `N` is preserved from the input channel as a type parameter,
enabling compile-time specialization for zero-allocation rechunking.

Uses batch `put!` operations on the output channel for improved throughput.

# Arguments
- `in`: Input SignalChannel{T,N}
- `chunk_size`: Desired number of samples in each output chunk
- `channel_size`: Buffer size for output channel (default: 16)

# Examples
```julia
# Convert 512-sample chunks to 1024-sample chunks
input = SignalChannel{ComplexF32,4}(512)
output = rechunk(input, 1024)
```
"""
function rechunk(in::SignalChannel{T,N}, chunk_size::Integer, channel_size=16) where {T<:Number,N}
    # No-op passthrough: when input and output chunk sizes already match, return
    # the input channel directly. This avoids creating an intermediate channel
    # and task, which fixes a race condition: with zero-copy passthrough the same
    # buffer references flow through both the input and output channels, extending
    # the pipeline depth beyond the upstream producer's buffer pool size. Under
    # slow-consumer conditions (e.g. JIT compilation on first run), the producer
    # can wrap around and overwrite buffers still queued in the downstream channel.
    if in.num_samples == chunk_size
        return in
    end

    out = SignalChannel{T,N}(chunk_size, channel_size)

    # Estimate max outputs per input: input can complete partial + produce full chunks
    # For downsampling (large input -> small output), this could be large
    max_outputs = cld(in.num_samples, chunk_size) + 1

    # We need channel_size + max_outputs + 2 buffers:
    # - channel_size buffers can be sitting in the output channel
    # - max_outputs buffers can be in the output vector
    # - 1 buffer being written to
    # - 1 buffer being read by the (single) consumer
    num_buffers = channel_size + max_outputs + 2

    # N is now a compile-time constant from the type parameter
    task = Threads.@spawn _rechunk_task(T, Val(N), in, out, chunk_size, num_buffers, max_outputs)
    bind(out, task)
    bind(in, task)  # Propagate errors upstream
    return out
end

# Inner task function with compile-time N for zero-allocation rechunking
function _rechunk_task(::Type{T}, ::Val{N}, in, out, chunk_size, num_buffers, max_outputs) where {T,N}
    state = RechunkState{T,N}(chunk_size, num_buffers, max_outputs)

    for data in in
        outputs = rechunk!(state, data)
        if !isempty(outputs)
            put!(out.channel, outputs)
        end
    end

    close(out)
end
