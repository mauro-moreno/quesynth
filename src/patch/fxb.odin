package patch

Fxb_Kind :: enum {
	Chunk_Bank,
	Program_Bank,
}

Fxb_Error :: enum {
	None,
	Truncated,
	Wrong_Magic,
	Invalid_Chunk_Size,
}

Fxb :: struct {
	kind:         Fxb_Kind,
	byte_size:    u32,
	version:      u32,
	fx_id:        u32,
	fx_version:   u32,
	num_programs: u32,
	chunk:        []byte,
}

FXB_HEADER_SIZE :: 156
FXB_CHUNK_SIZE_OFFSET :: 156

read_be_u32 :: proc(data: []byte, offset: int) -> (value: u32, ok: bool) {
	if offset < 0 || len(data) < 4 || offset > len(data)-4 {
		return 0, false
	}
	value = (u32(data[offset]) << 24) |
		u32(data[offset+1]) << 16 |
		u32(data[offset+2]) << 8 |
		u32(data[offset+3])
	return value, true
}

parse_fxb :: proc(data: []byte) -> (bank: Fxb, err: Fxb_Error) {
	if len(data) < FXB_HEADER_SIZE {
		return {}, .Truncated
	}

	magic, _ := read_be_u32(data, 0)
	if magic != 0x43636e4b { // CcnK
		return {}, .Wrong_Magic
	}
	byte_size, _ := read_be_u32(data, 4)
	fx_magic, _ := read_be_u32(data, 8)
	version, _ := read_be_u32(data, 12)
	fx_id, _ := read_be_u32(data, 16)
	fx_version, _ := read_be_u32(data, 20)
	num_programs, _ := read_be_u32(data, 24)

	// byteSize describes all bytes after the byteSize field in the VST2
	// container. The declared end must cover the fixed header and be present
	// in the caller's backing slice.
	declared_end := u64(8) + u64(byte_size)
	if declared_end < u64(FXB_HEADER_SIZE) || declared_end > u64(len(data)) {
		return {}, .Truncated
	}

	bank = Fxb{
		byte_size = byte_size,
		version = version,
		fx_id = fx_id,
		fx_version = fx_version,
		num_programs = num_programs,
	}

	switch fx_magic {
	case 0x46424368: // FBCh: opaque bank chunk
		bank.kind = .Chunk_Bank
		chunk_start := u64(FXB_CHUNK_SIZE_OFFSET + 4)
		// The chunk-size field is part of the chunk-based container and must
		// itself lie within the declared container and backing slice.
		if declared_end < chunk_start || chunk_start > u64(len(data)) {
			return {}, .Truncated
		}
		chunk_size, ok := read_be_u32(data, FXB_CHUNK_SIZE_OFFSET)
		if !ok {
			return {}, .Truncated
		}
		chunk_end := chunk_start + u64(chunk_size)
		if chunk_end < chunk_start || chunk_end > declared_end || chunk_end > u64(len(data)) {
			return {}, .Truncated
		}
		bank.chunk = data[int(chunk_start):int(chunk_end)]
	case 0x4678426b: // FxBk: parameter/program bank, not an opaque chunk
		bank.kind = .Program_Bank
	case:
		return {}, .Wrong_Magic
	}

	return bank, .None
}
