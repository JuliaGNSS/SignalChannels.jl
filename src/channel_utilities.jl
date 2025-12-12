"""
    consume_channel(f::Function, c::AbstractChannel, args...)

Consumes the given channel, calling `f(data, args...)` where `data` is what is
taken from the given channel. Returns when the channel closes.

This is useful for processing streaming data from a channel until the producer closes it.

# Examples
```julia
chan = Channel{Int}(10)
@async begin
    for i in 1:5
        put!(chan, i)
    end
    close(chan)
end

consume_channel(chan) do data
    println("Received: ", data)
end
```
"""
function consume_channel(f::Function, c::AbstractChannel, args...)
    for data in c
        f(data, args...)
    end
end

"""
    put_or_close!(out::AbstractChannel, data, upstream::AbstractChannel)

Try to put data to the output channel. If the output channel is closed,
close the upstream channel to propagate shutdown and return false.
Returns true if put succeeded, false if downstream was closed.
"""
function put_or_close!(out::AbstractChannel, data, upstream::AbstractChannel)
    if isopen(out)
        try
            put!(out, data)
            return true
        catch e
            if e isa InvalidStateException && !isopen(out)
                close(upstream)
                return false
            end
            rethrow(e)
        end
    else
        close(upstream)
        return false
    end
end

"""
    tee(in::AbstractChannel, channel_size::Integer=0)

Split a channel into two synchronized outputs. Both output channels receive
identical copies of the data.

Returns a tuple `(out1, out2)` of two channels with the same type as the input.

For `SignalChannel`, preserves the matrix dimensions.
For generic `Channel`, creates output channels with the specified buffer size.

Based on benchmarks in benchmark/benchmarks.jl a channel size of 16 is a sweet spot.

# Arguments
- `in`: Input channel to split
- `channel_size`: Buffer size for output channels (default: 16)

# Examples
```julia
# With SignalChannel
input = SignalChannel{ComplexF32}(1024, 4)
out1, out2 = tee(input, 16)

# With generic Channel
input = Channel{Int}(10)
out1, out2 = tee(input, 16)
```
"""
function tee(in::AbstractChannel, channel_size::Integer=16)
    out1 = similar(in, channel_size)
    out2 = similar(in, channel_size)
    task = Threads.@spawn begin
        for data in in
            put_or_close!(out1, data, in) || break
            put_or_close!(out2, data, in) || break
        end
        close(out1)
        close(out2)
    end
    bind(out1, task)
    bind(out2, task)
    bind(in, task)  # Propagate errors upstream
    return (out1, out2)
end

"""
    rechunk(in::SignalChannel{T}, chunk_size::Integer) where {T<:Number}

Converts a stream of chunks with one size to a stream of chunks with a different size.
This is useful for adapting data chunk sizes between different processing stages.

The number of antenna channels is preserved from the input channel.

Based on benchmarks in benchmark/benchmarks.jl a channel size of 16 is a sweet spot.

# Arguments
- `in`: Input SignalChannel
- `chunk_size`: Desired number of samples in each output chunk

# Examples
```julia
# Convert 512-sample chunks to 1024-sample chunks
input = SignalChannel{ComplexF32}(512, 4)
output = rechunk(input, 1024)
```
"""
function rechunk(in::SignalChannel{T}, chunk_size::Integer, channel_size=16) where {T<:Number}
    out = SignalChannel{T}(chunk_size, in.num_antenna_channels, channel_size)
    task = Threads.@spawn begin
        chunk_filled = 0
        chunk_idx = 1
        num_chunks = channel_size + 1
        # We'll alternate between filling up these channel_size + 1 chunks, then sending
        # them down the channel.  We have channel_size + 1 so that we can have:
        # - One that we're modifying,
        # - And others are sent out to a downstream
        chunks = [FixedSizeMatrixDefault{T}(undef, chunk_size, in.num_antenna_channels) for _ in 1:num_chunks]

        for data in in
            data_offset = 0
            data_remaining = size(data, 1)
            should_break = false

            while data_remaining > 0
                samples_wanted = chunk_size - chunk_filled
                samples_taken = min(data_remaining, samples_wanted)

                # Slice assignment with view on right side - no allocations
                chunks[chunk_idx][chunk_filled+1:chunk_filled+samples_taken, :] =
                    view(data, data_offset+1:data_offset+samples_taken, :)

                chunk_filled += samples_taken
                data_offset += samples_taken
                data_remaining -= samples_taken

                if chunk_filled >= chunk_size
                    if !put_or_close!(out, chunks[chunk_idx], in)
                        should_break = true
                        break
                    end
                    chunk_idx = mod1(chunk_idx + 1, num_chunks)
                    chunk_filled = 0
                end
            end
            should_break && break
        end
        close(out)
    end
    bind(out, task)
    bind(in, task)  # Propagate errors upstream
    return out
end

"""
    write_to_file(in::SignalChannel{T}, file_path::String) where {T<:Number}

Consume a channel and write to file(s). Multiple channels will be written to different files.
The channel number and data type are appended to the filename.

# Arguments
- `in`: Input SignalChannel to consume
- `file_path`: Base file path (without extension)

# File naming
Files are created with the pattern: `{file_path}{Type}{channel_number}.dat`

# Examples
```julia
chan = SignalChannel{ComplexF32}(1024, 4)
# This will create files: data_pathComplexF321.dat, data_pathComplexF322.dat, etc.
task = write_to_file(chan, "data_path")
wait(task)
```
"""
function write_to_file(in::SignalChannel{T}, file_path::String) where {T<:Number}
    task = Threads.@spawn begin
        type_string = string(T)
        streams = [
            open("$file_path$type_string$i.dat", "w") for i = 1:in.num_antenna_channels
        ]
        try
            consume_channel(in) do buffs
                foreach(eachcol(buffs), streams) do buff, stream
                    write(stream, buff)
                end
            end
        finally
            close.(streams)
        end
    end
    Base.errormonitor(task)
    return task
end

"""
    read_from_file(file_path::String, num_samples::Integer, num_antenna_channels::Integer; T::Type=ComplexF32)

Read data from file(s) and stream it through a SignalChannel. This is the inverse of `write_to_file`.

Files are expected to follow the naming pattern: `{file_path}{Type}{channel_number}.dat`

# Arguments
- `file_path`: Base file path (without extension)
- `num_samples`: Number of samples per chunk to read
- `num_antenna_channels`: Number of antenna channels (number of files to read)
- `T`: Data type to read (default: ComplexF32)

# Returns
- `SignalChannel{T}`: Channel that streams data from the files

# Examples
```julia
# Read back data that was written with write_to_file
chan = read_from_file("data_path", 1024, 4; T=ComplexF32)

# Process the data
for data in chan
    # Process each chunk
end
```
"""
function read_from_file(file_path::String, num_samples::Integer, num_antenna_channels::Integer; T::Type=ComplexF32)
    type_string = string(T)

    # Verify all files exist
    for i in 1:num_antenna_channels
        filepath = "$file_path$type_string$i.dat"
        if !isfile(filepath)
            error("File not found: $filepath")
        end
    end

    return spawn_signal_channel_thread(; T, num_samples, num_antenna_channels) do out
        streams = [open("$file_path$type_string$i.dat", "r") for i = 1:num_antenna_channels]

        try
            while !any(eof, streams)
                # Create buffer for this chunk
                buff = FixedSizeMatrixDefault{T}(undef, num_samples, num_antenna_channels)

                # Read data for each channel
                all_complete = true
                for (idx, stream) in enumerate(streams)
                    column = view(buff, :, idx)
                    bytes_read = readbytes!(stream, reinterpret(UInt8, column))
                    samples_read = bytes_read ÷ sizeof(T)

                    if samples_read < num_samples
                        all_complete = false
                        break
                    end
                end

                # Only put complete chunks
                if all_complete
                    put!(out, buff)
                end
            end
        finally
            close.(streams)
        end
    end
end
