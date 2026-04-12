@testitem "M0 carryover: hpack" begin
    include(joinpath(@__DIR__, "test_hpack.jl"))
end

@testitem "M0 carryover: http2_stream" begin
    include(joinpath(@__DIR__, "test_http2_stream.jl"))
end

@testitem "M0 carryover: http2_conformance" begin
    include(joinpath(@__DIR__, "test_http2_conformance.jl"))
end

@testitem "M0 carryover: stream_state_validation" begin
    include(joinpath(@__DIR__, "test_stream_state_validation.jl"))
end

@testitem "M0 carryover: connection_management" begin
    include(joinpath(@__DIR__, "test_connection_management.jl"))
end
