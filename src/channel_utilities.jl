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
    tee(in::AbstractChannel{T}) where {T}

Split a channel into two synchronized outputs. Both output channels receive
identical copies of the data.

Returns a tuple `(out1, out2)` of two channels with the same type as the input.

For `SignalChannel`, preserves the matrix dimensions.
For generic `Channel`, creates unbuffered output channels.

# Examples
```julia
# With SignalChannel
input = SignalChannel{ComplexF32}(1024, 4)
out1, out2 = tee(input)

# With generic Channel
input = Channel{Int}(10)
out1, out2 = tee(input)
```
"""
function tee(in::AbstractChannel)
    out1 = similar(in)
    out2 = similar(in)
    task = Threads.@spawn begin
        for data in in
            put!(out1, data)
            put!(out2, data)
        end
        close(out1)
        close(out2)
    end
    bind(out1, task)
    bind(out2, task)
    return (out1, out2)
end

"""
    rechunk(in::SignalChannel{T}, chunk_size::Integer) where {T<:Number}

Converts a stream of chunks with one size to a stream of chunks with a different size.
This is useful for adapting data chunk sizes between different processing stages.

The number of antenna channels is preserved from the input channel.

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
function rechunk(in::SignalChannel{T}, chunk_size::Integer) where {T<:Number}
    return spawn_signal_channel_thread(;
        T,
        num_samples=chunk_size,
        in.num_antenna_channels,
    ) do out
        chunk_filled = 0
        chunk_idx = 1
        # We'll alternate between filling up these three chunks, then sending
        # them down the channel.  We have three so that we can have:
        # - One that we're modifying,
        # - One that was sent out to a downstream,
        # - One that is being held by an intermediary
        chunks = [
            FixedSizeMatrixDefault{T}(undef, chunk_size, in.num_antenna_channels),
            FixedSizeMatrixDefault{T}(undef, chunk_size, in.num_antenna_channels),
            FixedSizeMatrixDefault{T}(undef, chunk_size, in.num_antenna_channels),
        ]
        consume_channel(in) do data
            # Make the loop type-stable
            data = view(data, 1:size(data, 1), :)

            # Generate chunks until this data is done
            while !isempty(data)

                # How many samples are we going to consume from this buffer?
                samples_wanted = (chunk_size - chunk_filled)
                samples_taken = min(size(data, 1), samples_wanted)

                # Copy as much of `data` as we can into `chunks`
                chunks[chunk_idx][chunk_filled+1:chunk_filled+samples_taken, :] =
                    data[1:samples_taken, :]
                chunk_filled += samples_taken

                # Move our view of `data` forward:
                data = view(data, samples_taken+1:size(data, 1), :)

                # If we filled the chunk completely, then send it off and flip `chunk_idx`:
                if chunk_filled >= chunk_size
                    put!(out, chunks[chunk_idx])
                    chunk_idx = mod1(chunk_idx + 1, length(chunks))
                    chunk_filled = 0
                end
            end
        end
    end
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
