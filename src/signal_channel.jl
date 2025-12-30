import Base.close, Base.put!, Base.close, Base.isempty
using FixedSizeArrays: FixedSizeMatrixDefault
using PipeChannels: PipeChannel

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

Uses a lock-free PipeChannel internally for zero-allocation performance in real-time applications.

**Thread Safety**: Exactly ONE producer thread may call `put!` and exactly ONE consumer thread
may call `take!`. Multiple producers or consumers will cause data races.

# Fields
- `num_samples::Int`: Number of samples per buffer (rows)
- `num_antenna_channels::Int`: Number of antenna channels (columns)
- `channel::PipeChannel{FixedSizeMatrixDefault{T}}`: Underlying lock-free channel with fixed-size matrices

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
    channel::PipeChannel{FixedSizeMatrixDefault{T}}
    function SignalChannel{T}(
        num_samples::Integer,
        num_antenna_channels::Integer=1,
        sz::Integer=16,
    ) where {T}
        return new(num_samples, num_antenna_channels, PipeChannel{FixedSizeMatrixDefault{T}}(sz))
    end
end

"""
    SignalChannel{T}(func::Function, num_samples, num_antenna_channels=1, size=16; taskref=nothing, spawn=false)

Construct a `SignalChannel` and execute `func` in a task, similar to `Channel(func)`.

# Arguments
- `func::Function`: Function to execute with the channel
- `num_samples::Integer`: Number of samples per buffer
- `num_antenna_channels::Integer`: Number of antenna channels (default: 1)
- `size`: Channel buffer size (default 16)
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
    size=16;
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

# Prevent accidental use of regular matrices - only FixedSizeMatrixDefault is allowed for performance
function Base.put!(c::SignalChannel{T}, v::AbstractMatrix{T}) where {T}
    throw(
        ArgumentError(
            "SignalChannel only accepts FixedSizeMatrixDefault for performance. " *
            "Got $(typeof(v)). Convert with: FixedSizeMatrixDefault{$T}(your_matrix)",
        ),
    )
end

# Delegate Base methods to the underlying channel
Base.bind(c::SignalChannel, task::Task) = Base.bind(c.channel, task)
Base.take!(c::SignalChannel) = Base.take!(c.channel)
Base.close(c::SignalChannel, excp::Exception=Base.closed_exception()) =
    Base.close(c.channel, excp)

# ============================================================================
# Batch Operations
# ============================================================================

"""
    put!(c::SignalChannel{T}, values::AbstractVector{<:FixedSizeMatrixDefault{T}}) where {T}

Add multiple fixed-size matrices to the channel in a single batch operation.
Blocks until all items are written. Returns the input vector.

This is more efficient than calling `put!` repeatedly because it uses the
underlying PipeChannel's batch operation, reducing atomic overhead.

All matrices must match the channel's `num_samples` and `num_antenna_channels`.

# Throws
- `ArgumentError`: If any matrix dimensions don't match the channel configuration
- `InvalidStateException`: If the channel is closed

# Examples
```julia
chan = SignalChannel{ComplexF32}(1024, 4)
buffers = [FixedSizeMatrixDefault{ComplexF32}(rand(ComplexF32, 1024, 4)) for _ in 1:8]
put!(chan, buffers)  # Batch put all 8 buffers
```
"""
function Base.put!(c::SignalChannel{T}, values::AbstractVector{<:FixedSizeMatrixDefault{T}}) where {T}
    # Validate all matrices have correct dimensions
    for (i, v) in enumerate(values)
        if size(v, 1) != c.num_samples || size(v, 2) != c.num_antenna_channels
            throw(
                ArgumentError(
                    "Matrix $i dimensions $(size(v)) do not match expected ($(c.num_samples), $(c.num_antenna_channels))",
                ),
            )
        end
    end
    Base.put!(c.channel, values)
end

"""
    take!(c::SignalChannel{T}, n::Integer) where {T}

Remove and return exactly `n` matrices from the channel in a single batch operation.
Blocks until all `n` items are available.

# Returns
- `Vector{FixedSizeMatrixDefault{T}}`: Vector of exactly `n` matrices

# Throws
- `InvalidStateException`: If the channel is closed before `n` items can be read

# Examples
```julia
chan = SignalChannel{ComplexF32}(1024, 4)
# ... producer puts data ...
batch = take!(chan, 8)  # Returns vector of 8 matrices
```
"""
function Base.take!(c::SignalChannel{T}, n::Integer) where {T}
    Base.take!(c.channel, n)
end

"""
    take!(c::SignalChannel{T}, output::AbstractVector{<:FixedSizeMatrixDefault{T}}) where {T}

Remove matrices from the channel into a pre-allocated output vector.
Blocks until the entire output buffer is filled. Returns `length(output)`.

This variant avoids allocation by writing into a provided buffer.

# Returns
- `Int`: Number of matrices read (always `length(output)`)

# Throws
- `InvalidStateException`: If the channel is closed before the buffer can be filled

# Examples
```julia
chan = SignalChannel{ComplexF32}(1024, 4)
buffer = Vector{FixedSizeMatrixDefault{ComplexF32}}(undef, 8)
take!(chan, buffer)  # Fills buffer with 8 matrices
```
"""
function Base.take!(c::SignalChannel{T}, output::AbstractVector{<:FixedSizeMatrixDefault{T}}) where {T}
    Base.take!(c.channel, output)
end

# ============================================================================
# Other Delegate Methods
# ============================================================================

Base.isopen(c::SignalChannel) = Base.isopen(c.channel)
Base.isready(c::SignalChannel) = Base.isready(c.channel)
Base.isempty(c::SignalChannel) = Base.isempty(c.channel)
Base.n_avail(c::SignalChannel) = Base.n_avail(c.channel)
Base.isfull(c::SignalChannel) = Base.isfull(c.channel)
Base.wait(c::SignalChannel) = Base.wait(c.channel)
Base.eltype(::Type{SignalChannel{T}}) where {T} = FixedSizeMatrixDefault{T}

# Iterator support: allows `for buffer in channel` syntax.
# The @inline annotation is critical to avoid heap allocation of the (value, state)
# tuple for non-isbits types like FixedSizeMatrixDefault.
@inline Base.iterate(c::SignalChannel, state=nothing) = Base.iterate(c.channel, state)
Base.IteratorSize(::Type{<:SignalChannel}) = Base.SizeUnknown()

"""
    Base.similar(c::SignalChannel{T}, [size::Int=16]) where {T}

Create a new SignalChannel with the same dimensions as `c` but with optional buffer size.

# Arguments
- `c`: Input SignalChannel
- `size`: Optional buffer size (default: 16)

# Examples
```julia
input = SignalChannel{ComplexF32}(1024, 4, 10)
output = similar(input)        # Same dimensions, buffer size 16
buffered = similar(input, 32)  # Same dimensions, buffer size 32
```
"""
Base.similar(c::SignalChannel{T}, size::Int=16) where {T} =
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

"""
    Base.similar(c::PipeChannel{T}, [size::Int=16]) where {T}

Create a new PipeChannel with the same element type as `c` but with optional buffer size.

# Arguments
- `c`: Input PipeChannel
- `size`: Buffer size (default: 16)

# Examples
```julia
input = PipeChannel{Int}(10)
output = similar(input)      # Same type, buffer size 16
buffered = similar(input, 20) # Same type, buffer size 20
```
"""
Base.similar(c::PipeChannel{T}, size::Int=16) where {T} = PipeChannel{T}(size)
