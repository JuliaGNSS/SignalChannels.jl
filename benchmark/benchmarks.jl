using BenchmarkTools
using SignalChannels

const SUITE = BenchmarkGroup()

# Include individual benchmark files
include("rechunk_benchmarks.jl")
include("tee_benchmarks.jl")
