module SignalChannels

export SignalChannel,
    consume_channel,
    consume_channel_with_warnings,
    tee,
    rechunk,
    write_to_file,
    read_from_file,
    spawn_channel_thread,
    membuffer,
    generate_stream,
    stream_data,
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

end # module SignalChannels
