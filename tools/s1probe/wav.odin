package s1probe

import "core:os"
import "core:mem"

// Write interleaved 32-bit float samples as a WAVE_FORMAT_IEEE_FLOAT file.
wav_write_f32 :: proc(path: string, samples: []f32, channels: int, sample_rate: int) -> bool {
	data_bytes := u32(len(samples) * size_of(f32))
	buf: [dynamic]u8
	defer delete(buf)

	put_str :: proc(b: ^[dynamic]u8, s: string) {
		for c in transmute([]u8)s do append(b, c)
	}
	put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
		x := v
		bytes := transmute([4]u8)x
		for c in bytes do append(b, c)
	}
	put_u16 :: proc(b: ^[dynamic]u8, v: u16) {
		x := v
		bytes := transmute([2]u8)x
		for c in bytes do append(b, c)
	}

	put_str(&buf, "RIFF")
	put_u32(&buf, 4 + 8 + 18 + 8 + data_bytes)
	put_str(&buf, "WAVE")

	put_str(&buf, "fmt ")
	put_u32(&buf, 18)
	put_u16(&buf, 3) // IEEE float
	put_u16(&buf, u16(channels))
	put_u32(&buf, u32(sample_rate))
	put_u32(&buf, u32(sample_rate * channels * 4))
	put_u16(&buf, u16(channels * 4))
	put_u16(&buf, 32)
	put_u16(&buf, 0)

	put_str(&buf, "data")
	put_u32(&buf, data_bytes)

	base := len(buf)
	resize(&buf, base + int(data_bytes))
	mem.copy(&buf[base], raw_data(samples), int(data_bytes))

	return os.write_entire_file(path, buf[:]) == nil
}
