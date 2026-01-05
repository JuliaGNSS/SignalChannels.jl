# Changelog

## [4.0.1](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v4.0.0...v4.0.1) (2026-01-05)


### Bug Fixes

* **benchmark:** use FixedSizeMatrixDefault to avoid put! conversion allocations ([c002824](https://github.com/JuliaGNSS/SignalChannels.jl/commit/c002824bfccdf177c824f19171f5f749aed2ed8e))

# [4.0.0](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.9...v4.0.0) (2025-12-19)


* refactor!: remove put_or_close! in favor of bind for error propagation ([24c4f3f](https://github.com/JuliaGNSS/SignalChannels.jl/commit/24c4f3f87704ec9812041bbadd380c3c9b88ac12))


### BREAKING CHANGES

* put_or_close! is no longer exported. Use plain put!
instead - bind() handles error propagation when downstream closes.

The put_or_close! function was redundant - bind(in, task) already
handles error propagation when a processing task fails due to a
closed downstream channel. Simplified tee, rechunk, and membuffer
to use plain put! calls.

Added test verifying that errors propagate upstream via bind when
a downstream channel is closed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>

## [3.0.9](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.8...v3.0.9) (2025-12-15)


### Bug Fixes

* buffer pool aliasing bug in rechunk and stream_data ([4ab734e](https://github.com/JuliaGNSS/SignalChannels.jl/commit/4ab734e8ea6c9978a60bc37ac99c17eecae92812))

## [3.0.8](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.7...v3.0.8) (2025-12-12)


### Bug Fixes

* propagating errors ([279ee1d](https://github.com/JuliaGNSS/SignalChannels.jl/commit/279ee1da3d170de4781873851d2d4781c18910f8))

## [3.0.7](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.6...v3.0.7) (2025-12-12)


### Bug Fixes

* properly close upstream channels and drain incoming channel ([96b9104](https://github.com/JuliaGNSS/SignalChannels.jl/commit/96b9104bfee513f71ce0a58c17f38c8e7fdd5f78))

## [3.0.6](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.5...v3.0.6) (2025-12-11)


### Performance Improvements

* add benchmark for signal channel ([fd0d739](https://github.com/JuliaGNSS/SignalChannels.jl/commit/fd0d73928effc9647e2d9bb9ea9773a8c542da57))

## [3.0.5](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.4...v3.0.5) (2025-12-10)


### Bug Fixes

* show warnings when writing to file ([8a6f9c4](https://github.com/JuliaGNSS/SignalChannels.jl/commit/8a6f9c4792502ee4e7672f5d5ee02ba36a458749))

## [3.0.4](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.3...v3.0.4) (2025-12-10)


### Performance Improvements

* add benchmark for tee ([66b8acf](https://github.com/JuliaGNSS/SignalChannels.jl/commit/66b8acf5f67bafac9cb234169d647eb561075b64))

## [3.0.3](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.2...v3.0.3) (2025-12-10)


### Performance Improvements

* improve performance of rechunk ([487cb1f](https://github.com/JuliaGNSS/SignalChannels.jl/commit/487cb1f289257f8be75a4943057b382df2f38724))

## [3.0.2](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.1...v3.0.2) (2025-12-10)


### Performance Improvements

* add benchmark script for rechunk ([3a4ce47](https://github.com/JuliaGNSS/SignalChannels.jl/commit/3a4ce473c04c13fa49cfa1c546e47a5a38ebb102))

## [3.0.1](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v3.0.0...v3.0.1) (2025-12-07)


### Bug Fixes

* reduce allocations in SoapySDR stream hot paths ([d971224](https://github.com/JuliaGNSS/SignalChannels.jl/commit/d9712241ce711745577e2296eba12a1fa8e70e6f))

# [3.0.0](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v2.0.0...v3.0.0) (2025-12-07)

# [2.0.0](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v1.0.2...v2.0.0) (2025-12-04)


* feat!: replace [@warn](https://github.com/warn) in hot loops with warning channel ([44794e0](https://github.com/JuliaGNSS/SignalChannels.jl/commit/44794e062622f1684982e315f305c0fb18fa0233))


### BREAKING CHANGES

* stream_data now returns a tuple instead of a single value.
- RX stream_data returns (signal_channel, warning_channel) instead of signal_channel
- TX stream_data returns (task, warning_channel) instead of task

Changes:
- Add StreamWarning struct to hold warning info (type, time, error code)
- Add push_warning! helper that silently drops if channel is full
- Update periodogram_liveplot to accept optional warning_channel
- Remove consume_channel_with_warnings (no longer needed)
- Update convenience functions and tests for new API

This avoids the performance overhead of @warn in the hot read/write
loops while still making warnings accessible to callers.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>

## [1.0.2](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v1.0.1...v1.0.2) (2025-12-01)


### Bug Fixes

* tasks should only be bound to out channels ([619f82c](https://github.com/JuliaGNSS/SignalChannels.jl/commit/619f82c8dad8f0ebd57d8c400e6e92b6695c4360))

## [1.0.1](https://github.com/JuliaGNSS/SignalChannels.jl/compare/v1.0.0...v1.0.1) (2025-11-28)


### Bug Fixes

* add SoapySDR as weakdep for proper extension loading ([9a3648b](https://github.com/JuliaGNSS/SignalChannels.jl/commit/9a3648b2ff6b255c8c0fd3b89285cd603d9d9d78))
* pass Ref{Cint} instead of nothing to SoapySDRDevice_writeStream ([a3b97ba](https://github.com/JuliaGNSS/SignalChannels.jl/commit/a3b97ba15e2eac00761649ebce10c38a36f715ce))

# 1.0.0 (2025-11-28)


### Bug Fixes

* make api more general ([fa676c5](https://github.com/JuliaGNSS/SignalChannels.jl/commit/fa676c514f36254f279adde841aa8ec1e2b92df8))
