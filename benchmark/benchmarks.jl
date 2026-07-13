using BenchmarkTools
using SignalChannels
using Pkg
using FixedSizeArrays: FixedSizeMatrixDefault

# Get package version for backward compatibility in benchmarks
const PACKAGE_VERSION = Pkg.Types.read_project(
    joinpath(dirname(@__DIR__), "Project.toml")
).version

# Detect the backing-array-type parameter API (SignalChannel{T,N,M}).
# The new API defaults to Matrix{T}; the old API is FixedSizeMatrixDefault-only.
# AirspeedVelocity runs this (head) script against both the PR and the baseline,
# so we feed each version its native zero-copy buffer type to keep the
# comparison fair and runnable on both.
const HAS_BACKING_TYPE_PARAM = try
    SignalChannel{ComplexF32,1,Matrix{ComplexF32}}
    true
catch
    false
end

# Wrap a plain array as the buffer type native to the current API:
# Matrix{T} on the new API (returned as-is, zero-copy), FixedSizeMatrixDefault{T}
# on the old API.
as_buffer(a::AbstractMatrix) =
    HAS_BACKING_TYPE_PARAM ? a : FixedSizeMatrixDefault{eltype(a)}(a)

const SUITE = BenchmarkGroup()

# Include individual benchmark files
include("channel_benchmarks.jl")
include("rechunk_benchmarks.jl")
include("rechunk_state_benchmarks.jl")
include("tee_benchmarks.jl")
include("soapysdr_benchmarks.jl")
