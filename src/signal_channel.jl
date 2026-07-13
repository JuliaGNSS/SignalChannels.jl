import Base.close, Base.put!, Base.close, Base.isempty
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
    SignalChannel{T,N,M} <: AbstractChannel{T}

A specialized channel type that enforces matrix dimensions for multi-channel signal data.
This ensures type safety when working with multi-antenna or multi-channel signal processing
applications.

The number of antenna channels `N` is a type parameter, enabling compile-time specialization
for zero-allocation performance in tight loops.

Data is stored as a matrix with dimensions `(num_samples, N)`.
For single-channel signals (`N = 1`), this results in a column vector
represented as a matrix with shape `(num_samples, 1)`.

The backing matrix type `M` is also a type parameter and defaults to `Matrix{T}`
(Julia's built-in dense array). Any `AbstractMatrix{T}` may be used instead — for
example `FixedSizeArrays.FixedSizeMatrixDefault{T}` (which guarantees the buffer
dimensions cannot change after creation) or a `StaticArrays` type. Because the
channel only ever passes *references* to buffers, the choice of `M` has no
measurable effect on channel throughput; pick it for the semantics you want.

Uses a lock-free PipeChannel internally for zero-allocation performance in real-time applications.

**Thread Safety**: Exactly ONE producer thread may call `put!` and exactly ONE consumer thread
may call `take!`. Multiple producers or consumers will cause data races.

# Type Parameters
- `T`: Element type (e.g., `ComplexF32`, `Float64`)
- `N`: Number of antenna channels (compile-time constant)
- `M`: Backing matrix type, `M <: AbstractMatrix{T}` (default: `Matrix{T}`)

# Fields
- `num_samples::Int`: Number of samples per buffer (rows)
- `channel::PipeChannel{M}`: Underlying lock-free channel of buffers

# Examples
```julia
# Create a single-channel for 1024 samples (shape: 1024×1), backed by Matrix{ComplexF32}
chan = SignalChannel{ComplexF32}(1024)
# or explicitly: SignalChannel{ComplexF32,1}(1024)

# Create a channel for 1024 samples across 4 antenna channels (shape: 1024×4)
chan = SignalChannel{ComplexF32,4}(1024)

# Opt into a different backing matrix type (e.g. FixedSizeArrays)
using FixedSizeArrays: FixedSizeMatrixDefault
chan = SignalChannel{ComplexF32,4,FixedSizeMatrixDefault{ComplexF32}}(1024)

# Put data (must match dimensions)
data = rand(ComplexF32, 1024, 1)  # Single channel
put!(chan, data)

# Take data
received = take!(chan)  # Returns an M with size (1024, 1) or (1024, 4)
```
"""
struct SignalChannel{T,N,M<:AbstractMatrix{T}} <: AbstractChannel{T}
    num_samples::Int
    channel::PipeChannel{M}
    function SignalChannel{T,N,M}(
        num_samples::Integer,
        sz::Integer=16,
    ) where {T,N,M}
        return new{T,N,M}(num_samples, PipeChannel{M}(sz))
    end
end

# Convenience constructor: SignalChannel{T,N}(num_samples) defaults the backing type to Matrix{T}
function SignalChannel{T,N}(num_samples::Integer, sz::Integer=16) where {T,N}
    return SignalChannel{T,N,Matrix{T}}(num_samples, sz)
end

# Convenience constructor: SignalChannel{T}(num_samples) defaults to N=1, M=Matrix{T}
function SignalChannel{T}(num_samples::Integer, sz::Integer=16) where {T}
    return SignalChannel{T,1,Matrix{T}}(num_samples, sz)
end

# Accessor for number of antenna channels (from type parameter)
num_antenna_channels(::SignalChannel{T,N}) where {T,N} = N

"""
    SignalChannel{T,N}(func::Function, num_samples, size=16; taskref=nothing, spawn=false)

Construct a `SignalChannel{T,N}` and execute `func` in a task, similar to `Channel(func)`.

# Arguments
- `func::Function`: Function to execute with the channel
- `num_samples::Integer`: Number of samples per buffer
- `size`: Channel buffer size (default 16)
- `taskref`: Optional reference to store the created task
- `spawn`: If true, schedule task on any thread; if false, yield to it immediately

# Examples
```julia
# Single channel (shape: 1024×1)
chan = SignalChannel{ComplexF32,1}(1024) do c
    for i in 1:100
        data = rand(ComplexF32, 1024, 1)
        put!(c, data)
    end
end

# Multi-channel (shape: 1024×4)
chan = SignalChannel{ComplexF32,4}(1024, 10) do c
    for i in 1:100
        data = rand(ComplexF32, 1024, 4)
        put!(c, data)
    end
end
```
"""
function SignalChannel{T,N,M}(
    func::Function,
    num_samples::Integer,
    size=16;
    taskref=nothing,
    spawn=false,
) where {T,N,M}
    chnl = SignalChannel{T,N,M}(num_samples, size)
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

# Convenience: SignalChannel{T,N}(func, ...) defaults the backing type to Matrix{T}
function SignalChannel{T,N}(
    func::Function,
    num_samples::Integer,
    size=16;
    taskref=nothing,
    spawn=false,
) where {T,N}
    return SignalChannel{T,N,Matrix{T}}(func, num_samples, size; taskref=taskref, spawn=spawn)
end

# Convenience: SignalChannel{T}(func, num_samples, size) defaults to N=1, M=Matrix{T}
function SignalChannel{T}(
    func::Function,
    num_samples::Integer,
    size=16;
    taskref=nothing,
    spawn=false,
) where {T}
    return SignalChannel{T,1,Matrix{T}}(func, num_samples, size; taskref=taskref, spawn=spawn)
end

@inline function _check_put_dims(c::SignalChannel{T,N}, v) where {T,N}
    if size(v, 1) != c.num_samples || size(v, 2) != N
        throw(
            ArgumentError(
                "Matrix dimensions $(size(v)) do not match expected ($(c.num_samples), $N)",
            ),
        )
    end
    return nothing
end

"""
    put!(c::SignalChannel{T,N,M}, v::AbstractMatrix{T})

Put a matrix into the channel. Validates that the matrix dimensions match the channel's
`num_samples` and `N` (number of antenna channels).

If `v` is already of the channel's backing type `M` it is stored by reference
(zero-copy). This is the common case for the default `M = Matrix{T}`. Otherwise `v`
is converted into an `M` via the `M(v)` constructor, which allocates a new buffer.

# Throws
- `ArgumentError`: If matrix dimensions don't match the channel configuration
"""
# Coerce a matrix to the backing type `M`. Modeled on `Base.convert`'s
# `(::Type{T}, ::T)` / `(::Type{T}, x)` pair so the identity case dispatches
# reliably (unlike a `v::M` method on `put!`, where `M` is a diagonal type
# variable shared with the channel type and is not treated as more specific
# than the `AbstractMatrix` fallback).
@inline _as_backing(::Type{M}, v::M) where {M<:AbstractMatrix} = v
@inline _as_backing(::Type{M}, v::AbstractMatrix) where {M<:AbstractMatrix} = M(v)::M

function Base.put!(c::SignalChannel{T,N,M}, v::AbstractMatrix{T}) where {T,N,M}
    _check_put_dims(c, v)
    Base.put!(c.channel, _as_backing(M, v))
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
    put!(c::SignalChannel{T,N,M}, values::AbstractVector{<:AbstractMatrix{T}}) where {T,N,M}

Add multiple matrices to the channel in a single batch operation.
Blocks until all items are written. Returns the input vector.

This is more efficient than calling `put!` repeatedly because it uses the
underlying PipeChannel's batch operation, reducing atomic overhead.

The element type of `values` must be the channel's backing type `M` (e.g. a
`Vector{M}`). All matrices must match the channel's `num_samples` and `N`
(number of antenna channels).

# Throws
- `ArgumentError`: If any matrix dimensions don't match the channel configuration
- `InvalidStateException`: If the channel is closed

# Examples
```julia
chan = SignalChannel{ComplexF32,4}(1024)
buffers = [rand(ComplexF32, 1024, 4) for _ in 1:8]
put!(chan, buffers)  # Batch put all 8 buffers
```
"""
function Base.put!(c::SignalChannel{T,N,M}, values::AbstractVector{<:AbstractMatrix{T}}) where {T,N,M}
    # Validate all matrices have correct dimensions
    for (i, v) in enumerate(values)
        if size(v, 1) != c.num_samples || size(v, 2) != N
            throw(
                ArgumentError(
                    "Matrix $i dimensions $(size(v)) do not match expected ($(c.num_samples), $N)",
                ),
            )
        end
    end
    Base.put!(c.channel, values)
end

"""
    take!(c::SignalChannel{T,N}, n::Integer) where {T,N}

Remove and return exactly `n` matrices from the channel in a single batch operation.
Blocks until all `n` items are available.

# Returns
- `Vector{M}`: Vector of exactly `n` matrices (where `M` is the channel's backing type)

# Throws
- `InvalidStateException`: If the channel is closed before `n` items can be read

# Examples
```julia
chan = SignalChannel{ComplexF32,4}(1024)
# ... producer puts data ...
batch = take!(chan, 8)  # Returns vector of 8 matrices
```
"""
function Base.take!(c::SignalChannel{T,N}, n::Integer) where {T,N}
    Base.take!(c.channel, n)
end

"""
    take!(c::SignalChannel{T,N,M}, output::AbstractVector{<:AbstractMatrix{T}}) where {T,N,M}

Remove matrices from the channel into a pre-allocated output vector.
Blocks until the entire output buffer is filled. Returns `length(output)`.

This variant avoids allocation by writing into a provided buffer.

# Returns
- `Int`: Number of matrices read (always `length(output)`)

# Throws
- `InvalidStateException`: If the channel is closed before the buffer can be filled

# Examples
```julia
chan = SignalChannel{ComplexF32,4}(1024)
buffer = Vector{Matrix{ComplexF32}}(undef, 8)
take!(chan, buffer)  # Fills buffer with 8 matrices
```
"""
function Base.take!(c::SignalChannel{T,N}, output::AbstractVector{<:AbstractMatrix{T}}) where {T,N}
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
Base.eltype(::Type{SignalChannel{T,N,M}}) where {T,N,M} = M

# Iterator support: allows `for buffer in channel` syntax.
# The @inline annotation is critical to avoid heap allocation of the (value, state)
# tuple for non-isbits types like Matrix (the buffer element type).
@inline Base.iterate(c::SignalChannel, state=nothing) = Base.iterate(c.channel, state)
Base.IteratorSize(::Type{<:SignalChannel}) = Base.SizeUnknown()

"""
    Base.similar(c::SignalChannel{T,N}, [size::Int=16]) where {T,N}

Create a new SignalChannel with the same dimensions as `c` but with optional buffer size.

# Arguments
- `c`: Input SignalChannel
- `size`: Optional buffer size (default: 16)

# Examples
```julia
input = SignalChannel{ComplexF32,4}(1024, 10)
output = similar(input)        # Same dimensions, buffer size 16
buffered = similar(input, 32)  # Same dimensions, buffer size 32
```
"""
Base.similar(c::SignalChannel{T,N,M}, size::Int=16) where {T,N,M} =
    SignalChannel{T,N,M}(c.num_samples, size)


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
