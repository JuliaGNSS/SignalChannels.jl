using FixedSizeArrays: FixedSizeMatrixDefault

"""
    mux(ch1::SignalChannel{T,N}, ch2::SignalChannel{T,N};
        channel_size::Integer=10, sync::Bool=true) where {T,N}

Sequential channel multiplexer that forwards all chunks from `ch1` until it closes,
then forwards all chunks from `ch2`.

When `sync=true` (the default), while forwarding chunks from `ch1`, this function also
takes (and discards) chunks from `ch2` to keep both channels synchronized. This is useful
when both channels represent the same signal timeline and you need continuous phase when
switching from `ch1` to `ch2`.

When `sync=false`, chunks from `ch2` are not consumed during the `ch1` phase. All chunks
from `ch2` are forwarded after `ch1` closes.

# Arguments
- `ch1`: First input channel (forwarded until closed)
- `ch2`: Second input channel (forwarded after ch1 closes)
- `channel_size`: Output channel buffer size (default: 10)
- `sync`: If true, consume and discard ch2 chunks while forwarding ch1 (default: true)

# Returns
- `SignalChannel{T,N}`: Output channel receiving chunks from ch1, then ch2

# Throws
- `ErrorException` if channels have different `num_samples`

# Examples
```julia
ch1 = SignalChannel{ComplexF32,1}(1024, 10)
ch2 = SignalChannel{ComplexF32,1}(1024, 10)

# With sync (default): ch2 is drained in parallel with ch1
out = mux(ch1, ch2)

# Without sync: ch2 is forwarded as-is after ch1 closes
out = mux(ch1, ch2; sync=false)
```
"""
function mux(
    ch1::SignalChannel{T,N},
    ch2::SignalChannel{T,N};
    channel_size::Integer = 10,
    sync::Bool = true,
) where {T,N}
    if ch1.num_samples != ch2.num_samples
        error(
            "mux requires both channels to have the same num_samples. Got $(ch1.num_samples) and $(ch2.num_samples)",
        )
    end
    num_samples = ch1.num_samples
    out = SignalChannel{T,N}(num_samples, channel_size)

    # Pre-allocate buffer slots to avoid allocation in the hot loop.
    # channel_size + 2 ensures we never overwrite a buffer still in flight
    # in the output channel.
    num_slots = channel_size + 2
    buffer_slots = [FixedSizeMatrixDefault{T}(undef, num_samples, N) for _ = 1:num_slots]

    task =
        let ch1 = ch1,
            ch2 = ch2,
            out = out,
            buffer_slots = buffer_slots,
            num_slots = num_slots

            Threads.@spawn begin
                slot_idx = 1

                # Phase 1: Forward chunks from ch1, optionally consuming from ch2
                for chunk in ch1
                    buffer = buffer_slots[slot_idx]
                    copyto!(buffer, chunk)
                    put!(out, buffer)
                    slot_idx = mod1(slot_idx + 1, num_slots)
                    if sync && (isopen(ch2) || isready(ch2))
                        take!(ch2)
                    end
                end

                # Phase 2: Forward all remaining chunks from ch2
                for chunk in ch2
                    buffer = buffer_slots[slot_idx]
                    copyto!(buffer, chunk)
                    put!(out, buffer)
                    slot_idx = mod1(slot_idx + 1, num_slots)
                end

                close(out)
            end
        end

    bind(out, task)
    bind(ch1, task)
    bind(ch2, task)
    return out
end

"""
    add(channels::SignalChannel{T,N}...; channel_size::Integer=10) where {T,N}

Element-wise addition of chunks from multiple SignalChannels.

Takes chunks from all input channels simultaneously, adds them element-wise,
and puts the summed result into the output channel. Closes when the first input
channel closes. All inputs must produce data at the same rate.

# Arguments
- `channels...`: Two or more input SignalChannels (all must have same T, N, and num_samples)
- `channel_size`: Output channel buffer size (default: 10)

# Returns
- `SignalChannel{T,N}`: Output channel receiving the element-wise sum of input chunks

# Throws
- `ArgumentError` if fewer than 2 channels are provided
- `ErrorException` if channels have different `num_samples`

# Examples
```julia
ch1 = SignalChannel{ComplexF32,1}(1024, 10)
ch2 = SignalChannel{ComplexF32,1}(1024, 10)

# Add two channels
out = add(ch1, ch2)

# Add three or more channels
ch3 = SignalChannel{ComplexF32,1}(1024, 10)
out = add(ch1, ch2, ch3)
```
"""
function add(channels::SignalChannel{T,N}...; channel_size::Integer = 10) where {T,N}
    length(channels) >= 2 ||
        throw(ArgumentError("add requires at least 2 channels, got $(length(channels))"))

    num_samples = first(channels).num_samples
    for (i, ch) in enumerate(channels)
        if ch.num_samples != num_samples
            error(
                "add requires all channels to have the same num_samples. " *
                "Channel 1 has $(num_samples), channel $i has $(ch.num_samples)",
            )
        end
    end

    out = SignalChannel{T,N}(num_samples, channel_size)
    rest = channels[2:end]

    # Pre-allocate buffer slots to avoid allocation in the hot loop.
    # channel_size + 2 ensures we never overwrite a buffer still in flight
    # in the output channel.
    num_slots = channel_size + 2
    buffer_slots = [FixedSizeMatrixDefault{T}(undef, num_samples, N) for _ = 1:num_slots]

    task =
        let channels = channels,
            rest = rest,
            out = out,
            buffer_slots = buffer_slots,
            num_slots = num_slots

            Threads.@spawn begin
                slot_idx = 1
                for chunk in first(channels)
                    result = buffer_slots[slot_idx]
                    copyto!(result, chunk)
                    for ch in rest
                        result .+= take!(ch)
                    end
                    put!(out, result)
                    slot_idx = mod1(slot_idx + 1, num_slots)
                end
                close(out)
            end
        end

    bind(out, task)
    for ch in channels
        bind(ch, task)
    end
    return out
end
