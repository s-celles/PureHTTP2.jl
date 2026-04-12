module HTTP2

include("frames.jl")
include("hpack.jl")
include("stream.jl")
include("flow_control.jl")
include("connection.jl")

# Public API (Milestone 2): frames layer
export FrameType, FrameFlags, ErrorCode, SettingsParameter
export FrameHeader, Frame
export encode_frame, decode_frame
export encode_frame_header, decode_frame_header, has_flag
export data_frame, headers_frame, settings_frame, parse_settings_frame
export ping_frame, goaway_frame, parse_goaway_frame
export rst_stream_frame, window_update_frame, parse_window_update_frame
export continuation_frame
export FRAME_HEADER_SIZE, CONNECTION_PREFACE
export DEFAULT_INITIAL_WINDOW_SIZE, DEFAULT_MAX_FRAME_SIZE
export MIN_MAX_FRAME_SIZE, MAX_MAX_FRAME_SIZE, DEFAULT_HEADER_TABLE_SIZE

# Public API (Milestone 2): HPACK layer
export DynamicTable, HPACKEncoder, HPACKDecoder
export encode_headers, decode_headers
export set_max_table_size!, encode_table_size_update
export huffman_encode, huffman_decode, huffman_encoded_length
export encode_integer, decode_integer
export encode_string, decode_string

end # module HTTP2
