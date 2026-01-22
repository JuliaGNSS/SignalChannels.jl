"""
    consume_channel(f::Function, c::AbstractChannel, args...)

Consumes the given channel, calling `f(data, args...)` where `data` is what is
taken from the given channel. Returns when the channel closes.

This is useful for processing streaming data from a channel until the producer closes it.

# Examples
```julia
chan = PipeChannel{Int}(10)
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
    tee(in::AbstractChannel, channel_size::Integer=16)
    tee(::Val{N}, in::AbstractChannel, channel_size::Integer=16) where N

Split a channel into N synchronized outputs. All output channels receive
identical copies of the data.

Returns a tuple of N channels with the same type as the input.

For `SignalChannel`, preserves the matrix dimensions.
For generic `PipeChannel`, creates output channels with the specified buffer size.

Based on benchmarks in benchmark/benchmarks.jl a channel size of 16 is a sweet spot.

# Arguments
- `Val{N}`: Number of output channels (default: 2 when not specified)
- `in`: Input channel to split
- `channel_size`: Buffer size for output channels (default: 16)

# Examples
```julia
# With SignalChannel (default 2 outputs)
input = SignalChannel{ComplexF32}(1024, 4)
out1, out2 = tee(input, 16)

# With generic PipeChannel
input = PipeChannel{Int}(10)
out1, out2 = tee(input, 16)

# With 3 outputs
input = SignalChannel{ComplexF32}(1024, 4)
out1, out2, out3 = tee(Val(3), input, 16)

# With 4 outputs
input = PipeChannel{Int}(10)
outputs = tee(Val(4), input)  # Returns NTuple{4, PipeChannel{Int}}
```
"""
function tee(::Val{N}, in::AbstractChannel, channel_size::Integer=16) where N
    outputs = ntuple(_ -> similar(in, channel_size), Val(N))
    task = Threads.@spawn begin
        for data in in
            for out in outputs
                put!(out, data)
            end
        end
        for out in outputs
            close(out)
        end
    end
    for out in outputs
        bind(out, task)
    end
    bind(in, task)
    return outputs
end

# Default to 2 outputs for backward compatibility
function tee(in::AbstractChannel, channel_size::Integer=16)
    return tee(Val(2), in, channel_size)
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
function write_to_file(in::SignalChannel{T,N}, file_path::String) where {T<:Number,N}
    task = Threads.@spawn begin
        type_string = string(T)
        streams = [
            open("$file_path$type_string$i.dat", "w") for i = 1:N
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
