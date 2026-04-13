@testitem "HPACK: huffman encoding" begin
    using PureHTTP2

    @testset "Basic encoding roundtrip" begin
        test_strings = [
            "www.example.com",
            "application/grpc",
            "localhost",
            "grpc.health.v1.Health",
            "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo",
            "POST",
            "GET",
            "200",
            "content-type",
            "te",
            "trailers",
        ]

        for s in test_strings
            raw_data = Vector{UInt8}(s)
            encoded = PureHTTP2.huffman_encode(raw_data)
            decoded = PureHTTP2.huffman_decode(encoded)
            @test String(decoded) == s
        end
    end

    @testset "Empty string" begin
        empty = UInt8[]
        encoded = PureHTTP2.huffman_encode(empty)
        @test isempty(encoded)
        decoded = PureHTTP2.huffman_decode(encoded)
        @test isempty(decoded)
    end

    @testset "Single characters" begin
        for c in ['a', 'A', '0', ' ', '/', ':']
            data = Vector{UInt8}(string(c))
            encoded = PureHTTP2.huffman_encode(data)
            decoded = PureHTTP2.huffman_decode(encoded)
            @test String(decoded) == string(c)
        end
    end

    @testset "All printable ASCII" begin
        for byte in UInt8(32):UInt8(126)
            data = [byte]
            encoded = PureHTTP2.huffman_encode(data)
            decoded = PureHTTP2.huffman_decode(encoded)
            @test decoded == data
        end
    end

    @testset "Space savings" begin
        test_cases = [
            ("www.example.com", true),
            ("application/grpc", true),
            ("localhost", true),
            ("POST", false),
        ]

        for (s, should_save) in test_cases
            raw_data = Vector{UInt8}(s)
            encoded = PureHTTP2.huffman_encode(raw_data)
            if should_save
                @test length(encoded) <= length(raw_data)
            end
            decoded = PureHTTP2.huffman_decode(encoded)
            @test String(decoded) == s
        end
    end
end

@testitem "HPACK: huffman encoded length" begin
    using PureHTTP2

    @testset "Length calculation matches actual encoding" begin
        test_strings = [
            "www.example.com",
            "localhost",
            "application/grpc",
            "Hello, World!",
        ]

        for s in test_strings
            raw_data = Vector{UInt8}(s)
            predicted_len = PureHTTP2.huffman_encoded_length(raw_data)
            actual_encoded = PureHTTP2.huffman_encode(raw_data)
            @test predicted_len == length(actual_encoded)
        end
    end

    @testset "Empty string" begin
        @test PureHTTP2.huffman_encoded_length(UInt8[]) == 0
    end
end

@testitem "HPACK: integer encoding" begin
    using PureHTTP2

    @testset "Small values (fit in prefix)" begin
        for prefix_bits in [5, 6, 7]
            max_prefix = (1 << prefix_bits) - 1
            for value in 0:(max_prefix - 1)
                encoded = PureHTTP2.encode_integer(value, prefix_bits)
                @test length(encoded) == 1
                @test encoded[1] == value
            end
        end
    end

    @testset "Large values (multi-byte encoding)" begin
        test_cases = [
            (127, 7),
            (128, 7),
            (255, 7),
            (1000, 7),
            (16383, 6),
        ]

        for (value, prefix_bits) in test_cases
            encoded = PureHTTP2.encode_integer(value, prefix_bits)
            decoded, offset = PureHTTP2.decode_integer(encoded, 1, prefix_bits)
            @test decoded == value
            @test offset == length(encoded) + 1
        end
    end

    @testset "Roundtrip for various prefix sizes" begin
        for prefix_bits in [4, 5, 6, 7]
            for value in [0, 1, 10, 100, 1000, 10000]
                encoded = PureHTTP2.encode_integer(value, prefix_bits)
                decoded, _ = PureHTTP2.decode_integer(encoded, 1, prefix_bits)
                @test decoded == value
            end
        end
    end
end

@testitem "HPACK: string encoding" begin
    using PureHTTP2

    @testset "Raw encoding (no Huffman)" begin
        test_strings = ["hello", "world", "test"]

        for s in test_strings
            encoded = PureHTTP2.encode_string(s; huffman=false)
            @test (encoded[1] & 0x80) == 0
            decoded_str, _ = PureHTTP2.decode_string(encoded, 1)
            @test decoded_str == s
        end
    end

    @testset "Huffman encoding" begin
        test_strings = [
            "www.example.com",
            "localhost",
            "application/grpc",
        ]

        for s in test_strings
            encoded = PureHTTP2.encode_string(s; huffman=true)
            raw_len = length(s)
            huff_encoded = PureHTTP2.huffman_encode(Vector{UInt8}(s))
            if length(huff_encoded) < raw_len
                @test (encoded[1] & 0x80) != 0
            end
            decoded_str, _ = PureHTTP2.decode_string(encoded, 1)
            @test decoded_str == s
        end
    end

    @testset "Empty string" begin
        encoded_raw = PureHTTP2.encode_string(""; huffman=false)
        @test encoded_raw == UInt8[0x00]

        encoded_huff = PureHTTP2.encode_string(""; huffman=true)
        @test encoded_huff == UInt8[0x00]

        decoded, _ = PureHTTP2.decode_string(encoded_raw, 1)
        @test decoded == ""
    end

    @testset "Huffman auto-fallback" begin
        short_string = "ab"
        encoded = PureHTTP2.encode_string(short_string; huffman=true)
        decoded, _ = PureHTTP2.decode_string(encoded, 1)
        @test decoded == short_string
    end
end

@testitem "HPACK: dynamic table" begin
    using PureHTTP2

    @testset "Basic operations" begin
        table = PureHTTP2.DynamicTable(4096)
        @test isempty(table.entries)
        @test table.size == 0
        @test table.max_size == 4096

        PureHTTP2.add!(table, "custom-header", "custom-value")
        @test length(table.entries) == 1
        @test table.entries[1] == ("custom-header", "custom-value")
        @test table.size == PureHTTP2.entry_size("custom-header", "custom-value")
    end

    @testset "Entry eviction" begin
        table = PureHTTP2.DynamicTable(100)

        PureHTTP2.add!(table, "header1", "value1")
        PureHTTP2.add!(table, "header2", "value2")
        PureHTTP2.add!(table, "header3", "value3")

        @test length(table.entries) <= 2
        @test table.size <= table.max_size
    end

    @testset "Resize" begin
        table = PureHTTP2.DynamicTable(4096)
        PureHTTP2.add!(table, "header", "value")

        Base.resize!(table, 0)
        @test isempty(table.entries)
        @test table.size == 0
        @test table.max_size == 0
    end

    @testset "Get entry spanning static and dynamic" begin
        table = PureHTTP2.DynamicTable(4096)
        PureHTTP2.add!(table, "x-custom", "test")

        @test PureHTTP2.get_entry(table, 1) == (":authority", "")
        @test PureHTTP2.get_entry(table, 2) == (":method", "GET")
        @test PureHTTP2.get_entry(table, 3) == (":method", "POST")

        @test PureHTTP2.get_entry(table, 62) == ("x-custom", "test")
    end
end

@testitem "HPACK: encoder/decoder" begin
    using PureHTTP2

    @testset "Basic header encoding/decoding" begin
        encoder = PureHTTP2.HPACKEncoder(4096)
        decoder = PureHTTP2.HPACKDecoder(4096)

        headers = [
            (":method", "GET"),
            (":path", "/"),
            (":scheme", "http"),
            ("host", "localhost"),
        ]

        encoded = PureHTTP2.encode_headers(encoder, headers)
        decoded = PureHTTP2.decode_headers(decoder, encoded)

        @test length(decoded) == length(headers)
        for (orig, dec) in zip(headers, decoded)
            @test orig == dec
        end
    end

    @testset "Indexed header field" begin
        encoder = PureHTTP2.HPACKEncoder(4096)
        decoder = PureHTTP2.HPACKDecoder(4096)

        encoded = PureHTTP2.encode_header(encoder, ":method", "GET")
        @test (encoded[1] & 0x80) != 0

        decoded = PureHTTP2.decode_headers(decoder, encoded)
        @test decoded == [(":method", "GET")]
    end

    @testset "Literal header with indexing" begin
        encoder = PureHTTP2.HPACKEncoder(4096)
        decoder = PureHTTP2.HPACKDecoder(4096)

        encoded = PureHTTP2.encode_header(encoder, "x-custom", "value"; indexing=:incremental)
        decoded = PureHTTP2.decode_headers(decoder, encoded)

        @test decoded == [("x-custom", "value")]
        @test !isempty(encoder.dynamic_table.entries)
        @test !isempty(decoder.dynamic_table.entries)
    end

    @testset "Never indexed headers" begin
        encoder = PureHTTP2.HPACKEncoder(4096)
        decoder = PureHTTP2.HPACKDecoder(4096)

        headers = [("authorization", "Bearer token123")]
        encoded = PureHTTP2.encode_headers(encoder, headers)
        decoded = PureHTTP2.decode_headers(decoder, encoded)

        @test decoded == headers
    end

    @testset "Huffman encoding in headers" begin
        encoder = PureHTTP2.HPACKEncoder(4096; use_huffman=true)
        decoder = PureHTTP2.HPACKDecoder(4096)

        headers = [
            (":path", "/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo"),
            ("content-type", "application/grpc"),
        ]

        encoded = PureHTTP2.encode_headers(encoder, headers)
        decoded = PureHTTP2.decode_headers(decoder, encoded)

        @test decoded == headers
    end

    @testset "Multiple requests maintain state" begin
        encoder = PureHTTP2.HPACKEncoder(4096)
        decoder = PureHTTP2.HPACKDecoder(4096)

        headers1 = [("x-request-id", "req-001"), (":method", "POST")]
        encoded1 = PureHTTP2.encode_headers(encoder, headers1)
        decoded1 = PureHTTP2.decode_headers(decoder, encoded1)
        @test decoded1 == headers1

        headers2 = [("x-request-id", "req-002"), (":method", "POST")]
        encoded2 = PureHTTP2.encode_headers(encoder, headers2)
        decoded2 = PureHTTP2.decode_headers(decoder, encoded2)
        @test decoded2 == headers2
    end
end

@testitem "HPACK: entry size calculation" begin
    using PureHTTP2

    # Per RFC 7541 Section 4.1: size = name_len + value_len + 32
    @test PureHTTP2.entry_size("name", "value") == 4 + 5 + 32
    @test PureHTTP2.entry_size("", "") == 0 + 0 + 32
    @test PureHTTP2.entry_size("content-type", "application/grpc") == 12 + 16 + 32
end

@testitem "HPACK: static table lookup" begin
    using PureHTTP2

    table = PureHTTP2.DynamicTable(4096)

    # Exact match in static table
    index, exact = PureHTTP2.find_index(table, ":method", "GET")
    @test index == 2
    @test exact == true

    # Name-only match in static table
    index, exact = PureHTTP2.find_index(table, ":method", "OPTIONS")
    @test index > 0
    @test exact == false

    # Not in table
    index, exact = PureHTTP2.find_index(table, "x-nonexistent", "value")
    @test index == 0
    @test exact == false
end
