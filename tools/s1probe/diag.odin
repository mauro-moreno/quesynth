// THROWAWAY DIAGNOSTICS. Not part of the shipped synth and not part of the
// verify oracle. These subcommands exist to answer the "out-of-range stored
// value" question in docs/synth1-param-encoding.md by measurement.
//
//   s1probe chunkdump [dll]                  -> dump effGetChunk bank+program
//   s1probe chunkload [dll] <file.sy1>       -> effSetChunk the raw .sy1, read back
//   s1probe drivers   [dll] <param> <driver> -> re-sweep <param> per state of <driver>
//   s1probe chunkmap  [dll]                  -> empirically map chunk u32 slots to params
//   s1probe chunkpoke [dll] <param> <value>… -> write raw ints into the chunk, read back
package s1probe

import "core:fmt"
import "core:os"
import "core:strings"
import spatch "../../src/patch"

// ------------------------------------------------------------- chunkdump

hexdump :: proc(b: ^strings.Builder, data: []byte, limit: int) {
	n := min(len(data), limit)
	for off := 0; off < n; off += 16 {
		fmt.sbprintf(b, "%08x  ", off)
		for i in 0 ..< 16 {
			if off + i < n {
				fmt.sbprintf(b, "%02x ", data[off + i])
			} else {
				strings.write_string(b, "   ")
			}
			if i == 7 {strings.write_string(b, " ")}
		}
		strings.write_string(b, " |")
		for i in 0 ..< 16 {
			if off + i >= n {break}
			c := data[off + i]
			if c >= 0x20 && c < 0x7f {
				strings.write_byte(b, c)
			} else {
				strings.write_byte(b, '.')
			}
		}
		strings.write_string(b, "|\n")
	}
}

get_chunk :: proc(p: ^Plugin, index: i32) -> []byte {
	buf: rawptr
	size := p.eff.dispatcher(p.eff, i32(Op.GetChunk), index, 0, &buf, 0)
	if size <= 0 || buf == nil {
		return nil
	}
	return (cast([^]byte)buf)[:size]
}

cmd_chunkdump :: proc(dll: string) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)

	fmt.printfln("flags: chunks=%v", p.eff.flags & FLAG_PROGRAM_CHUNKS != 0)

	for index in i32(0) ..= 1 {
		kind := index == 0 ? "bank" : "program"
		data := get_chunk(&p, index)
		fmt.printfln("--- effGetChunk index=%v (%v): size=%v", index, kind, len(data))
		if len(data) == 0 {continue}

		out := fmt.tprintf("build/chunk-%v.bin", kind)
		_ = os.write_entire_file(out, data)
		fmt.printfln("wrote %v", out)

		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		hexdump(&b, data, 1024)
		fmt.print(strings.to_string(b))
	}
}

// ------------------------------------------------------------- chunkload

// Feed raw bytes to effSetChunk and report every live parameter afterwards.
// If Synth1's own state chunk is its .sy1 text, this runs Synth1's own loader
// and the read-back is the authoritative mapping.
cmd_chunkload :: proc(dll, path: string, index: i32) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("chunkload: cannot read %q: %v", path, read_err)
		os.exit(1)
	}
	defer delete(data, context.allocator)

	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	parsed, parse_err := spatch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("chunkload: parse %q: %v", path, parse_err)
		os.exit(1)
	}

	// Record the untouched state so a no-op SetChunk is detectable.
	before: [spatch.PARAMETER_COUNT]f32
	for i in 0 ..< spatch.PARAMETER_COUNT {
		before[i] = e.get_parameter(e, i32(i))
	}

	rc := e.dispatcher(e, i32(Op.SetChunk), index, len(data), raw_data(data), 0)
	fmt.printfln("effSetChunk index=%v size=%v -> rc=%v", index, len(data), rc)

	changed := 0
	for i in 0 ..< spatch.PARAMETER_COUNT {
		if e.get_parameter(e, i32(i)) != before[i] {changed += 1}
	}
	fmt.printfln("parameters changed by SetChunk: %v", changed)

	fmt.println("idx\tpresent\tfilevalue\tnorm\tdisplay\tname")
	for i in 0 ..< spatch.PARAMETER_COUNT {
		norm := e.get_parameter(e, i32(i))
		disp := dispatch_str(&p, .GetParamDisplay, i32(i))
		fv := -1
		if parsed.present[i] {fv = parsed.values[i]}
		fmt.printfln("%v\t%v\t%v\t%.9f\t%v\t%v",
			i, parsed.present[i], fv, norm, disp, spatch.PARAMETERS[i].name)
	}
}

// --------------------------------------------------------------- drivers

// H2: is the target parameter's state set context dependent? Hold `driver` at
// each of its own states and re-enumerate `target`'s states each time.
cmd_drivers :: proc(dll: string, target, driver: i32) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	SWEEP :: 16384

	// Enumerate the driver's own states first.
	dnorms: [dynamic]f32
	defer delete(dnorms)
	{
		prev := f32(-1)
		for k in 0 ..= SWEEP {
			v := f32(k) / f32(SWEEP)
			e.set_parameter(e, driver, v)
			r := e.get_parameter(e, driver)
			if k == 0 || r != prev {
				append(&dnorms, r)
				prev = r
			}
		}
	}
	dname := dispatch_str(&p, .GetParamName, driver)
	tname := dispatch_str(&p, .GetParamName, target)
	fmt.printfln("driver %v (%v) has %v states; target %v (%v)",
		driver, dname, len(dnorms), target, tname)

	if len(dnorms) > 64 {
		fmt.printfln("driver has too many states to enumerate exhaustively; aborting")
		return
	}

	for dn, di in dnorms {
		e.set_parameter(e, driver, dn)
		ddisp := dispatch_str(&p, .GetParamDisplay, driver)

		norms: [dynamic]f32
		disps: [dynamic]string
		defer delete(norms)
		defer delete(disps)
		prev := f32(-1)
		for k in 0 ..= SWEEP {
			v := f32(k) / f32(SWEEP)
			e.set_parameter(e, target, v)
			r := e.get_parameter(e, target)
			if k == 0 || r != prev {
				append(&norms, r)
				append(&disps, dispatch_str(&p, .GetParamDisplay, target))
				prev = r
			}
		}
		fmt.printfln("driver state %v (norm %.9f, display %q) -> target states = %v",
			di, dn, ddisp, len(norms))
		if len(norms) <= 64 {
			for n, k in norms {
				fmt.printfln("    %v norm=%.9f display=%q", k, n, disps[k])
			}
		}
	}
}

// ------------------------------------------------------------------ coerce

// H3 fallback: what does the plugin snap to for each candidate reading of an
// out-of-range stored integer? Purely descriptive; picks no rule.
cmd_coerce :: proc(dll: string, target: i32, values: []int) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	SWEEP :: 16384
	norms: [dynamic]f32
	disps: [dynamic]string
	defer delete(norms)
	defer delete(disps)
	prev := f32(-1)
	for k in 0 ..= SWEEP {
		v := f32(k) / f32(SWEEP)
		e.set_parameter(e, target, v)
		r := e.get_parameter(e, target)
		if k == 0 || r != prev {
			append(&norms, r)
			append(&disps, dispatch_str(&p, .GetParamDisplay, target))
			prev = r
		}
	}
	n := len(norms)
	tname := dispatch_str(&p, .GetParamName, target)
	fmt.printfln("param %v (%v): %v states", target, tname, n)

	for v in values {
		fmt.printfln("-- stored value %v", v)
		// candidate A: direct state index (may be out of range)
		if v >= 0 && v < n {
			fmt.printfln("   state-index      -> norm=%.9f display=%q", norms[v], disps[v])
		} else {
			fmt.printfln("   state-index      -> OUT OF RANGE (n=%v)", n)
		}
		// candidate B: what the plugin does with the raw 128-grid norm
		cands := [][2]f64{
			{f64(v) / 128.0, 0},
			{(f64(v) + 0.5) / 128.0, 1},
			{f64(v) / f64(n), 2},
			{(f64(v) + 0.5) / f64(n), 3},
			{f64(v) / 127.0, 4},
		}
		names := []string{"v/128", "(v+0.5)/128", "v/n", "(v+0.5)/n", "v/127"}
		for c in cands {
			e.set_parameter(e, target, f32(c[0]))
			r := e.get_parameter(e, target)
			d := dispatch_str(&p, .GetParamDisplay, target)
			si := -1
			for nn, k in norms {
				if nn == r {si = k; break}
			}
			fmt.printfln("   %-12v sent=%.9f -> snap norm=%.9f state=%v display=%q",
				names[int(c[1])], c[0], r, si, d)
		}
	}
}

// -------------------------------------------------------------- chunkmap

// Copy the chunk out of plugin-owned memory; effGetChunk hands back an
// internal buffer that later calls overwrite.
get_chunk_copy :: proc(p: ^Plugin, index: i32) -> []byte {
	src := get_chunk(p, index)
	if len(src) == 0 {return nil}
	dst := make([]byte, len(src))
	copy(dst, src)
	return dst
}

read_le_u32 :: proc(data: []byte, off: int) -> u32 {
	return u32(data[off]) | u32(data[off+1]) << 8 | u32(data[off+2]) << 16 | u32(data[off+3]) << 24
}

write_le_u32 :: proc(data: []byte, off: int, v: u32) {
	data[off]   = byte(v)
	data[off+1] = byte(v >> 8)
	data[off+2] = byte(v >> 16)
	data[off+3] = byte(v >> 24)
}

// For each live parameter, move it to a state it is not currently in, re-read
// the chunk, and report which 4-byte slots changed. This derives the chunk
// layout from the plugin itself instead of assuming it.
cmd_chunkmap :: proc(dll: string, chunk_index: i32) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	fmt.println("param\tslot\tbyteoff\told\tnew\tnorm\tdisplay\tname")
	for i in 0 ..< spatch.PARAMETER_COUNT {
		base := get_chunk_copy(&p, chunk_index)
		if len(base) == 0 {
			fmt.eprintln("chunkmap: empty chunk")
			os.exit(1)
		}
		defer delete(base)

		saved := e.get_parameter(e, i32(i))
		// Find a normalised value that actually lands on a different state.
		moved := false
		for k in 0 ..= 64 {
			v := f32(k) / 64.0
			e.set_parameter(e, i32(i), v)
			if e.get_parameter(e, i32(i)) != saved {moved = true; break}
		}
		if !moved {
			fmt.printfln("%v\t-\t-\t-\t-\t-\t-\t%v (could not move)", i, spatch.PARAMETERS[i].name)
			continue
		}
		norm := e.get_parameter(e, i32(i))
		disp := dispatch_str(&p, .GetParamDisplay, i32(i))

		after := get_chunk_copy(&p, chunk_index)
		defer delete(after)

		hits := 0
		for off := 0; off + 4 <= len(base); off += 4 {
			a := read_le_u32(base, off)
			b := read_le_u32(after, off)
			if a != b {
				fmt.printfln("%v\t%v\t0x%x\t%v\t%v\t%.9f\t%v\t%v",
					i, off / 4, off, a, b, norm, disp, spatch.PARAMETERS[i].name)
				hits += 1
			}
		}
		if hits == 0 {
			fmt.printfln("%v\t-\t-\t-\t-\t%.9f\t%v\t%v (NO CHUNK SLOT CHANGED)",
				i, norm, disp, spatch.PARAMETERS[i].name)
		}
		e.set_parameter(e, i32(i), saved)
	}
}

// ------------------------------------------------------------- chunkpoke

// Write raw integers straight into the chunk's value slots and hand the chunk
// back with effSetChunk. This runs Synth1's own state-restore path over the
// exact integers a .sy1 file stores, which is the oracle for out-of-range
// values. `slot_base` and `stride` come from chunkmap output.
cmd_chunkpoke :: proc(dll: string, chunk_index: i32, slot_base, stride: int, pairs: [][2]int) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	chunk := get_chunk_copy(&p, chunk_index)
	if len(chunk) == 0 {
		fmt.eprintln("chunkpoke: empty chunk")
		os.exit(1)
	}
	defer delete(chunk)

	for pr in pairs {
		idx, val := pr[0], pr[1]
		off := slot_base + idx * stride
		if off + 4 > len(chunk) {
			fmt.eprintfln("chunkpoke: offset 0x%x for param %v is past the chunk", off, idx)
			os.exit(1)
		}
		old := read_le_u32(chunk, off)
		write_le_u32(chunk, off, u32(val))
		fmt.printfln("poke param %v at 0x%x: %v -> %v", idx, off, old, val)
	}

	rc := e.dispatcher(e, i32(Op.SetChunk), chunk_index, len(chunk), raw_data(chunk), 0)
	fmt.printfln("effSetChunk index=%v size=%v -> rc=%v", chunk_index, len(chunk), rc)

	for pr in pairs {
		idx := pr[0]
		norm := e.get_parameter(e, i32(idx))
		disp := dispatch_str(&p, .GetParamDisplay, i32(idx))
		fmt.printfln("read back param %v (%v): stored=%v norm=%.9f display=%q",
			idx, spatch.PARAMETERS[idx].name, pr[1], norm, disp)
	}
}

// ------------------------------------------------------------- chunkscan

// Sweep one parameter's stored integer over [lo,hi]. Each step restores a
// pristine default chunk with only that one slot overwritten, so every reading
// is independent. This is Synth1's own state-restore path, so the read-back is
// authoritative for values that setParameter's 0..1 domain cannot reach.
cmd_chunkscan :: proc(dll: string, chunk_index: i32, param: int, lo, hi: int) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	pristine := get_chunk_copy(&p, chunk_index)
	if len(pristine) == 0 {
		fmt.eprintln("chunkscan: empty chunk")
		os.exit(1)
	}
	defer delete(pristine)

	off := 572 + param * 8
	if off + 4 > len(pristine) {
		fmt.eprintfln("chunkscan: param %v past chunk", param)
		os.exit(1)
	}

	work := make([]byte, len(pristine))
	defer delete(work)

	// The canonical state table as reachable through setParameter 0..1, for
	// comparison against what the loader accepts.
	SWEEP :: 16384
	norms: [dynamic]f32
	defer delete(norms)
	{
		prev := f32(-1)
		for k in 0 ..= SWEEP {
			v := f32(k) / f32(SWEEP)
			e.set_parameter(e, i32(param), v)
			r := e.get_parameter(e, i32(param))
			if k == 0 || r != prev {append(&norms, r); prev = r}
		}
	}
	n := len(norms)
	fmt.printfln("# param %v (%v): setParameter-reachable states = %v",
		param, spatch.PARAMETERS[param].name, n)
	fmt.println("stored\tnorm\tstate_of_norm\tuniform_(v+0.5)/n\tdisplay")

	for v in lo ..= hi {
		copy(work, pristine)
		write_le_u32(work, off, u32(i32(v)))
		e.dispatcher(e, i32(Op.SetChunk), chunk_index, len(work), raw_data(work), 0)
		norm := e.get_parameter(e, i32(param))
		disp := dispatch_str(&p, .GetParamDisplay, i32(param))
		si := -1
		for nn, k in norms {
			if nn == norm {si = k; break}
		}
		fmt.printfln("%v\t%.9f\t%v\t%.9f\t%q", v, norm, si, (f64(v) + 0.5) / f64(n), disp)
	}
}

// ------------------------------------------------------------ chunkclass

// Classify every parameter's stored-integer convention using the loader.
//
// A 0-based parameter maps stored 0 to its lowest state. A 1-based parameter
// maps stored 1 to its lowest state and stored 0 underflows to the highest.
// Comparing the read-back for stored 0, 1 and 2 separates the two without
// needing a full sweep.
cmd_chunkclass :: proc(dll: string, chunk_index: i32) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	pristine := get_chunk_copy(&p, chunk_index)
	if len(pristine) == 0 {os.exit(1)}
	defer delete(pristine)
	work := make([]byte, len(pristine))
	defer delete(work)

	poke :: proc(p: ^Plugin, work, pristine: []byte, chunk_index: i32, param, v: int) -> (f32, string) {
		copy(work, pristine)
		write_le_u32(work, 572 + param * 8, u32(i32(v)))
		p.eff.dispatcher(p.eff, i32(Op.SetChunk), chunk_index, len(work), raw_data(work), 0)
		return p.eff.get_parameter(p.eff, i32(param)), dispatch_str(p, .GetParamDisplay, i32(param))
	}

	fmt.println("param\tclass\tn0\td0\tn1\td1\tn2\td2\tname")
	for i in 0 ..< spatch.PARAMETER_COUNT {
		n0, d0 := poke(&p, work, pristine, chunk_index, i, 0)
		n1, d1 := poke(&p, work, pristine, chunk_index, i, 1)
		n2, d2 := poke(&p, work, pristine, chunk_index, i, 2)
		class := "0-based"
		if n0 > n1 {class = "1-based"}
		if n0 == n1 {class = "flat?"}
		fmt.printfln("%v\t%v\t%.9f\t%q\t%.9f\t%q\t%.9f\t%q\t%v",
			i, class, n0, d0, n1, d1, n2, d2, spatch.PARAMETERS[i].name)
	}
}

// ---------------------------------------------------------------- setget

// Does setParameter accept values outside 0..1? The loader produces read-back
// values above 1.0 for out-of-range stored integers, so whether verify can
// reproduce them through setParameter decides how verify must be built.
cmd_setget :: proc(dll: string, param: int, values: []f64) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	fmt.println("sent\tread_back\tdisplay\tround_trips")
	for v in values {
		e.set_parameter(e, i32(param), f32(v))
		r := e.get_parameter(e, i32(param))
		d := dispatch_str(&p, .GetParamDisplay, i32(param))
		fmt.printfln("%.9f\t%.9f\t%q\t%v", v, r, d, r == f32(v))
	}
}

// ----------------------------------------------------------- oracletable

// Dump the loader's read-back for every live parameter over a range of stored
// integers, without the slow setParameter sweep. This is the bulk evidence the
// stored-integer -> normalised mapping is derived from and validated against.
//
//   s1probe oracletable [dll] <lo> <hi>   -> TSV on stdout: param, stored, norm
cmd_oracletable :: proc(dll: string, chunk_index: i32, lo, hi: int) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	pristine := get_chunk_copy(&p, chunk_index)
	if len(pristine) == 0 {
		fmt.eprintln("oracletable: empty chunk")
		os.exit(1)
	}
	defer delete(pristine)
	work := make([]byte, len(pristine))
	defer delete(work)

	fmt.println("param\tstored\tnorm")
	for i in 0 ..< spatch.PARAMETER_COUNT {
		off := 572 + i * 8
		if off + 4 > len(pristine) {continue}
		for v in lo ..= hi {
			copy(work, pristine)
			write_le_u32(work, off, u32(i32(v)))
			e.dispatcher(e, i32(Op.SetChunk), chunk_index, len(work), raw_data(work), 0)
			fmt.printfln("%v\t%v\t%.9f", i, v, e.get_parameter(e, i32(i)))
		}
	}
}

// s1probe states <index> - enumerate a parameter's states and what it calls them.
//
// Added for parameters 87 and 89, the MIDI controller destinations. Their list is
// not in the parameter table this project generated -- they read back as a raw
// fraction rather than as a state table -- and it is not the parameter numbering
// either: it is Synth1's own ordered list of assignable destinations, which is
// shorter than the parameter list and in its own order.
//
// The list can be read off the plugin's own dropdown, and this project has been
// caught three times by doing exactly that: the oscillator waveforms, the LFO
// destinations and the LFO waveforms all list in an order the plugin does not use.
// So it is swept instead, and the plugin is asked what each state is called.
cmd_states :: proc(dll: string, target: i32) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	SWEEP :: 65536
	tname := dispatch_str(&p, .GetParamName, target)

	norms: [dynamic]f32
	defer delete(norms)
	disps: [dynamic]string
	defer delete(disps)

	prev := f32(-1)
	for k in 0 ..= SWEEP {
		v := f32(k) / f32(SWEEP)
		e.set_parameter(e, target, v)
		r := e.get_parameter(e, target)
		if k == 0 || r != prev {
			append(&norms, r)
			append(&disps, dispatch_str(&p, .GetParamDisplay, target))
			prev = r
		}
	}

	fmt.printfln("parameter %v (%v): %v states", target, tname, len(norms))
	for i in 0 ..< len(norms) {
		fmt.printfln("%5v  norm %.9f  %q", i, norms[i], disps[i])
	}
}

// s1probe assigns - what each MIDI controller destination index actually moves.
//
// Parameters 87 and 89 hold a destination as a bare number: 44 in the factory
// patches, which the plugin's own panel shows as "lfo1 depth". The number is an
// index into Synth1's list of assignable destinations, which is shorter than the
// parameter list, in its own order, and nowhere in the data this project has
// extracted -- `GetParamDisplay` on parameter 87 returns the number back.
//
// The list can be read off a screenshot of the plugin's dropdown. It is not, and
// the reason is in docs/reference-notes.md three times over: the oscillator
// waveforms, the LFO destinations and the LFO waveforms each list in an order the
// plugin does not use, and each cost a wrong binding that looked right.
//
// So it is measured. For each destination index: point controller 1 at the
// modulation wheel with full sensitivity, read every parameter, send the wheel to
// 127, and read them all again. Whatever moved is the destination. Nothing here
// depends on hearing anything, which is what makes it exact.
cmd_assigns :: proc(dll: string, limit: int) {
	p, ok := load(dll)
	if !ok {os.exit(1)}
	defer unload(&p)
	e := p.eff

	count := int(e.num_params)
	before := make([]f32, count)
	defer delete(before)
	after := make([]f32, count)
	defer delete(after)

	// 0xB0 is a control change on channel 1 and 0x01 is the modulation wheel, so
	// 0xB001 is "the mod wheel" -- which is what the factory patches store in 86.
	MOD_WHEEL_SOURCE :: f32(45057.0 / 65536.0)

	fmt.println("destination  parameter  name")

	for dest in 0 ..< limit {
		e.set_parameter(e, 86, MOD_WHEEL_SOURCE)
		e.set_parameter(e, 87, f32(dest + 1) / 65536.0)
		e.set_parameter(e, 50, 1.0) // sensitivity at maximum
		// Park the wheel low, so the move below is a real change.
		send_midi(&p, 0xB0, 0x01, 0, 0)
		render_silence(&p, 2)

		for i in 0 ..< count {
			before[i] = e.get_parameter(e, i32(i))
		}
		send_midi(&p, 0xB0, 0x01, 127, 0)
		render_silence(&p, 2)
		for i in 0 ..< count {
			after[i] = e.get_parameter(e, i32(i))
		}

		moved := -1
		for i in 0 ..< count {
			// 50 and 86..89 are the routing itself and are expected to differ.
			if i == 50 || (i >= 86 && i <= 89) {
				continue
			}
			if abs(after[i] - before[i]) > 1.0e-6 {
				moved = i
				break
			}
		}
		if moved < 0 {
			fmt.printfln("%11v  %9v  %v", dest, "-", "nothing moved")
		} else {
			fmt.printfln("%11v  %9v  %v", dest, moved, dispatch_str(&p, .GetParamName, i32(moved)))
		}
	}
}

// Run a couple of blocks so the plugin acts on the events it was handed.
render_silence :: proc(p: ^Plugin, blocks: int) {
	e := p.eff
	nch := int(e.num_outputs)
	if nch < 1 {nch = 2}
	bufs := make([][]f32, nch)
	defer delete(bufs)
	ptrs := make([][^]f32, nch)
	defer delete(ptrs)
	for c in 0 ..< nch {
		bufs[c] = make([]f32, BLOCK)
		ptrs[c] = raw_data(bufs[c])
	}
	defer for c in 0 ..< nch {delete(bufs[c])}

	in_bufs := make([][]f32, 2)
	defer delete(in_bufs)
	in_ptrs := make([][^]f32, 2)
	defer delete(in_ptrs)
	for c in 0 ..< 2 {
		in_bufs[c] = make([]f32, BLOCK)
		in_ptrs[c] = raw_data(in_bufs[c])
	}
	defer for c in 0 ..< 2 {delete(in_bufs[c])}

	for _ in 0 ..< blocks {
		e.process_replacing(e, raw_data(in_ptrs), raw_data(ptrs), BLOCK)
	}
}
