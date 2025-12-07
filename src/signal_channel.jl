import Base.close, Base.put!, Base.close, Base.isempty
using FixedSizeArrays: FixedSizeMatrixDefault

"""
    StreamWarning

Represents a warning event that occurred during stream processing.
Used to communicate errors/warnings from hot loops without blocking.

# Fields
- `type::Symbol`: Warning type (e.g., `:overflow`, `:underflow`, `:timeout`, `:error`)
- `time_str::String`: Human-readable time when the warning occurred
- `error_code::Union{Int,Nothing}`: Optional error code from the underlying API
- `error_string::Union{String,Nothing}`: Optional error description

# Examples
```julia
warning = StreamWarning(:overflow, "1.5s", nothing, nothing)
warning = StreamWarning(:error, "2.3s", -5, "Unknown error")
```
"""
struct StreamWarning
    type::Symbol
    time_str::String
    error_code::Union{Int,Nothing}
    error_string::Union{String,Nothing}
end

"""
    StreamWarning(type::Symbol, time_str::String)

Convenience constructor for simple warnings without error codes.
"""
StreamWarning(type::Symbol, time_str::String) = StreamWarning(type, time_str, nothing, nothing)

"""
    TxStats

Statistics about transmitted samples from a TX stream.

# Fields
- `total_samples::Int`: Total number of samples successfully transmitted so far
"""
struct TxStats
    total_samples::Int
end

"""
    SignalChannel{T} <: AbstractChannel{T}

A specialized channel type that enforces matrix dimensions for multi-channel signal data.
This ensures type safety when working with multi-antenna or multi-channel signal processing
applications.

Data is always stored as a fixed-size matrix with dimensions `(num_samples, num_antenna_channels)`.
For single-channel signals (`num_antenna_channels = 1`), this results in a column vector
represented as a matrix with shape `(num_samples, 1)`.

The use of FixedSizeMatrixDefault ensures that buffer dimensions cannot be changed after creation,
providing additional safety guarantees.

# Fields
- `num_samples::Int`: Number of samples per buffer (rows)
- `num_antenna_channels::Int`: Number of antenna channels (columns)
- `channel::Channel{FixedSizeMatrixDefault{T}}`: Underlying Julia Channel with fixed-size matrices

# Examples
```julia
# Create a single-channel for 1024 samples (shape: 1024×1)
chan = SignalChannel{ComplexF32}(1024)

# Create a channel for 1024 samples across 4 antenna channels (shape: 1024×4)
chan = SignalChannel{ComplexF32}(1024, 4)

# Put data (must match dimensions)
data = rand(ComplexF32, 1024, 1)  # Single channel
put!(chan, data)

# Take data
received = take!(chan)  # Returns FixedSizeMatrixDefault{ComplexF32} with size (1024, 1) or (1024, 4)
```
"""
struct SignalChannel{T} <: AbstractChannel{T}
    num_samples::Int
    num_antenna_channels::Int
    channel::Channel{FixedSizeMatrixDefault{T}}
    function SignalChannel{T}(
        num_samples::Integer,
        num_antenna_channels::Integer=1,
        sz::Integer=0,
    ) where {T}
        return new(num_samples, num_antenna_channels, Channel{FixedSizeMatrixDefault{T}}(sz))
    end
end

"""
    SignalChannel{T}(func::Function, num_samples, num_antenna_channels=1, size=0; taskref=nothing, spawn=false)

Construct a `SignalChannel` and execute `func` in a task, similar to `Channel(func)`.

# Arguments
- `func::Function`: Function to execute with the channel
- `num_samples::Integer`: Number of samples per buffer
- `num_antenna_channels::Integer`: Number of antenna channels (default: 1)
- `size`: Channel buffer size (default 0)
- `taskref`: Optional reference to store the created task
- `spawn`: If true, schedule task on any thread; if false, yield to it immediately

# Examples
```julia
# Single channel (shape: 1024×1)
chan = SignalChannel{ComplexF32}(1024) do c
    for i in 1:100
        data = rand(ComplexF32, 1024, 1)
        put!(c, data)
    end
end

# Multi-channel (shape: 1024×4)
chan = SignalChannel{ComplexF32}(1024, 4, 10) do c
    for i in 1:100
        data = rand(ComplexF32, 1024, 4)
        put!(c, data)
    end
end
```
"""
function SignalChannel{T}(
    func::Function,
    num_samples::Integer,
    num_antenna_channels::Integer=1,
    size=0;
    taskref=nothing,
    spawn=false,
) where {T}
    chnl = SignalChannel{T}(num_samples, num_antenna_channels, size)
    task = Task(() -> func(chnl))
    task.sticky = !spawn
    bind(chnl, task)
    if spawn
        schedule(task) # start it on (potentially) another thread
    else
        yield(task) # immediately start it, yielding the current thread
    end
    isa(taskref, Ref{Task}) && (taskref[] = task)
    return chnl
end

"""
    put!(c::SignalChannel, v::FixedSizeMatrixDefault)

Put a fixed-size matrix into the channel. Validates that the matrix dimensions match the channel's
`num_samples` and `num_antenna_channels`.

# Throws
- `ArgumentError`: If matrix dimensions don't match the channel configuration
"""
function Base.put!(c::SignalChannel{T}, v::FixedSizeMatrixDefault{T}) where {T}
    if size(v, 1) != c.num_samples || size(v, 2) != c.num_antenna_channels
        throw(
            ArgumentError(
                "Matrix dimensions $(size(v)) do not match expected ($(c.num_samples), $(c.num_antenna_channels))",
            ),
        )
    end
    Base.put!(c.channel, v)
end

"""
    put!(c::SignalChannel, v::AbstractMatrix)

Put a regular matrix into the channel by converting it to a FixedSizeMatrixDefault.
Validates that the matrix dimensions match the channel's `num_samples` and `num_antenna_channels`.

This convenience method allows using regular Julia arrays without manually converting to
FixedSizeMatrixDefault.

# Arguments
- `c`: SignalChannel to put data into
- `v`: Regular matrix to put (will be converted to FixedSizeMatrixDefault)

# Throws
- `ArgumentError`: If matrix dimensions don't match the channel configuration

# Examples
```julia
chan = SignalChannel{ComplexF32}(1024, 4)

# Can now use regular arrays directly
data = rand(ComplexF32, 1024, 4)
put!(chan, data)  # Automatically converts to FixedSizeMatrixDefault
```
"""
function Base.put!(c::SignalChannel{T}, v::AbstractMatrix{T}) where {T}
    if size(v, 1) != c.num_samples || size(v, 2) != c.num_antenna_channels
        throw(
            ArgumentError(
                "Matrix dimensions $(size(v)) do not match expected ($(c.num_samples), $(c.num_antenna_channels))",
            ),
        )
    end
    # Convert to FixedSizeMatrixDefault
    fixed_matrix = FixedSizeMatrixDefault{T}(v)
    Base.put!(c.channel, fixed_matrix)
end

# Delegate Base methods to the underlying channel
Base.bind(c::SignalChannel, task::Task) = Base.bind(c.channel, task)
Base.take!(c::SignalChannel) = Base.take!(c.channel)
Base.close(c::SignalChannel, excp::Exception=Base.closed_exception()) =
    Base.close(c.channel, excp)
Base.isopen(c::SignalChannel) = Base.isopen(c.channel)
Base.close_chnl_on_taskdone(t::Task, c::SignalChannel) =
    Base.close_chnl_on_taskdone(t, c.channel)
Base.isready(c::SignalChannel) = Base.isready(c.channel)
Base.isempty(c::SignalChannel) = Base.isempty(c.channel)
Base.n_avail(c::SignalChannel) = Base.n_avail(c.channel)
Base.isfull(c::SignalChannel) = Base.isfull(c.channel)

Base.lock(c::SignalChannel) = Base.lock(c.channel)
Base.lock(f, c::SignalChannel) = Base.lock(f, c.channel)
Base.unlock(c::SignalChannel) = Base.unlock(c.channel)
Base.trylock(c::SignalChannel) = Base.trylock(c.channel)
Base.wait(c::SignalChannel) = Base.wait(c.channel)
Base.eltype(c::SignalChannel) = Base.eltype(c.channel)
Base.show(io::IO, c::SignalChannel) = Base.show(io, c.channel)
Base.iterate(c::SignalChannel, state=nothing) = Base.iterate(c.channel, state)
Base.IteratorSize(::Type{<:SignalChannel}) = Base.SizeUnknown()

"""
    Base.similar(c::SignalChannel{T}, [size::Int=0]) where {T}

Create a new SignalChannel with the same dimensions as `c` but with optional buffer size.

# Arguments
- `c`: Input SignalChannel
- `size`: Optional buffer size (default: 0, unbuffered)

# Examples
```julia
input = SignalChannel{ComplexF32}(1024, 4, 10)
output = similar(input)        # Same dimensions, unbuffered
buffered = similar(input, 32)  # Same dimensions, buffer size 32
```
"""
Base.similar(c::SignalChannel{T}, size::Int=0) where {T} =
    SignalChannel{T}(c.num_samples, c.num_antenna_channels, size)

"""
    Base.similar(c::Channel{T}, [size::Int=0]) where {T}

Create a new Channel with the same element type as `c` but with optional buffer size.

# Arguments
- `c`: Input Channel
- `size`: Buffer size (default: 0, unbuffered)

# Examples
```julia
input = Channel{Int}(10)
output = similar(input)      # Same type, unbuffered
buffered = similar(input, 20) # Same type, buffer size 20
```
"""
Base.similar(c::Channel{T}, size::Int=0) where {T} = Channel{T}(size)
