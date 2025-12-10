module SignalChannels

export SignalChannel,
    StreamWarning,
    TxStats,
    consume_channel,
    tee,
    rechunk,
    write_to_file,
    read_from_file,
    spawn_signal_channel_thread,
    membuffer,
    stream_data,
    SDRChannelConfig,
    PeriodogramData,
    calculate_periodogram,
    periodogram_liveplot,
    sdr_periodogram_liveplot,
    sdr_record_to_file

include("signal_channel.jl")
include("channel_utilities.jl")
include("stream_utilities.jl")
include("periodogram.jl")

# Function stubs for extension - actual implementations in SignalChannelsSoapySDRExt
function stream_data end
function sdr_periodogram_liveplot end
function sdr_record_to_file end

using Unitful: Unitful

"""
    SDRChannelConfig(; sample_rate, frequency, bandwidth=nothing, gain=nothing, antenna=nothing, frequency_correction=nothing)

Configuration for an SDR RX or TX channel.

# Fields
- `sample_rate::Unitful.Frequency`: Sampling rate (e.g., `5e6u"Hz"`)
- `frequency::Unitful.Frequency`: Center frequency (e.g., `1.57542e9u"Hz"`)
- `bandwidth::Union{Nothing,Unitful.Frequency}`: Filter bandwidth. Defaults to `sample_rate` if `nothing`.
- `gain::Union{Nothing,Unitful.Gain}`: Gain setting. For RX, `nothing` enables automatic gain control (AGC).
- `antenna::Union{Nothing,String}`: Antenna port name. `nothing` uses the default antenna.
- `frequency_correction::Union{Nothing,Real}`: Frequency correction in PPM. `nothing` leaves unchanged.

# Examples
```julia
using SignalChannels
using Unitful: @u_str

# Basic RX configuration
rx_config = SDRChannelConfig(
    sample_rate = 5e6u"Hz",
    frequency = 1.57542e9u"Hz",
    gain = 50u"dB"
)

# TX configuration
tx_config = SDRChannelConfig(
    sample_rate = 5e6u"Hz",
    frequency = 2.4e9u"Hz",
    gain = -10u"dB"
)

# Multi-channel with different frequencies
configs = (
    SDRChannelConfig(sample_rate=5e6u"Hz", frequency=1.57542e9u"Hz"),
    SDRChannelConfig(sample_rate=5e6u"Hz", frequency=1.22760e9u"Hz"),
)
```
"""
Base.@kwdef struct SDRChannelConfig
    sample_rate::Unitful.Frequency
    frequency::Unitful.Frequency
    bandwidth::Union{Nothing,Unitful.Frequency} = nothing
    gain::Union{Nothing,Unitful.Gain} = nothing
    antenna::Union{Nothing,String} = nothing
    frequency_correction::Union{Nothing,Real} = nothing
end

end # module SignalChannels
