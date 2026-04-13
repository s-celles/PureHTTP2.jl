@testmodule HPACKFixtures begin
using JSON
export hex_to_bytes, producer_dir, all_stories, load_story
"""
    hex_to_bytes(s) -> Vector{UInt8}
Decode a lowercase/uppercase hex string into a byte vector. Errors on
odd-length or non-hex input.
"""
function hex_to_bytes(s::AbstractString)
    n = length(s)
    iseven(n) || error("hex_to_bytes: odd-length input ($(n) chars)")
    out = Vector{UInt8}(undef, n ÷ 2)
    @inbounds for i in 1:(n ÷ 2)
        pair = s[(2i - 1):(2i)]
        b = tryparse(UInt8, pair; base = 16)
        b === nothing && error("hex_to_bytes: invalid hex pair $(pair) at offset $(2i - 1)")
        out[i] = b
    end
    return out
end
"""
    producer_dir(producer) -> String
Absolute path to one of the hpack-test-case producer directories,
resolved relative to this setup module's file.
"""
function producer_dir(producer::AbstractString)
    return joinpath(@__DIR__, "fixtures", "hpack-test-case", producer)
end
"""
    all_stories(producer) -> Vector{String}
Sorted list of absolute paths to every `story_*.json` file for a
given producer.
"""
function all_stories(producer::AbstractString)
    dir = producer_dir(producer)
    files = readdir(dir)
    stories = filter(f -> startswith(f, "story_") && endswith(f, ".json"), files)
    sort!(stories)
    return [joinpath(dir, f) for f in stories]
end
"""
    load_story(path) -> Vector{NamedTuple}
Parse a story JSON file and return one NamedTuple per case. Each
tuple has fields:
- `seqno::Int` — the case index
- `wire::Vector{UInt8}` — the decoded HPACK wire bytes
- `headers::Vector{Tuple{String,String}}` — the expected decoded
  header list (order-preserving; duplicate names permitted)
"""
function load_story(path::AbstractString)
    data = JSON.parsefile(path)
    cases = data["cases"]
    # Not all producers ship `seqno` / `wire`: `raw-data` only has `headers`
    # because it is the raw input to encoder implementations. Return a
    # union-compatible shape and let callers decide what to check.
    result = Vector{NamedTuple{(:seqno, :wire, :headers), Tuple{Int, Vector{UInt8}, Vector{Tuple{String, String}}}}}(undef, length(cases))
    for (i, case) in enumerate(cases)
        seqno = haskey(case, "seqno") ? Int(case["seqno"]) : (i - 1)
        wire = haskey(case, "wire") ? hex_to_bytes(case["wire"]) : UInt8[]
        raw_headers = case["headers"]
        headers = Vector{Tuple{String, String}}(undef, length(raw_headers))
        for (j, h) in enumerate(raw_headers)
            # Each header is a single-key dict; preserves ordering and duplicates
            k = first(keys(h))
            v = h[k]
            headers[j] = (String(k), String(v))
        end
        result[i] = (seqno = seqno, wire = wire, headers = headers)
    end
    return result
end
end # @testmodule HPACKFixtures
@testitem "HPACK conformance: nghttp2" setup=[HPACKFixtures] begin
    using PureHTTP2
    stories_tested = Ref(0)
    cases_tested = Ref(0)
    for story_path in HPACKFixtures.all_stories("nghttp2")
        stories_tested[] += 1
        cases = HPACKFixtures.load_story(story_path)
        decoder = PureHTTP2.HPACKDecoder()
        for case in cases
            cases_tested[] += 1
            decoded = PureHTTP2.decode_headers(decoder, case.wire)
            @test decoded == case.headers
            # Round-trip: re-encode the decoded list with a fresh encoder
            # and re-decode with a fresh decoder, compare to the original.
            # HPACK is not byte-unique so we compare logical header lists,
            # not encoded bytes.
            encoder2 = PureHTTP2.HPACKEncoder()
            decoder2 = PureHTTP2.HPACKDecoder()
            re_encoded = PureHTTP2.encode_headers(encoder2, decoded)
            re_decoded = PureHTTP2.decode_headers(decoder2, re_encoded)
            @test re_decoded == decoded
        end
    end
    @info "HPACK conformance: nghttp2 — $(stories_tested[]) stories, $(cases_tested[]) cases"
end
@testitem "HPACK conformance: go-hpack" setup=[HPACKFixtures] begin
    using PureHTTP2
    stories_tested = Ref(0)
    cases_tested = Ref(0)
    for story_path in HPACKFixtures.all_stories("go-hpack")
        stories_tested[] += 1
        cases = HPACKFixtures.load_story(story_path)
        decoder = PureHTTP2.HPACKDecoder()
        for case in cases
            cases_tested[] += 1
            decoded = PureHTTP2.decode_headers(decoder, case.wire)
            @test decoded == case.headers
            encoder2 = PureHTTP2.HPACKEncoder()
            decoder2 = PureHTTP2.HPACKDecoder()
            re_encoded = PureHTTP2.encode_headers(encoder2, decoded)
            re_decoded = PureHTTP2.decode_headers(decoder2, re_encoded)
            @test re_decoded == decoded
        end
    end
    @info "HPACK conformance: go-hpack — $(stories_tested[]) stories, $(cases_tested[]) cases"
end
@testitem "HPACK conformance: python-hpack" setup=[HPACKFixtures] begin
    using PureHTTP2
    stories_tested = Ref(0)
    cases_tested = Ref(0)
    for story_path in HPACKFixtures.all_stories("python-hpack")
        stories_tested[] += 1
        cases = HPACKFixtures.load_story(story_path)
        decoder = PureHTTP2.HPACKDecoder()
        for case in cases
            cases_tested[] += 1
            decoded = PureHTTP2.decode_headers(decoder, case.wire)
            @test decoded == case.headers
            encoder2 = PureHTTP2.HPACKEncoder()
            decoder2 = PureHTTP2.HPACKDecoder()
            re_encoded = PureHTTP2.encode_headers(encoder2, decoded)
            re_decoded = PureHTTP2.decode_headers(decoder2, re_encoded)
            @test re_decoded == decoded
        end
    end
    @info "HPACK conformance: python-hpack — $(stories_tested[]) stories, $(cases_tested[]) cases"
end
@testitem "HPACK conformance: raw-data" setup=[HPACKFixtures] begin
    using PureHTTP2
    # The raw-data producer ships only `headers` — it is the raw input to
    # encoder implementations, not a source of HPACK wire bytes. The check
    # here is therefore an encoder-self-test: encode each header list with
    # PureHTTP2.jl and decode with PureHTTP2.jl, then compare to the original.
    stories_tested = Ref(0)
    cases_tested = Ref(0)
    for story_path in HPACKFixtures.all_stories("raw-data")
        stories_tested[] += 1
        cases = HPACKFixtures.load_story(story_path)
        for case in cases
            cases_tested[] += 1
            encoder = PureHTTP2.HPACKEncoder()
            decoder = PureHTTP2.HPACKDecoder()
            encoded = PureHTTP2.encode_headers(encoder, case.headers)
            decoded = PureHTTP2.decode_headers(decoder, encoded)
            @test decoded == case.headers
        end
    end
    @info "HPACK conformance: raw-data — $(stories_tested[]) stories, $(cases_tested[]) cases"
end
