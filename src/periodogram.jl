using DSP
using Unitful
using LiveLayoutUnicodePlots
using UnicodePlots

"""
    PeriodogramData

Data structure containing periodogram analysis results.

# Fields
- `freqs::Vector{Float64}`: Frequency bins (Hz)
- `powers::Vector{Float64}`: Power spectral density values (dB)
- `timestamp::Float64`: Timestamp in seconds
"""
struct PeriodogramData
    freqs::Vector{Float64}
    powers::Vector{Float64}
    timestamp::Float64
end

"""
    get_periodogram_channel(data_channel::SignalChannel, sampling_freq;
                           window=hamming, push_roughly_every=100u"ms")

Processes incoming sample data and computes periodograms at regular intervals.
Returns a channel that outputs `PeriodogramData`.

# Arguments
- `data_channel::SignalChannel{T}`: Input channel containing signal data
- `sampling_freq`: Sampling frequency (with units, e.g., `10u"MHz"`)
- `window`: Window function to apply (default: `hamming`)
- `push_roughly_every`: Approximate time interval between periodogram updates (default: `100u"ms"`)

# Returns
- `Channel{PeriodogramData}`: Channel that outputs periodogram data structures

# Examples
```julia
# Create a signal channel with 1024 samples
data_chan = SignalChannel{ComplexF32}(1024)

# Create periodogram channel that updates every 100ms
pgram_chan = get_periodogram_channel(data_chan, 10u"MHz")

# Consume periodogram data
for pgram in pgram_chan
    # Process pgram.freqs, pgram.powers, pgram.timestamp
end
```
"""
function calculate_periodogram(
    data_channel::SignalChannel{T},
    sampling_freq;
    window=hamming,
    push_roughly_every=100u"ms",
    channel_size=10
) where {T}
    periodogram_channel = Channel{PeriodogramData}(channel_size)
    last_output = 0.0u"ms"
    runtime = 0.0u"ms"
    first = true

    task = Threads.@spawn begin
        consume_channel(data_channel) do data
            # Update runtime based on number of samples
            num_samples = size(data, 1)
            chunk_duration = num_samples / ustrip(u"Hz", sampling_freq) * 1000u"ms"
            runtime += chunk_duration

            # Check if it's time to push new periodogram data
            if (runtime - last_output) > push_roughly_every || first
                # Take first channel if multi-channel
                samples = @view data[:, 1]

                # Compute periodogram
                fs = ustrip(u"Hz", sampling_freq)
                pxx_result = DSP.fftshift(periodogram(samples; onesided=false, fs=fs, window=window))

                # Create periodogram data structure
                pgram_data = PeriodogramData(
                    pxx_result.freq,
                    pxx_result.power,
                    ustrip(u"s", runtime),
                )

                push!(periodogram_channel, pgram_data)
                last_output = runtime
                first = false
            end
        end
        close(periodogram_channel)
    end

    bind(periodogram_channel, task)
    periodogram_channel
end

"""
    periodogram_liveplot(periodogram_channel::Channel{PeriodogramData})

Displays a real-time updating plot of the periodogram data using LivePlot with UnicodePlots.
The plot updates as new periodogram data arrives through the channel.
"""
function periodogram_liveplot(periodogram_channel::Channel{PeriodogramData})
    live_plot = LivePlot()

    # Track min/max power values across all iterations
    min_power = Inf
    max_power = -Inf

    consume_channel_with_warnings(periodogram_channel; max_warnings=20) do pgram_data, accumulated_warnings
        # Track minimum and maximum power values
        power = 10 .* log10.(pgram_data.powers)
        min_power = min(min_power, minimum(power))
        max_power = max(max_power, maximum(power))

        # Create the dual-panel layout
        layout_result = @layout [
            UnicodePlots.lineplot(
                pgram_data.freqs,
                power;
                xlabel="Frequency (Hz)",
                ylabel="Power Spectral Density",
                title="Real-time Periodogram - Time: $(round(pgram_data.timestamp, digits=2)) s",
                ylim=(min_power, max_power),
            ),
            textplot(
                join(accumulated_warnings, '\n');
                width=40,
                title="Recent Warnings",
                border=:solid
            )
        ]
        live_plot(layout_result)
    end
end