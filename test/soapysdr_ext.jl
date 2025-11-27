module SoapySDRExtTest

using Test: @test, @testset, @test_throws, @test_skip, @test_broken

# Only run these tests if SoapySDR is available
if Base.find_package("SoapySDR") !== nothing
    using SignalChannels
    using SoapySDR
    using Unitful

    # Get the extension module and import stream_data
    const ext_module = Base.get_extension(SignalChannels, :SignalChannelsSoapySDRExt)
    const stream_data = ext_module.stream_data

    @testset "SoapySDR Extension" begin
        @testset "Extension loads correctly" begin
            # Test that the extension module exists
            @test !isnothing(ext_module)

            # Test that stream_data is defined in the extension
            @test isdefined(ext_module, :stream_data)
        end

        @testset "Loopback device tests" begin
            # Note: SoapyLoopback_jll has known issues with cleanup (crashes on finalization)
            # These tests are skipped to avoid crashes during testing
            # The extension functionality can be tested with real hardware
            @info "Skipping loopback device tests due to known SoapyLoopback_jll crashes"
            @test_skip false  # Indicate tests are intentionally skipped
        end

        @testset "Method signatures" begin
            # Test that the extension defines generate_stream for SoapySDR.Stream
            # Note: We need to check with type parameters for the stream
            found_generate_stream = false
            for m in methods(SignalChannels.generate_stream)
                sig = m.sig
                if sig isa UnionAll
                    sig = sig.body
                end
                # Check if this is the method we're looking for
                if sig <: Tuple{typeof(SignalChannels.generate_stream), Function, SoapySDR.Stream}
                    found_generate_stream = true
                    break
                end
            end
            @test found_generate_stream

            # Test that stream_data accepts Union{Event, Integer} as end condition
            # The actual signature uses Union{Base.Event, Integer}, so we check for that
            found_stream_data = false
            for m in methods(stream_data)
                sig = m.sig
                if sig isa UnionAll
                    sig = sig.body
                end
                # Check if this is the method with Union{Base.Event, Integer}
                if sig <: Tuple{typeof(stream_data), SoapySDR.Stream, Union{Base.Event, Integer}}
                    found_stream_data = true
                    break
                end
            end
            @test found_stream_data
        end
    end
else
    @testset "SoapySDR Extension (Skipped)" begin
        @info "SoapySDR not installed. Install with: using Pkg; Pkg.add(\"SoapySDR\")"
        @test true  # No-op test to indicate tests were skipped
    end
end

end # module SoapySDRExtTest
