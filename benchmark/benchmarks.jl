using BenchmarkTools
using SignalChannels
using Pkg

# Get package version for backward compatibility in benchmarks
const PACKAGE_VERSION = Pkg.Types.read_project(
    joinpath(dirname(@__DIR__), "Project.toml")
).version

const SUITE = BenchmarkGroup()

# Include individual benchmark files
include("channel_benchmarks.jl")
include("rechunk_benchmarks.jl")
include("tee_benchmarks.jl")
