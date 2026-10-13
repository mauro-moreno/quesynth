package s1probe

// s1probe arch - the architecture theories in
// docs/synth1-architecture-evidence.md, one subcommand per theory.
//
//   s1probe arch fxorder               effect unit against EQ and delay order
//   s1probe arch pan                   static, unison and LFO pan composition
//   s1probe arch lfocutoff             cutoff LFO depth against the base cutoff
//   s1probe arch lfophase              free-running against key-synced LFO
//   s1probe arch envshape              decay and release: linear or exponential
//   s1probe arch envlaw                finite envelope lengths and fade model
//   s1probe arch ramp                  a cutoff/pitch edit's transition time
//   s1probe arch clip                  output stage above full scale
//   s1probe arch rate                  modulation update grid
//   s1probe arch osc                   oscillator purity and aliasing
//   s1probe arch voices                polyphony and unison accounting
//   s1probe arch eq                    equaliser peak response
//   s1probe arch filtertype            parameter 14's five responses; --values cutoff,resonance
//   s1probe arch hits                  a short patch averaged over many hits; --what <patch.sy1> --values <hits>
//   s1probe arch tone                  the equaliser's tone, each state against stored 65; --values states
//
// Common options: --wav <dir> writes every render pair; --values <list>
// overrides a subcommand's sweep where it has one.
//
// Every subcommand renders the same patch and the same timed script through a
// freshly loaded reference and through this engine, and reads both with the
// same instrument. Where an instrument needs calibrating, each engine is
// calibrated against its own static sweep, so neither inherits the other's
// offsets. The numbers describe behaviour; what they say about the theories is
// in the evidence document, not here.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import sdsp "../../src/dsp"
import sengine "../../src/engine"
import cpatch "../../src/patch"

Arch_Options :: struct {
	wav:    string,
	values: [dynamic]int,
	what:   string,
	child:  bool,
	case_:  int,
}

Arch_Chunk :: struct {
	pristine: []byte,
	work:     []byte,
}

// ------------------------------------------------------------------ helpers

// Search only actual measured states. Searching arbitrary stored integers
// through the binding's fallback picks invalid stored 0 for destination 7
// and unison 8: the binding clamps it to the last state but the reference's
// chunk loader does not. A probe must send a state's own stored value.
arch_stored_for_display :: proc(index: int, display: string) -> int {
	for state, position in cpatch.parameter_states(index) {
		if state.display == display {
			stored, ok := cpatch.parameter_stored_at_position(index, position)
			if ok {return stored}
		}
	}
	return -1
}

arch_stored_for_id :: proc(index, id: int) -> int {
	return arch_stored_for_display(index, fmt.tprintf("%v", id))
}

arch_stored_for_number :: proc(index: int, value: f32) -> int {
	for _, position in cpatch.parameter_states(index) {
		stored, ok := cpatch.parameter_stored_at_position(index, position)
		if ok && abs(sengine.display_number(index, stored, -9999) - value) < 1.0e-4 {return stored}
	}
	return -1
}

// Parameter 61's stored integer nearest `hz`, and the frequency it displays.
arch_eq_stored_near :: proc(hz: f64) -> (stored: int, actual: f64) {
	best := 1.0e9
	for s in 0 ..< 128 {
		h := f64(sengine.display_frequency_hz(sengine.resolved_display(61, s)))
		if h <= 0 {continue}
		d := abs(math.log2(h / hz))
		if d < best {
			best = d
			stored = s
			actual = h
		}
	}
	return
}

arch_render :: proc(
	dll: string,
	p: ^cpatch.Patch,
	c: ^Arch_Chunk,
	events: []Script_Event,
	seconds: f64,
) -> (
	ref, ours: []f32,
) {
	ref = render_reference_script(dll, p, c.pristine, c.work, events, script_frame(seconds))
	ours = render_ours_script(p^, events, script_frame(seconds))
	return
}

ms_to_frame :: proc(ms: f64) -> int {
	return int(math.round(ms * f64(SAMPLE_RATE) / 1000.0))
}

// Welch power of x[from:to], Hann windowed, `n` points, hop n/2. The scale is
// arbitrary but common to every call with the same `n`, which is all a ratio
// needs. Length n/2+1; nil when the span is shorter than one frame.
arch_spectrum :: proc(x: []f32, from, to, n: int) -> []f64 {
	lo := max(from, 0)
	hi := min(to, len(x))
	if hi - lo < n {return nil}
	re := make([]f64, n)
	defer delete(re)
	im := make([]f64, n)
	defer delete(im)
	power := make([]f64, n / 2 + 1)
	frames := 0
	for start := lo; start + n <= hi; start += n / 2 {
		for i in 0 ..< n {
			w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(n)))
			re[i] = f64(x[start + i]) * w
			im[i] = 0
		}
		fft_forward(re, im)
		for k in 0 ..< len(power) {
			power[k] += re[k] * re[k] + im[k] * im[k]
		}
		frames += 1
	}
	for k in 0 ..< len(power) {
		power[k] /= f64(frames)
	}
	return power
}

// Power of the spectral line nearest `hz`: the sum over +/-3 bins, which holds
// a Hann window's whole main lobe wherever between two bins the line falls.
arch_line_power :: proc(power: []f64, bin_hz, hz: f64) -> f64 {
	centre := int(math.round(hz / bin_hz))
	sum := 0.0
	for k in centre - 3 ..= centre + 3 {
		if k >= 1 && k < len(power) {sum += power[k]}
	}
	return sum
}

// The transfer function from x to y over [from:to], |Sxy| / Sxx per bin. With
// identical input sequences -- both engines' noise is deterministic per render
// -- this is the section's exact magnitude response rather than an estimate.
arch_transfer :: proc(x, y: []f32, from, to, n: int) -> []f64 {
	lo := max(from, 0)
	hi := min(min(to, len(x)), len(y))
	if hi - lo < n {return nil}
	xr := make([]f64, n);defer delete(xr)
	xi := make([]f64, n);defer delete(xi)
	yr := make([]f64, n);defer delete(yr)
	yi := make([]f64, n);defer delete(yi)
	bins := n / 2 + 1
	sr := make([]f64, bins);defer delete(sr)
	si := make([]f64, bins);defer delete(si)
	sxx := make([]f64, bins);defer delete(sxx)
	for start := lo; start + n <= hi; start += n / 2 {
		for i in 0 ..< n {
			w := 0.5 * (1.0 - math.cos(2.0 * math.PI * f64(i) / f64(n)))
			xr[i] = f64(x[start + i]) * w
			yr[i] = f64(y[start + i]) * w
			xi[i] = 0
			yi[i] = 0
		}
		fft_forward(xr, xi)
		fft_forward(yr, yi)
		for k in 0 ..< bins {
			// Y * conj(X)
			sr[k] += yr[k] * xr[k] + yi[k] * xi[k]
			si[k] += yi[k] * xr[k] - yr[k] * xi[k]
			sxx[k] += xr[k] * xr[k] + xi[k] * xi[k]
		}
	}
	h := make([]f64, bins)
	for k in 0 ..< bins {
		h[k] = sxx[k] > 0 ? math.sqrt(sr[k] * sr[k] + si[k] * si[k]) / sxx[k] : 0
	}
	return h
}

// The transfer magnitude at `hz`, in dB, averaged in power over the bins within
// a twelfth of an octave so a single noisy bin cannot set it.
arch_transfer_db_at :: proc(h: []f64, bin_hz, hz: f64) -> f64 {
	lo := int(math.floor(hz * math.pow(f64(2.0), -1.0 / 24.0) / bin_hz))
	hi := int(math.ceil(hz * math.pow(f64(2.0), 1.0 / 24.0) / bin_hz))
	sum := 0.0
	count := 0
	for k in max(lo, 1) ..= min(hi, len(h) - 1) {
		sum += h[k] * h[k]
		count += 1
	}
	if count == 0 || sum <= 0 {return -200}
	return 10.0 * math.log10(sum / f64(count))
}

// Least squares y = slope*x + intercept, and the RMS residual.
arch_fit_line :: proc(xs, ys: []f64) -> (slope, intercept, rms: f64) {
	n := f64(len(xs))
	if len(xs) < 2 || len(ys) != len(xs) {return}
	mx, my := 0.0, 0.0
	for i in 0 ..< len(xs) {
		mx += xs[i]
		my += ys[i]
	}
	mx /= n
	my /= n
	sxy, sxx := 0.0, 0.0
	for i in 0 ..< len(xs) {
		sxy += (xs[i] - mx) * (ys[i] - my)
		sxx += (xs[i] - mx) * (xs[i] - mx)
	}
	if sxx <= 0 {return}
	slope = sxy / sxx
	intercept = my - slope * mx
	sum := 0.0
	for i in 0 ..< len(xs) {
		r := ys[i] - (slope * xs[i] + intercept)
		sum += r * r
	}
	rms = math.sqrt(sum / n)
	return
}

// RMS level of x in frames of `frame` samples, in dB. -200 for silence.
arch_frame_db :: proc(x: []f32, frame: int) -> []f64 {
	count := len(x) / frame
	out := make([]f64, count)
	for f in 0 ..< count {
		out[f] = window_db(x, f * frame, (f + 1) * frame)
	}
	return out
}

// ------------------------------------------------------------------ envshape

// The shape of a falling segment.
//
// A decay that is exponential falls in a straight line in decibels; one that
// is linear in amplitude falls ever faster in decibels and in a straight line
// in amplitude. So the segment is fitted both ways over the same span and both
// residuals are reported, together with the dB slope over the first and last
// thirds, whose ratio is 1 for an exponential and grows without bound for a
// linear ramp. Nothing is decided here; the numbers are printed.
Decay_Shape :: struct {
	ok:            bool,
	span_ms:       f64,
	early_db_ms:   f64,
	late_db_ms:    f64,
	// late / early: 1 for an exponential, several for a linear ramp.
	ratio:         f64,
	// RMS residual of the best straight line in dB, in dB.
	db_line_rms:   f64,
	// RMS residual of the best straight line in amplitude, as a fraction of
	// the amplitude at the start of the span.
	amp_line_rms:  f64,
}

// `db` is a frame series, `start` the frame the segment begins at. The span
// runs from the first frame `from_db` under the start level to the first frame
// `to_db` under it.
decay_shape :: proc(db: []f64, start: int, frame_ms, from_db, to_db: f64) -> Decay_Shape {
	s: Decay_Shape
	if start < 0 || start >= len(db) {return s}
	// The segment starts at its peak, not at `start`: the frame a note begins
	// in holds only part of a cycle, and counting it as the top would put the
	// span's first point on the onset rather than on the segment.
	peak := start
	for k in start ..< min(start + 4, len(db)) {
		if db[k] > db[peak] {peak = k}
	}
	top := db[peak]
	first, last := -1, -1
	for k in peak ..< len(db) {
		if first < 0 && db[k] <= top - from_db {first = k}
		if db[k] <= top - to_db {
			last = k
			break
		}
	}
	if first < 0 || last < 0 || last - first < 9 {return s}
	n := last - first + 1
	xs := make([]f64, n);defer delete(xs)
	ys := make([]f64, n);defer delete(ys)
	amps := make([]f64, n);defer delete(amps)
	for i in 0 ..< n {
		xs[i] = f64(i) * frame_ms
		ys[i] = db[first + i]
		amps[i] = math.pow(10.0, db[first + i] / 20.0)
	}
	_, _, s.db_line_rms = arch_fit_line(xs, ys)
	_, _, amp_rms := arch_fit_line(xs, amps)
	s.amp_line_rms = amps[0] > 0 ? amp_rms / amps[0] : 0
	third := n / 3
	early, _, _ := arch_fit_line(xs[:third], ys[:third])
	late, _, _ := arch_fit_line(xs[n - third:], ys[n - third:])
	s.early_db_ms = early
	s.late_db_ms = late
	s.ratio = early != 0 ? late / early : 0
	s.span_ms = f64(n - 1) * frame_ms
	s.ok = true
	return s
}

// ------------------------------------------------------------------ rate

// Where a gain sequence changes its law: a control-rate grid.
//
// A gain computed every sample from a smooth law has a smooth second
// difference. One updated every N samples and held has a first difference that
// is zero except every N samples; one updated every N samples and ramped
// linearly between updates has a second difference that is zero except every N
// samples. Either way the second difference carries isolated spikes on an N
// grid. A spike is a value more than `factor` times the median magnitude.
Grid_Reading :: struct {
	samples:       int,
	spikes:        int,
	// The most common spacing between consecutive spikes, and the share of
	// spacings that are a whole multiple of it.
	spacing:       int,
	on_grid:       f64,
	// Where the grid sits: spike index modulo the spacing, most common value.
	phase:         int,
	// Share of first differences that are exactly zero: a held (staircase)
	// gain reads close to 1 - 1/N, a ramped or per-sample one close to 0.
	zero_d1:       f64,
}

// `g` is the gain sequence and `valid` marks samples where it is defined; a
// difference is only taken across consecutive valid samples.
grid_reading :: proc(g: []f64, valid: []bool, factor: f64) -> Grid_Reading {
	r: Grid_Reading
	n := len(g)
	if n < 4 || len(valid) != n {return r}
	d2 := make([dynamic]f64);defer delete(d2)
	at := make([dynamic]int);defer delete(at)
	zero := 0
	d1_count := 0
	for i in 2 ..< n {
		if !(valid[i] && valid[i - 1] && valid[i - 2]) {continue}
		a := g[i] - g[i - 1]
		b := g[i - 1] - g[i - 2]
		if a == 0 {zero += 1}
		d1_count += 1
		append(&d2, abs(a - b))
		append(&at, i)
	}
	r.samples = len(d2)
	if r.samples < 8 {return r}
	r.zero_d1 = f64(zero) / f64(max(d1_count, 1))
	sorted := slice.clone(d2[:]);defer delete(sorted)
	slice.sort(sorted)
	med := sorted[len(sorted) / 2]
	top := sorted[len(sorted) - 1]
	threshold := max(med * factor, top * 1.0e-3)
	if top <= 0 {return r}
	spikes := make([dynamic]int);defer delete(spikes)
	for v, k in d2 {
		if v > threshold {
			// A spike at a held step shows twice in the second difference,
			// once rising into the step and once out of it; keep the first.
			if len(spikes) > 0 && at[k] - spikes[len(spikes) - 1] <= 1 {continue}
			append(&spikes, at[k])
		}
	}
	r.spikes = len(spikes)
	if r.spikes < 3 {return r}
	counts := make(map[int]int);defer delete(counts)
	for k in 1 ..< len(spikes) {
		counts[spikes[k] - spikes[k - 1]] += 1
	}
	best := 0
	for spacing, c in counts {
		if c > best || (c == best && spacing < r.spacing) {
			best = c
			r.spacing = spacing
		}
	}
	if r.spacing <= 0 {return r}
	multiple := 0
	for k in 1 ..< len(spikes) {
		if (spikes[k] - spikes[k - 1]) % r.spacing == 0 {multiple += 1}
	}
	r.on_grid = f64(multiple) / f64(len(spikes) - 1)
	phases := make(map[int]int);defer delete(phases)
	for s in spikes {phases[s % r.spacing] += 1}
	best = 0
	for ph, c in phases {
		if c > best {
			best = c
			r.phase = ph
		}
	}
	return r
}

// ------------------------------------------------------------------ pan

// The single-control law, the reference's, measured (null-test.md): full level
// at the centre, the channel panned away from attenuated linearly,
// min(1, 1 -/+ pan).
pan_law :: proc(pan: f64) -> (l, r: f64) {
	p := clamp(pan, -1, 1)
	return min(1.0, 1.0 - p), min(1.0, 1.0 + p)
}

// Additive: the controls' positions add, then one law applies. A position is
// only defined for a control whose own gains lie on the law (see
// `pan_on_law`); the LFO's do not on the reference, which raises the near
// channel above 1.
pan_additive :: proc(positions: []f64) -> (l, r: f64) {
	sum := 0.0
	for p in positions {sum += p}
	return pan_law(sum)
}

// Multiplicative: each control applies its own gains and they multiply. The
// prediction takes each control's gains as measured alone, through the same
// engine and instrument, so it assumes no law for any control and inherits no
// calibration from the other engine.
pan_product :: proc(gains: [][2]f64) -> (l, r: f64) {
	l, r = 1, 1
	for g in gains {
		l *= g[0]
		r *= g[1]
	}
	return
}

// A position read back from a pair of gains under the single-control law:
// for pan >= 0 the left gain is 1 - pan and the right is 1, and the other way
// round below, so right minus left is the position on either side.
pan_position :: proc(l, r: f64) -> f64 {
	return r - l
}

// Whether a pair of gains is one the single-control law can produce: the
// louder channel at unity and the quieter at or under it.
pan_on_law :: proc(l, r: f64, tolerance := 0.02) -> bool {
	return abs(max(l, r) - 1.0) <= tolerance && min(l, r) <= 1.0 + tolerance
}

// ------------------------------------------------------------------ ramp

// A stepped series, normalised: 0 at the settled level before the step, 1 at
// the settled level at the end. `at` is the event's index; the level before is
// the mean over [at - guard - before, at - guard), so a measurement window that
// straddles the event cannot leak into it, and the level after is the mean of
// the last `after` points.
Step :: struct {
	a, b: f64,
	ok:   bool,
}

step_levels :: proc(series: []f64, at, guard, before, after: int) -> Step {
	s: Step
	if at - guard - before < 0 || len(series) - after <= at || after <= 0 || before <= 0 {return s}
	for k in at - guard - before ..< at - guard {s.a += series[k]}
	s.a /= f64(before)
	for k in len(series) - after ..< len(series) {s.b += series[k]}
	s.b /= f64(after)
	s.ok = abs(s.b - s.a) > 1.0e-9
	return s
}

step_progress :: proc(s: Step, v: f64) -> f64 {
	return (v - s.a) / (s.b - s.a)
}

// Where the normalised step first rises through `threshold`, in index units
// after `at`, interpolated between the two samples that bracket it. Only a
// real crossing counts -- the sample before is under the threshold and the
// one after is at or over it -- searched from the guard onwards, so a series
// that never crosses (or starts past the threshold) is reported unmeasurable
// rather than given a time computed from a vanishing difference.
step_crossing :: proc(series: []f64, s: Step, at, guard: int, threshold: f64) -> (t: f64, ok: bool) {
	if !s.ok {return 0, false}
	for k in max(at - guard, 1) ..< len(series) {
		prev := step_progress(s, series[k - 1])
		u := step_progress(s, series[k])
		if prev < threshold && u >= threshold {
			return f64(k - 1 - at) + (threshold - prev) / (u - prev), true
		}
	}
	return 0, false
}

// ------------------------------------------------------------------ lfophase

// The frames at which a falling saw jumps back up: a rise of more than half
// the series' range from one frame to the next.
saw_jumps :: proc(env: []f64, from, to: int) -> [dynamic]int {
	jumps: [dynamic]int
	lo := max(from, 1)
	hi := min(to, len(env))
	top := 0.0
	for k in lo ..< hi {top = max(top, env[k])}
	for k in lo ..< hi {
		if env[k] - env[k - 1] > 0.5 * top {append(&jumps, k)}
	}
	return jumps
}

// The LFO phase at a note's onset, in turns, from the first jump after it: a
// falling saw starts each cycle at its top, so a jump `d` frames after onset
// means the onset was `1 - d/period` of the way through a cycle.
onset_phase :: proc(onset, first_jump: int, period: f64) -> f64 {
	if period <= 0 {return -1}
	ph := 1.0 - f64(first_jump - onset) / period
	ph -= math.floor(ph)
	return ph
}

// ------------------------------------------------------------------ lfocutoff

// Sixth-octave band levels in dB of a power spectrum, 40 Hz to 15 kHz.
ARCH_BAND_LO :: 40.0
ARCH_BAND_HI :: 15000.0

arch_band_db :: proc(power: []f64, bin_hz: f64) -> []f64 {
	out: [dynamic]f64
	for lo := ARCH_BAND_LO; lo < ARCH_BAND_HI; lo *= math.pow(f64(2.0), 1.0 / 6.0) {
		hi := lo * math.pow(f64(2.0), 1.0 / 6.0)
		sum := 0.0
		count := 0
		for k in max(int(math.ceil(lo / bin_hz)), 1) ..< min(int(math.ceil(hi / bin_hz)), len(power)) {
			sum += power[k]
			count += 1
		}
		append(&out, count > 0 && sum > 0 ? 10.0 * math.log10(sum / f64(count)) : -200)
	}
	return out[:]
}

// The calibrated state whose band profile is nearest `profile`, refined
// between grid points by a parabola through the three nearest distances.
// `states` must ascend. The distance is the mean squared dB difference over
// bands where both profiles are above the floor.
match_state :: proc(profile: []f64, states: []f64, profiles: [][]f64) -> (state, distance: f64) {
	if len(states) == 0 {return -1, 0}
	dist := make([]f64, len(states));defer delete(dist)
	best := 0
	for s in 0 ..< len(states) {
		sum := 0.0
		count := 0
		for b in 0 ..< min(len(profile), len(profiles[s])) {
			if profile[b] < -150 || profiles[s][b] < -150 {continue}
			d := profile[b] - profiles[s][b]
			sum += d * d
			count += 1
		}
		dist[s] = count > 0 ? sum / f64(count) : 1.0e12
		if dist[s] < dist[best] {best = s}
	}
	state = states[best]
	distance = dist[best]
	if best > 0 && best < len(states) - 1 {
		a, b, c := dist[best - 1], dist[best], dist[best + 1]
		den := a - 2.0 * b + c
		if den > 0 {
			off := clamp(0.5 * (a - c) / den, -1, 1)
			step := off >= 0 ? states[best + 1] - states[best] : states[best] - states[best - 1]
			state += off * step
		}
	}
	return
}

// The cutoff axis's frequency at a fractional state.
cutoff_hz_at :: proc(state: f64) -> f64 {
	s := clamp(state, 0, f64(sengine.FILTER_TABLE_SIZE - 1))
	return f64(sengine.filter_index_hz(f32(s) * sengine.FILTER_INDEX_MAX / f32(sengine.FILTER_TABLE_SIZE - 1)))
}

// ================================================================== commands

// A sine through an open filter, phase fixed so a render is a function of the
// patch. Every probe below starts here and changes only what it measures.
arch_sine_patch :: proc() -> cpatch.Patch {
	p := neutral_probe_patch()
	set_param(&p, 0, 0) // oscillator 1 sine
	set_param(&p, 5, 0) // oscillator 1 alone
	set_param(&p, 19, 127)
	set_param(&p, 29, 110)
	set_param(&p, 91, 1)
	set_param(&p, 60, 64) // equaliser tone flat
	set_param(&p, 61, 64)
	set_param(&p, 62, 64) // equaliser level 0.0 dB
	set_param(&p, 63, 64)
	return p
}

// Oscillator 2's noise alone through the filter; the source every transfer
// measurement here divides out.
arch_noise_patch :: proc() -> cpatch.Patch {
	p := arch_sine_patch()
	set_param(&p, 1, 4) // oscillator 2 noise
	set_param(&p, 5, 127)
	return p
}

note_hz :: proc(note: f64) -> f64 {
	return 440.0 * math.pow(2.0, (note - 69.0) / 12.0)
}

// Line levels in dB of the first `count` harmonics of f0 over x[from:to].
arch_harmonics :: proc(x: []f32, from, to: int, f0: f64, n := 16384) -> (h: [8]f64) {
	power := arch_spectrum(x, from, to, n)
	defer delete(power)
	if power == nil {return}
	bin_hz := f64(SAMPLE_RATE) / f64(n)
	for k in 0 ..< len(h) {
		h[k] = power_db(arch_line_power(power, bin_hz, f0 * f64(k + 1)))
	}
	return
}

arch_free_pair :: proc(ref, ours: []f32) {
	delete(ref)
	delete(ours)
}

// ------------------------------------------------------------------ fxorder

fxorder_patch :: proc(effect: bool, eq_freq, eq_level: int) -> cpatch.Patch {
	p := arch_sine_patch()
	set_param(&p, 29, 127) // amp gain at maximum, as fxprobe drives the unit
	set_param(&p, 61, eq_freq)
	set_param(&p, 62, eq_level)
	set_param(&p, 77, effect ? 1 : 0)
	set_param(&p, 78, arch_stored_for_id(78, 1)) // a.d.2, a memoryless tanh
	set_param(&p, 79, 64)
	set_param(&p, 80, 64)
	set_param(&p, 81, 127)
	return p
}

cmd_arch_fxorder :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	f0 := note_hz(48)
	eq_f0, hz_f0 := arch_eq_stored_near(f0)
	eq_f3, hz_f3 := arch_eq_stored_near(3 * f0)
	boost := 127
	fmt.println("arch fxorder: sine note 48 into effect a.d.2 (ctl1 64, ctl2 64, level 127), amp gain 127")
	fmt.printfln("  EQ at f0: stored %v (%q, %v Hz); EQ at 3 f0: stored %v (%q, %v Hz); level stored %v (%q)",
		eq_f0, sengine.resolved_display(61, eq_f0), dec1(hz_f0), eq_f3, sengine.resolved_display(61, eq_f3), dec1(hz_f3),
		boost, sengine.resolved_display(62, boost))
	fmt.println("  H1/H3: arbitrary but common spectral-power dB scale, mid channel, 0.3-1.4 s")
	fmt.println()

	Fx_Case :: struct {
		label:  string,
		effect: bool,
		freq:   int,
		level:  int,
		note:   int,
	}
	cases := []Fx_Case {
		{"A  effect, EQ flat", true, eq_f0, 64, 48},
		{"B  effect, EQ +f0", true, eq_f0, boost, 48},
		{"C  effect, EQ +3f0", true, eq_f3, boost, 48},
		{"A0 no effect, flat", false, eq_f0, 64, 48},
		{"B0 no effect, EQ +f0", false, eq_f0, boost, 48},
		{"A1 no effect, flat, note 67", false, eq_f3, 64, 67},
		{"C1 no effect, EQ +3f0, note 67", false, eq_f3, boost, 67},
		{"B1 no effect, EQ +f0, note 67", false, eq_f0, boost, 67},
		{"C0 no effect, EQ +3f0", false, eq_f3, boost, 48},
	}
	h1: [2][9]f64
	h3: [2][9]f64
	fmt.printfln("  %-32v | %8v %8v %8v | %8v %8v %8v", "case", "ref H1", "ref H3", "H3-H1", "our H1", "our H3", "H3-H1")
	for cs, i in cases {
		p := fxorder_patch(cs.effect, cs.freq, cs.level)
		ev := []Script_Event{script_on(0, cs.note), script_off(1.5, cs.note)}
		ref, ours := arch_render(dll, &p, c, ev, 1.6)
		write_pair(o.wav, fmt.tprintf("fxorder-%v", i), ref, ours)
		for audio, side in ([2][]f32{ref, ours}) {
			x := script_channel(audio, -1)
			h := arch_harmonics(x, ms_to_frame(300), ms_to_frame(1400), note_hz(f64(cs.note)))
			h1[side][i] = h[0]
			h3[side][i] = h[2]
			delete(x)
		}
		arch_free_pair(ref, ours)
		fmt.printfln("  %-32v | %v %v %v | %v %v %v", cs.label,
			dec1(h1[0][i], 8), dec1(h3[0][i], 8), sdec1(h3[0][i] - h1[0][i], 8),
			dec1(h1[1][i], 8), dec1(h3[1][i], 8), sdec1(h3[1][i] - h1[1][i], 8))
		free_all(context.temp_allocator)
	}
	fmt.println()
	for side in 0 ..< 2 {
		fmt.printfln("  %v", side == 0 ? "reference" : "this engine")
		gain_f0 := h1[side][4] - h1[side][3]
		gain_f3 := h1[side][6] - h1[side][5]
		fmt.printfln("    EQ gain, linear path: at f0 %v dB, at 3 f0 %v dB", sdec2(gain_f0), sdec2(gain_f3))
		fmt.printfln("    B-A: H1 %v, H3 %v dB; independent EQ-after prediction %v, %v dB",
			sdec2(h1[side][1] - h1[side][0]), sdec2(h3[side][1] - h3[side][0]),
			sdec2(gain_f0), sdec2(h1[side][7] - h1[side][5]))
		fmt.printfln("    C-A: H1 %v, H3 %v dB; independent EQ-after prediction %v, %v dB",
			sdec2(h1[side][2] - h1[side][0]), sdec2(h3[side][2] - h3[side][0]),
			sdec2(h1[side][8] - h1[side][3]), sdec2(gain_f3))
	}

	// The effect unit against the delay. A distortion before the delay puts a
	// linear copy of its output in the echo, so the echo carries the dry hit's
	// harmonic balance at a lower level. After the delay it would distort the
	// quieter echo less, and the balance would move.
	fmt.println()
	fmt.println("  effect against delay: note 48 held 0.2 s, delay \"(8)\" (250 ms), feedback 0, dry/wet 32, tone 64")
	fmt.printfln("  %-14v | %9v %9v %9v | %9v %9v %9v", "case", "ref dry", "ref echo", "echo H1", "our dry", "our echo", "echo H1")
	fmt.printfln("  %-14v | %9v %9v %9v | %9v %9v %9v", "", "H3-H1", "H3-H1", "-dry H1", "H3-H1", "H3-H1", "-dry H1")
	eighth := arch_stored_for_display(35, "(8)")
	for effect in ([2]bool{true, false}) {
		p := fxorder_patch(effect, eq_f0, 64)
		set_param(&p, 65, 1)
		set_param(&p, 35, eighth)
		set_param(&p, 36, 0)
		set_param(&p, 37, 32)
		set_param(&p, 82, 0)
		set_param(&p, 98, 64)
		ev := []Script_Event{script_on(0, 48), script_off(0.2, 48)}
		ref, ours := arch_render(dll, &p, c, ev, 0.6)
		write_pair(o.wav, fmt.tprintf("fxdelay-%v", effect ? "on" : "off"), ref, ours)
		cells: [2][3]f64
		for audio, side in ([2][]f32{ref, ours}) {
			x := script_channel(audio, -1)
			dry := arch_harmonics(x, ms_to_frame(30), ms_to_frame(190), f0, 4096)
			echo := arch_harmonics(x, ms_to_frame(285), ms_to_frame(445), f0, 4096)
			cells[side] = {dry[2] - dry[0], echo[2] - echo[0], echo[0] - dry[0]}
			delete(x)
		}
		arch_free_pair(ref, ours)
		fmt.printfln("  %-14v | %v %v %v | %v %v %v", effect ? "effect on" : "effect off",
			sdec1(cells[0][0], 9), sdec1(cells[0][1], 9), sdec1(cells[0][2], 9),
			sdec1(cells[1][0], 9), sdec1(cells[1][1], 9), sdec1(cells[1][2], 9))
	}
}

// ------------------------------------------------------------------ pan

Pan_Config :: struct {
	label:  string,
	spread: int, // parameter 84; 64 is no spread
	pan:    int, // parameter 90; 64 is centre
	depth:  int, // LFO 1 depth on pan; 0 is off
}

pan_patch :: proc(cfg: Pan_Config) -> cpatch.Patch {
	p := arch_sine_patch()
	set_param(&p, 90, cfg.pan)
	// Two unison layers, not detuned, the alternating one an octave up: each
	// layer is its own spectral line, so its gains can be read separately.
	set_param(&p, 73, 1)
	set_param(&p, 93, arch_stored_for_display(93, "2"))
	set_param(&p, 75, 0)
	set_param(&p, 85, arch_stored_for_number(85, 12))
	set_param(&p, 92, 0)
	set_param(&p, 84, cfg.spread)
	if cfg.depth > 0 {
		set_param(&p, 57, 1)
		set_param(&p, 41, arch_stored_for_id(41, 7)) // pan
		set_param(&p, 42, LFO_PITCH_SHAPE_SQUARE)
		set_param(&p, 43, 44) // about 0.95 Hz: a half cycle of 526 ms
		set_param(&p, 44, cfg.depth)
		set_param(&p, 68, 1)
		set_param(&p, 67, 0)
	}
	return p
}

PAN_FFT :: 4096

// Per line, per LFO half: (left, right) gain against the control's level.
Pan_Reading :: struct {
	gain: [2][2][2]f64, // [half][line][channel]
}

pan_read :: proc(audio: []f32, lines: [2]f64, control: [2]f64) -> Pan_Reading {
	r: Pan_Reading
	left := script_channel(audio, 0)
	defer delete(left)
	right := script_channel(audio, 1)
	defer delete(right)
	bin_hz := f64(SAMPLE_RATE) / f64(PAN_FFT)
	Window :: struct {
		pos: f64,
		g:   [2][2]f64,
	}
	windows: [dynamic]Window
	defer delete(windows)
	for from := ms_to_frame(200); from + PAN_FFT <= len(left) - ms_to_frame(150); from += PAN_FFT / 4 {
		w: Window
		for ch in 0 ..< 2 {
			power := arch_spectrum(ch == 0 ? left : right, from, from + PAN_FFT, PAN_FFT)
			for line in 0 ..< 2 {
				w.g[line][ch] = math.sqrt(arch_line_power(power, bin_hz, lines[line])) / control[line]
			}
			delete(power)
		}
		w.pos = w.g[0][1] - w.g[0][0]
		append(&windows, w)
	}
	// A square LFO holds two positions; the windows in the lowest and highest
	// 30% by position are inside one half each. A static setting has one
	// position and both halves read the same.
	slice.sort_by(windows[:], proc(a, b: Window) -> bool {return a.pos < b.pos})
	n := len(windows) * 3 / 10
	for half in 0 ..< 2 {
		for k in 0 ..< n {
			w := windows[half == 0 ? k : len(windows) - 1 - k]
			for line in 0 ..< 2 {
				for ch in 0 ..< 2 {
					r.gain[half][line][ch] += w.g[line][ch] / f64(n)
				}
			}
		}
	}
	return r
}

cmd_arch_pan :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	lines := [2]f64{note_hz(60), note_hz(72)}
	ev := []Script_Event{script_on(0, 60), script_off(4.0, 60)}
	fmt.println("arch pan: sine note 60, unison 2 (detune 0, unison pitch +12), so each layer is one line")
	fmt.println("  gains are each line's channel level against the same line at spread 64, pan 64, no LFO")
	fmt.println("  LFO: square on pan, rate 44, key sync; halves are the lowest and highest 30% of windows by position")
	fmt.println()

	control_cfg := Pan_Config{"control", 64, 64, 0}
	cp := pan_patch(control_cfg)
	cref, cours := arch_render(dll, &cp, c, ev, 4.2)
	control: [2][2]f64
	for audio, side in ([2][]f32{cref, cours}) {
		x := script_channel(audio, 0)
		power := arch_spectrum(x, ms_to_frame(200), len(x) - ms_to_frame(150), PAN_FFT)
		bin_hz := f64(SAMPLE_RATE) / f64(PAN_FFT)
		for line in 0 ..< 2 {
			control[side][line] = math.sqrt(arch_line_power(power, bin_hz, lines[line]))
		}
		delete(power)
		delete(x)
	}
	arch_free_pair(cref, cours)

	configs := []Pan_Config {
		{"spread 96", 96, 64, 0},
		{"spread 127", 127, 64, 0},
		{"pan 32", 64, 32, 0},
		{"pan 0", 64, 0, 0},
		{"pan 96", 64, 96, 0},
		{"spread 96 + pan 32", 96, 32, 0},
		{"spread 96 + pan 96", 96, 96, 0},
		{"spread 127 + pan 0", 127, 0, 0},
		{"spread 127 + pan 32", 127, 32, 0},
		{"LFO 32", 64, 64, 32},
		{"LFO 127", 64, 64, 127},
		{"LFO 32 + pan 32", 64, 32, 32},
		{"LFO 127 + pan 32", 64, 32, 127},
		{"LFO 32 + spread 96", 96, 64, 32},
		{"LFO 127 + spread 96", 96, 64, 127},
	}
	readings: [2][dynamic]Pan_Reading
	defer for r in readings {delete(r)}
	for cfg, i in configs {
		p := pan_patch(cfg)
		ref, ours := arch_render(dll, &p, c, ev, 4.2)
		write_pair(o.wav, fmt.tprintf("pan-%v", i), ref, ours)
		append(&readings[0], pan_read(ref, lines, control[0]))
		append(&readings[1], pan_read(ours, lines, control[1]))
		arch_free_pair(ref, ours)
		free_all(context.temp_allocator)
	}
	find :: proc(configs: []Pan_Config, label: string) -> int {
		for cfg, i in configs {if cfg.label == label {return i}}
		return -1
	}

	for side in 0 ..< 2 {
		fmt.printfln("  %v", side == 0 ? "reference" : "this engine")
		fmt.printfln("    %-22v %4v %4v | %13v | %13v | %13v", "config", "half", "line", "measured L R", "additive L R", "product L R")
		r := readings[side][:]
		// [static only, with the LFO][additive, product]: squared error, cells.
		err: [2][2]f64
		count: [2][2]int
		for cfg, i in configs {
			halves := cfg.depth > 0 ? 2 : 1
			for half in 0 ..< halves {
				for line in 0 ..< 2 {
					g := r[i].gain[half][line]
					// Each composed control's gains, as measured alone.
					parts: [dynamic][2]f64
					defer delete(parts)
					if cfg.spread != 64 && (cfg.pan != 64 || cfg.depth > 0) {
						append(&parts, r[find(configs, fmt.tprintf("spread %v", cfg.spread))].gain[0][line])
					}
					if cfg.pan != 64 && (cfg.spread != 64 || cfg.depth > 0) {
						append(&parts, r[find(configs, fmt.tprintf("pan %v", cfg.pan))].gain[0][line])
					}
					if cfg.depth > 0 && (cfg.spread != 64 || cfg.pan != 64) {
						append(&parts, r[find(configs, fmt.tprintf("LFO %v", cfg.depth))].gain[half][0])
					}
					cell :: proc(l, r: f64) -> string {return fmt.tprintf("%v %v", dec3(l, 6), dec3(r, 6))}
					if len(parts) < 2 {
						fmt.printfln("    %-22v %4v %4v | %v | %13v | %13v", cfg.label, half, line, cell(g[0], g[1]),
							fmt.tprintf("pos %v", sdec3(pan_position(g[0], g[1]))),
							pan_on_law(g[0], g[1]) ? "on law" : "OFF law")
						continue
					}
					group := cfg.depth > 0 ? 1 : 0
					on_law := true
					positions: [dynamic]f64
					defer delete(positions)
					for pg in parts {
						on_law &&= pan_on_law(pg[0], pg[1])
						append(&positions, pan_position(pg[0], pg[1]))
					}
					ml, mr := pan_product(parts[:])
					err[group][1] += (ml - g[0]) * (ml - g[0]) + (mr - g[1]) * (mr - g[1])
					count[group][1] += 2
					add_cell := fmt.tprintf("%13v", "undefined")
					if on_law {
						al, ar := pan_additive(positions[:])
						err[group][0] += (al - g[0]) * (al - g[0]) + (ar - g[1]) * (ar - g[1])
						count[group][0] += 2
						add_cell = cell(al, ar)
					}
					fmt.printfln("    %-22v %4v %4v | %v | %v | %v", cfg.label, half, line, cell(g[0], g[1]), add_cell, cell(ml, mr))
				}
			}
		}
		rms :: proc(e: f64, n: int) -> string {return n > 0 ? fmt.tprintf("%v (%v gains)", dec4(math.sqrt(e / f64(n))), n) : "undefined"}
		fmt.printfln("    RMS gain error, static controls only: additive %v, product %v", rms(err[0][0], count[0][0]), rms(err[0][1], count[0][1]))
		fmt.printfln("    RMS gain error, with the LFO:         additive %v, product %v", rms(err[1][0], count[1][0]), rms(err[1][1], count[1][1]))
	}
}

// ------------------------------------------------------------------ lfocutoff

lfocutoff_patch :: proc(base, depth: int) -> cpatch.Patch {
	p := arch_noise_patch()
	set_param(&p, 14, arch_stored_for_id(14, 0)) // 12 dB low pass
	set_param(&p, 19, base)
	set_param(&p, 20, 0)
	if depth > 0 {
		set_param(&p, 57, 1)
		set_param(&p, 41, arch_stored_for_id(41, 3)) // cutoff
		set_param(&p, 42, LFO_PITCH_SHAPE_SQUARE)
		set_param(&p, 43, 8) // 0.12 Hz: half cycles of 4.1 s
		set_param(&p, 44, depth)
		set_param(&p, 68, 1)
		set_param(&p, 67, 0)
	}
	return p
}

cmd_arch_lfocutoff :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	N :: 16384
	bin_hz := f64(SAMPLE_RATE) / f64(N)
	fmt.println("arch lfocutoff: noise through the 12 dB low pass, resonance 0, square LFO on cutoff, rate 8, key sync")
	fmt.println("  each half of the square is matched to the same engine's static cutoff sweep (states 16..127 step 2)")
	fmt.println()

	states: [dynamic]f64
	defer delete(states)
	cal: [2][dynamic][]f64
	defer for side in 0 ..< 2 {
		for prof in cal[side] {delete(prof)}
		delete(cal[side])
	}
	cal_ev := []Script_Event{script_on(0, 60), script_off(3.6, 60)}
	for s := 16; s <= 127; s += 2 {
		p := lfocutoff_patch(s, 0)
		ref, ours := arch_render(dll, &p, c, cal_ev, 3.7)
		for audio, side in ([2][]f32{ref, ours}) {
			x := script_channel(audio, -1)
			power := arch_spectrum(x, ms_to_frame(500), ms_to_frame(3500), N)
			append(&cal[side], arch_band_db(power, bin_hz))
			delete(power)
			delete(x)
		}
		append(&states, f64(s))
		arch_free_pair(ref, ours)
		if s == 126 {s = 125} // so 127 is calibrated too
		free_all(context.temp_allocator)
	}

	bases := []int{32, 56, 72, 88}
	depths := o.values[:]
	if len(depths) == 0 {depths = []int{16, 32, 48}}
	ev := []Script_Event{script_on(0, 60), script_off(8.5, 60)}
	fmt.printfln("  %4v %5v | %22v | %22v | %v", "base", "depth", "ref lo hi d-states d-oct", "our lo hi d-states d-oct",
		"predicted d-oct: fixed 5.06*d/127 | remaining states d/127*(127-b) as oct | remaining oct")
	for base in bases {
		for depth in depths {
			p := lfocutoff_patch(base, depth)
			ref, ours := arch_render(dll, &p, c, ev, 8.6)
			write_pair(o.wav, fmt.tprintf("lfocutoff-b%v-d%v", base, depth), ref, ours)
			cells: [2]string
			for audio, side in ([2][]f32{ref, ours}) {
				x := script_channel(audio, -1)
				m: [2]f64
				d: [2]f64
				for half in 0 ..< 2 {
					// Short interior windows: the measured rate varies with shape.
					// The old 4.8-7.8 s window straddled the reference's next edge.
					from := half == 0 ? ms_to_frame(1000) : ms_to_frame(5000)
					power := arch_spectrum(x, from, from + ms_to_frame(1000), N)
					prof := arch_band_db(power, bin_hz)
					m[half], d[half] = match_state(prof, states[:], cal[side][:])
					delete(prof)
					delete(power)
				}
				lo, hi := min(m[0], m[1]), max(m[0], m[1])
				cells[side] = fmt.tprintf("%v %v %v %v fit %v/%v dB", dec1(lo, 5), dec1(hi, 5), sdec1(hi - lo, 6), sdec2(math.log2(cutoff_hz_at(hi) / cutoff_hz_at(lo)), 5), dec2(math.sqrt(d[0])), dec2(math.sqrt(d[1])))
				delete(x)
			}
			arch_free_pair(ref, ours)
			fixed := 5.06 * f64(depth) / 127.0
			remaining_states := f64(depth) / 127.0 * f64(127 - base)
			remaining_states_oct := math.log2(cutoff_hz_at(f64(base) + remaining_states) / cutoff_hz_at(f64(base)))
			remaining_oct := f64(depth) / 127.0 * math.log2(cutoff_hz_at(127) / cutoff_hz_at(f64(base)))
			fmt.printfln("  %v %v | %v | %v | %v | %v | %v", pad_left(fmt.tprint(base), 4), pad_left(fmt.tprint(depth), 5),
				cells[0], cells[1], dec2(fixed, 5), dec2(remaining_states_oct, 5), dec2(remaining_oct, 5))
			free_all(context.temp_allocator)
		}
	}
}

// ------------------------------------------------------------------ lfophase

cmd_arch_lfophase :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	// The rate nearest 2.5 Hz, read off the measured table.
	rate := 0
	best := 1.0e9
	for s in 0 ..< 128 {
		hz := f64(sengine.lfo_rate_hz(sengine.resolved_position(43, s)))
		if abs(hz - 2.5) < best {
			best = abs(hz - 2.5)
			rate = s
		}
	}
	table_hz := f64(sengine.lfo_rate_hz(sengine.resolved_position(43, rate)))
	period := f64(SAMPLE_RATE) / table_hz
	FRAME :: 96
	fmt.println("arch lfophase: mono, sine note 84, LFO 1 saw on volume at depth 127; the saw's jump marks its cycle")
	fmt.printfln("  rate stored %v (%v Hz from the table, period %v ms)", rate, dec3(table_hz), dec1(period * 1000 / f64(SAMPLE_RATE)))
	fmt.println("  phase = LFO phase at note-on in turns, from the first jump after it and the measured jump spacing")
	fmt.println()
	Scenario :: struct {
		a, b: f64,
	}
	quarter := period / f64(SAMPLE_RATE) / 4
	scenarios := []Scenario{{0.0, 1.2}, {0.0, 1.2 + quarter}, {0.3, 1.2}, {0.3, 1.2 + quarter}}
	fmt.printfln("  %-5v %-14v | %-26v | %-26v | %v", "sync", "on A, on B (s)", "ref phase A, B, B-A", "our phase A, B, B-A", "free-running B-A")
	for sync in 0 ..< 2 {
		for sc in scenarios {
			p := arch_sine_patch()
			set_param(&p, 38, 1)
			set_param(&p, 57, 1)
			set_param(&p, 41, arch_stored_for_id(41, 4)) // volume
			set_param(&p, 42, 0) // saw
			set_param(&p, 43, rate)
			set_param(&p, 44, 127)
			set_param(&p, 68, sync)
			set_param(&p, 67, 0)
			ev := []Script_Event{script_on(sc.a, 84), script_off(sc.a + 0.9, 84), script_on(sc.b, 84), script_off(sc.b + 0.9, 84)}
			ref, ours := arch_render(dll, &p, c, ev, sc.b + 1.0)
			write_pair(o.wav, fmt.tprintf("lfophase-s%v-%v-%v", sync, sc.a, sc.b), ref, ours)
			cells: [2]string
			for audio, side in ([2][]f32{ref, ours}) {
				x := script_channel(audio, -1)
				count := len(x) / FRAME
				env := make([]f64, count)
				for f in 0 ..< count {
					sum := 0.0
					for i in f * FRAME ..< (f + 1) * FRAME {sum += f64(x[i]) * f64(x[i])}
					env[f] = math.sqrt(sum / FRAME)
				}
				ph: [2]f64
				for note in 0 ..< 2 {
					on := ev[note * 2].frame
					off := ev[note * 2 + 1].frame
					jumps := saw_jumps(env, on / FRAME + 3, off / FRAME - 2)
					measured := period
					if len(jumps) >= 2 {
						measured = f64((jumps[len(jumps) - 1] - jumps[0]) * FRAME) / f64(len(jumps) - 1)
					}
					ph[note] = len(jumps) > 0 ? onset_phase(on, jumps[0] * FRAME, measured) : -1
					delete(jumps)
				}
				diff := ph[1] - ph[0]
				diff -= math.floor(diff)
				cells[side] = fmt.tprintf("%v %v %v", dec3(ph[0], 7), dec3(ph[1], 7), dec3(diff, 7))
				delete(env)
				delete(x)
			}
			arch_free_pair(ref, ours)
			free_run := f64(ev[2].frame - ev[0].frame) / period
			free_run -= math.floor(free_run)
			fmt.printfln("  %-5v %-14v | %v | %v | %v", sync == 1 ? "on" : "off",
				fmt.tprintf("%v, %v", dec3(f64(ev[0].frame) / SAMPLE_RATE), dec3(f64(ev[2].frame) / SAMPLE_RATE)),
				cells[0], cells[1], dec3(free_run, 7))
			free_all(context.temp_allocator)
		}
	}
	lfophase_shared(dll, c, o, rate, period)
}

// A line's amplitude, frame by frame: a Hann-windowed single-bin DFT at `hz`,
// scaled so a steady sine of amplitude A reads A. Two notes an octave apart
// are read separately this way where a broadband envelope would sum them.
LINE_WINDOW :: 960 // 20 ms: 50 Hz bins; notes 60 and 72 sit 262 Hz apart
LINE_HOP :: 96

line_envelope :: proc(x: []f32, hz: f64, window, hop: int) -> []f64 {
	count := len(x) >= window ? (len(x) - window) / hop + 1 : 0
	out := make([]f64, count)
	for f in 0 ..< count {
		re, im := 0.0, 0.0
		for i in 0 ..< window {
			w := 0.5 - 0.5 * math.cos(2.0 * math.PI * f64(i) / f64(window))
			ph := 2.0 * math.PI * hz * f64(f * hop + i) / f64(SAMPLE_RATE)
			v := f64(x[f * hop + i]) * w
			re += v * math.cos(ph)
			im += v * math.sin(ph)
		}
		out[f] = math.sqrt(re * re + im * im) * 4.0 / f64(window)
	}
	return out
}

// The sample positions at which a windowed envelope jumps up by more than half
// its range: within each run of frames that rise that much over `span`
// frames, the steepest single step, whose two frames' windows straddle the
// jump at their mid-point.
rise_times :: proc(env: []f64, span, window, hop: int) -> [dynamic]f64 {
	out: [dynamic]f64
	top := 0.0
	for v in env {top = max(top, v)}
	k := span
	for k < len(env) {
		if env[k] - env[k - span] <= 0.5 * top {
			k += 1
			continue
		}
		steepest := k
		for k < len(env) && env[k] - env[k - span] > 0.5 * top {
			if env[k] - env[k - 1] > env[steepest] - env[steepest - 1] {steepest = k}
			k += 1
		}
		append(&out, (f64(steepest) - 0.5) * f64(hop) + f64(window) / 2)
	}
	return out
}

// T4b: one LFO for every voice, or one each. Poly 16 with two in-phase
// unison layers renders two notes in the reference under this host (`arch
// voices`), where plain poly does not. With key sync on, a second note resets
// a shared LFO, and the first note's saw jumps in step with the second's from
// then on; an LFO of its own keeps the first note on its own cycle.
lfophase_shared :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options, rate: int, period: f64) {
	fmt.println()
	fmt.println("  two notes at once: poly 16, unison 2 in phase, note 60 at 0 s and note 72 at 0.5 s, same LFO 1")
	fmt.println("  each note's line read with a 20 ms window; phase of its first saw jump after 0.52 s, in turns (-0.5..0.5),")
	fmt.println("  from note 60's onset (an LFO per voice, key-synced, reads 0) and from note 72's (a shared one reads 0)")
	fmt.printfln("  %-5v | %-30v | %-30v", "sync", "ref 60/own 60/72's 72/own", "our 60/own 60/72's 72/own")
	for sync in ([2]int{1, 0}) {
		p := voice_case_patch(Voice_Case{"", 0, 16, 2, 2})
		set_param(&p, 57, 1)
		set_param(&p, 41, arch_stored_for_id(41, 4)) // volume
		set_param(&p, 42, 0) // saw
		set_param(&p, 43, rate)
		set_param(&p, 44, 127)
		set_param(&p, 68, sync)
		set_param(&p, 67, 0)
		ev := []Script_Event{script_on(0, 60), script_on(0.5, 72), script_off(1.6, 60), script_off(1.6, 72)}
		ref, ours := arch_render(dll, &p, c, ev, 1.7)
		write_pair(o.wav, fmt.tprintf("lfoshared-s%v", sync), ref, ours)
		cells: [2]string
		for audio, side in ([2][]f32{ref, ours}) {
			x := script_channel(audio, -1)
			ph: [3]f64 = {math.nan_f64(), math.nan_f64(), math.nan_f64()}
			for note, n in ([2]int{60, 72}) {
				env := line_envelope(x, note_hz(f64(note)), LINE_WINDOW, LINE_HOP)
				rises := rise_times(env, LINE_WINDOW / LINE_HOP, LINE_WINDOW, LINE_HOP)
				for r in rises {
					if r < f64(ev[1].frame) + 0.02 * SAMPLE_RATE {continue}
					turns :: proc(d, period: f64) -> f64 {v := d / period;return v - math.round(v)}
					if n == 0 {
						ph[0] = turns(r - f64(ev[0].frame), period)
						ph[1] = turns(r - f64(ev[1].frame), period)
					} else {
						ph[2] = turns(r - f64(ev[1].frame), period)
					}
					break
				}
				delete(rises)
				delete(env)
			}
			cells[side] = fmt.tprintf("%v %v %v", sdec3(ph[0], 9), sdec3(ph[1], 9), sdec3(ph[2], 9))
			delete(x)
		}
		arch_free_pair(ref, ours)
		fmt.printfln("  %-5v | %-30v | %-30v", sync == 1 ? "on" : "off", cells[0], cells[1])
		free_all(context.temp_allocator)
	}
}

// ------------------------------------------------------------------ envshape

// A sine's amplitude once per cycle: the largest |sample| in each period. At
// 46 samples a cycle the sampled peak is within 0.02 dB of the true one, where
// a fixed RMS frame holding a non-integer number of cycles ripples by tenths of
// a decibel and bends a fitted slope.
cycle_peak_db :: proc(x: []f32, period: f64) -> []f64 {
	out: [dynamic]f64
	for k := 0; ; k += 1 {
		from := int(math.floor(f64(k) * period))
		to := int(math.floor(f64(k + 1) * period))
		if to > len(x) {break}
		top := 0.0
		for i in from ..< to {top = max(top, abs(f64(x[i])))}
		append(&out, top > 1.0e-10 ? 20.0 * math.log10(top) : -200)
	}
	return out[:]
}

cmd_arch_envshape :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	period := f64(SAMPLE_RATE) / note_hz(84)
	frame_ms := period * 1000 / f64(SAMPLE_RATE)
	values := o.values[:]
	if len(values) == 0 {values = []int{30, 50, 70, 90}}
	fmt.println("arch envshape: sine note 84, peak level once per cycle, span from 3 dB to 45 dB under the segment's start")
	fmt.println("  early/late: dB slope over the first and last thirds; ratio 1 is exponential, a linear ramp grows it")
	fmt.println("  dB-line: RMS residual of a straight line in dB; amp-line: of a straight line in amplitude, / start")
	fmt.println()
	fmt.printfln("  %-12v | %-44v | %-44v", "segment", "ref span early late ratio dB-line amp-line", "our span early late ratio dB-line amp-line")
	for segment in ([2]string{"decay", "release"}) {
		for v in values {
			p := arch_sine_patch()
			set_param(&p, 25, 0)
			on_s := 0.0
			off_s: f64
			seconds: f64
			if segment == "decay" {
				set_param(&p, 26, v)
				set_param(&p, 27, 0)
				t := f64(sengine.envelope_decay_time(26, v))
				off_s = t + 0.3
				seconds = off_s + 0.1
			} else {
				set_param(&p, 26, 0)
				set_param(&p, 27, 127)
				set_param(&p, 28, v)
				t := f64(sengine.envelope_release_time(28, v))
				off_s = 0.3
				seconds = off_s + t + 0.3
			}
			ev := []Script_Event{script_on(on_s, 84), script_off(off_s, 84)}
			ref, ours := arch_render(dll, &p, c, ev, seconds)
			write_pair(o.wav, fmt.tprintf("envshape-%v-%v", segment, v), ref, ours)
			cells: [2]string
			for audio, side in ([2][]f32{ref, ours}) {
				x := script_channel(audio, -1)
				db := cycle_peak_db(x, period)
				start := segment == "decay" ? 0 : int(f64(ev[1].frame) / period) + 1
				sh := decay_shape(db, start, frame_ms, 3, 45)
				cells[side] = sh.ok ? fmt.tprintf("%v %v %v %v %v %v", dec0(sh.span_ms, 6), dec4(sh.early_db_ms, 7), dec4(sh.late_db_ms, 7),
					dec2(sh.ratio, 5), dec2(sh.db_line_rms, 5), dec3(sh.amp_line_rms, 6)) : "unreadable"
				delete(db)
				delete(x)
			}
			arch_free_pair(ref, ours)
			fmt.printfln("  %-12v | %-44v | %-44v", fmt.tprintf("%v %v", segment, v), cells[0], cells[1])
			free_all(context.temp_allocator)
		}
	}
}

// ------------------------------------------------------------------ ramp

cmd_arch_ramp :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	HOP :: 24 // 0.5 ms
	GUARD :: 4 // 2 ms: more than half of either measurement window
	fmt.println("arch ramp: a parameter, controller or bend stepped at 0.5 s and back at 1.0 s")
	fmt.println("  cutoff/cc: sine note 108 through the 12 dB low pass, cutoff 30 <-> 70 (cc: controller 1 assigned")
	fmt.println("  to cutoff, sensitivity stored 80, from 30); the sine stays two octaves above the corner, so its")
	fmt.println("  level in dB is close to linear in the cutoff state. Centred 2 ms RMS windows.")
	fmt.println("  pitch: oscillator 2 triangle note 96, parameter 2 0 <-> +12; bend: sine note 96, range 12, raw")
	fmt.println("  8192 <-> 16383. Pitch from zero crossings in centred 3 ms windows. Every 0.5 ms.")
	fmt.println("  u(t): progress of the step at t ms after the event's block boundary; t10/t90: when it crosses 10%")
	fmt.println("  and 90%; mid: u halfway between t10 and t90, 0.50 for a linear ramp, 0.70 for a one-pole")
	fmt.println()
	whats := []string{"cutoff", "cc", "pitch", "bend", "cutoff-small", "bend-half"}
	if o.what != "" {whats = []string{o.what}}
	offsets := []f64{0, 5, 10, 20, 30, 40, 50, 60}
	head := strings.builder_make(context.temp_allocator)
	for off in offsets {fmt.sbprintf(&head, " %v", pad_left(fmt.tprintf("u%v", off), 5))}
	fmt.printfln("  %-7v %-5v %-4v |%v | %6v %6v %6v %5v", "what", "step", "side", strings.to_string(head), "t10", "t90", "10-90", "mid")
	for what in whats {
		p := arch_sine_patch()
		note := 108
		ev: [dynamic]Script_Event
		defer delete(ev)
		switch what {
		case "cutoff", "cc", "cutoff-small":
			set_param(&p, 14, arch_stored_for_id(14, 0))
			set_param(&p, 19, 30)
			set_param(&p, 20, 0)
			if what == "cutoff" {
				append(&ev, script_on(0, note), script_set(0.5, 19, 70), script_set(1.0, 19, 30), script_off(1.5, note))
			} else if what == "cutoff-small" {
				// A quarter of the step: a fixed-time ramp still takes the same
				// time, a fixed-rate one a quarter of it.
				append(&ev, script_on(0, note), script_set(0.5, 19, 40), script_set(1.0, 19, 30), script_off(1.5, note))
			} else {
				set_param(&p, 86, 0xB001)
				set_param(&p, 87, 19)
				set_param(&p, 50, 80)
				set_param(&p, 88, 0xB002)
				set_param(&p, 89, 44)
				set_param(&p, 51, 64)
				append(&ev, script_on(0, note), script_cc(0.5, 1, 127), script_cc(1.0, 1, 0), script_off(1.5, note))
			}
		case "pitch":
			note = 96
			set_param(&p, 1, 3) // oscillator 2 triangle, alone
			set_param(&p, 5, 127)
			set_param(&p, 4, 1)
			zero := arch_stored_for_number(2, 0)
			set_param(&p, 2, zero)
			set_param(&p, 3, 64)
			append(&ev, script_on(0, note), script_set(0.5, 2, arch_stored_for_number(2, 12)), script_set(1.0, 2, zero), script_off(1.5, note))
		case "bend", "bend-half":
			note = 96
			set_param(&p, 40, arch_stored_for_number(40, 12))
			append(&ev, script_on(0, note), script_bend(0.5, what == "bend" ? 16383 : 12288), script_bend(1.0, 8192), script_off(1.5, note))
		case:
			usage()
		}
		ref, ours := arch_render(dll, &p, c, ev[:], 1.6)
		write_pair(o.wav, fmt.tprintf("ramp-%v", what), ref, ours)
		for step in 0 ..< 2 {
			for audio, side in ([2][]f32{ref, ours}) {
				x := script_channel(audio, -1)
				at := ev[1 + step].frame
				from := at - ms_to_frame(60)
				to := ev[2 + step].frame - ms_to_frame(5)
				series: [dynamic]f64
				for t := from; t < to; t += HOP {
					if what == "cutoff" || what == "cc" || what == "cutoff-small" {
						append(&series, window_db(x, t - ms_to_frame(1), t + ms_to_frame(1)))
					} else {
						append(&series, hz_to_midi(zc_frequency(x, t - ms_to_frame(1.5), t + ms_to_frame(1.5))))
					}
				}
				i_at := (at - from) / HOP
				s := step_levels(series[:], i_at, GUARD, 40, 60)
				row := strings.builder_make(context.temp_allocator)
				for off in offsets {
					k := i_at + int(off * 2)
					fmt.sbprintf(&row, " %v", s.ok && k < len(series) ? dec2(step_progress(s, series[k]), 5) : pad_left("-", 5))
				}
				t10, ok10 := step_crossing(series[:], s, i_at, GUARD, 0.1)
				t90, ok90 := step_crossing(series[:], s, i_at, GUARD, 0.9)
				ms :: proc(t: f64, ok: bool) -> string {return ok ? dec1(t * 0.5, 6) : pad_left("-", 6)}
				mid := "    -"
				if ok10 && ok90 {
					k := i_at + int(math.round((t10 + t90) / 2))
					if k >= 0 && k < len(series) {mid = dec2(step_progress(s, series[k]), 5)}
				}
				span := ok10 && ok90 ? dec1((t90 - t10) * 0.5, 6) : pad_left("-", 6)
				fmt.printfln("  %-7v %-5v %-4v |%v | %v %v %v %v", what, step == 0 ? "up" : "down", side == 0 ? "ref" : "ours",
					strings.to_string(row), ms(t10, ok10), ms(t90, ok90), span, mid)
				delete(series)
				delete(x)
			}
		}
		arch_free_pair(ref, ours)
		free_all(context.temp_allocator)
	}
}

// ------------------------------------------------------------------ clip

cmd_arch_clip :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	f0 := note_hz(48)
	eq_f0, _ := arch_eq_stored_near(f0)
	fmt.println("arch clip: sine note 48, amp gain 127, N unison layers in phase (detune 0, phase shift 0, no spread)")
	fmt.println("  peak is the largest |sample| of either channel, 0.3-1.3 s; H3, H5 against H1")
	fmt.println()
	Clip_Case :: struct {
		voices: int,
		eq:     bool,
	}
	cases := []Clip_Case{{1, false}, {2, false}, {4, false}, {8, false}, {1, true}, {8, true}}
	fmt.printfln("  %-12v | %9v %8v %8v %8v | %9v %8v %8v %8v", "case", "ref peak", "H1", "H3-H1", "H5-H1", "our peak", "H1", "H3-H1", "H5-H1")
	for cs in cases {
		p := arch_sine_patch()
		set_param(&p, 29, 127)
		if cs.voices > 1 {
			set_param(&p, 73, 1)
			set_param(&p, 93, arch_stored_for_display(93, fmt.tprint(cs.voices)))
			set_param(&p, 75, 0)
			set_param(&p, 84, 64)
			set_param(&p, 85, arch_stored_for_number(85, 0))
			set_param(&p, 92, 0)
		}
		if cs.eq {
			set_param(&p, 61, eq_f0)
			set_param(&p, 62, 127)
		}
		ev := []Script_Event{script_on(0, 48), script_off(1.4, 48)}
		ref, ours := arch_render(dll, &p, c, ev, 1.5)
		write_pair(o.wav, fmt.tprintf("clip-%v%v", cs.voices, cs.eq ? "-eq" : ""), ref, ours)
		cells: [2]string
		for audio, side in ([2][]f32{ref, ours}) {
			peak := 0.0
			for i in ms_to_frame(300) * 2 ..< ms_to_frame(1300) * 2 {peak = max(peak, abs(f64(audio[i])))}
			x := script_channel(audio, -1)
			h := arch_harmonics(x, ms_to_frame(300), ms_to_frame(1300), f0)
			cells[side] = fmt.tprintf("%v %v %v %v", sdec1(20 * math.log10(max(peak, 1.0e-12)), 9), dec1(h[0], 8), sdec1(h[2] - h[0], 8), sdec1(h[4] - h[0], 8))
			delete(x)
		}
		arch_free_pair(ref, ours)
		fmt.printfln("  %-12v | %v | %v", fmt.tprintf("%v layers%v", cs.voices, cs.eq ? " +EQ" : ""), cells[0], cells[1])
		free_all(context.temp_allocator)
	}
}

// ------------------------------------------------------------------ rate

cmd_arch_rate :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	// A pulse at note 0 holds a plateau for tens of milliseconds, and dividing a
	// modulated render by an unmodulated one of the same patch leaves the gain
	// sequence itself wherever the plateau is well away from zero.
	base :: proc() -> cpatch.Patch {
		p := arch_sine_patch()
		set_param(&p, 0, 2) // pulse
		set_param(&p, 8, 64)
		set_param(&p, 29, 100)
		return p
	}
	decay := 40
	lfo_rate := 0
	best := 1.0e9
	for s in 0 ..< 128 {
		hz := f64(sengine.lfo_rate_hz(sengine.resolved_position(43, s)))
		if abs(hz - 8) < best {
			best = abs(hz - 8)
			lfo_rate = s
		}
	}
	fmt.println("arch rate: pulse at note 0; gain = modulated render / flat render where |flat| > half its peak")
	fmt.printfln("  envelope: decay stored %v, sustain 0; LFO: sine on volume, depth 64, rate stored %v", decay, lfo_rate)
	fmt.println("  spikes: |2nd difference| over 20x its median; spacing: commonest gap; on-grid: share of gaps that are")
	fmt.println("  multiples of it; phase: commonest spike index mod spacing; zero d1: share of exactly flat steps")
	fmt.println()
	ev := []Script_Event{script_on(0, 0), script_off(1.1, 0)}
	flat := base()
	fref, fours := arch_render(dll, &flat, c, ev, 1.2)
	defer arch_free_pair(fref, fours)
	fmt.printfln("  %-9v | %-40v | %-40v", "source", "ref samples spikes spacing grid phase zero-d1", "our samples spikes spacing grid phase zero-d1")
	for source in ([2]string{"envelope", "lfo"}) {
		p := base()
		to_ms := 400.0
		if source == "envelope" {
			set_param(&p, 26, decay)
			set_param(&p, 27, 0)
		} else {
			set_param(&p, 57, 1)
			set_param(&p, 41, arch_stored_for_id(41, 4))
			set_param(&p, 42, 5) // sine
			set_param(&p, 43, lfo_rate)
			set_param(&p, 44, 64)
			set_param(&p, 68, 1)
			to_ms = 1000
		}
		ref, ours := arch_render(dll, &p, c, ev, 1.2)
		write_pair(o.wav, fmt.tprintf("rate-%v", source), ref, ours)
		cells: [2]string
		flats := [2][]f32{fref, fours}
		for audio, side in ([2][]f32{ref, ours}) {
			from := ms_to_frame(5)
			to := ms_to_frame(to_ms)
			top := 0.0
			for i in from ..< to {top = max(top, abs(f64(flats[side][i * 2])))}
			g := make([]f64, to - from)
			valid := make([]bool, to - from)
			for i in from ..< to {
				f := f64(flats[side][i * 2])
				if abs(f) > 0.5 * top {
					g[i - from] = f64(audio[i * 2]) / f
					valid[i - from] = true
				}
			}
			r := grid_reading(g, valid, 20)
			// Back to absolute sample positions for the phase.
			phase := r.spacing > 0 ? (r.phase + from) % r.spacing : 0
			cells[side] = fmt.tprintf("%v %v %v %v %v %v", pad_left(fmt.tprint(r.samples), 7), pad_left(fmt.tprint(r.spikes), 6),
				pad_left(fmt.tprint(r.spacing), 7), dec2(r.on_grid, 4), pad_left(fmt.tprint(phase), 5), dec3(r.zero_d1, 7))
			delete(g)
			delete(valid)
		}
		arch_free_pair(ref, ours)
		fmt.printfln("  %-9v | %-40v | %-40v", source, cells[0], cells[1])
		free_all(context.temp_allocator)
	}
}

// ------------------------------------------------------------------ osc

cmd_arch_osc :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	N :: 16384
	bin_hz := f64(SAMPLE_RATE) / f64(N)
	fmt.println("arch osc: oscillator 1 alone, filter open, 0.3-1.9 s, 16384-point Welch")
	fmt.println("  sine: harmonics and the worst non-harmonic bin against H1, and H1's frequency error in cents")
	fmt.println("  saw/pulse: energy away from every harmonic (+/-3 bins) against the total, in dB")
	fmt.println()
	Osc_Case :: struct {
		shape: int,
		note:  int,
	}
	cases := []Osc_Case{{0, 48}, {0, 69}, {0, 93}, {1, 72}, {1, 96}, {2, 96}}
	fmt.printfln("  %-10v | %-38v | %-38v", "case", "ref H2 H3 spur cents / inharmonic", "our H2 H3 spur cents / inharmonic")
	for cs in cases {
		p := arch_sine_patch()
		set_param(&p, 0, cs.shape)
		set_param(&p, 8, 64)
		ev := []Script_Event{script_on(0, cs.note), script_off(2.0, cs.note)}
		ref, ours := arch_render(dll, &p, c, ev, 2.1)
		write_pair(o.wav, fmt.tprintf("osc-%v-%v", cs.shape, cs.note), ref, ours)
		f0 := note_hz(f64(cs.note))
		cells: [2]string
		for audio, side in ([2][]f32{ref, ours}) {
			x := script_channel(audio, 0)
			power := arch_spectrum(x, ms_to_frame(300), ms_to_frame(1900), N)
			harmonic := make([]bool, len(power))
			for k := 1; f0 * f64(k) < f64(SAMPLE_RATE) / 2; k += 1 {
				centre := int(math.round(f0 * f64(k) / bin_hz))
				for b in centre - 3 ..= centre + 3 {
					if b >= 0 && b < len(power) {harmonic[b] = true}
				}
			}
			h1 := arch_line_power(power, bin_hz, f0)
			if cs.shape == 0 {
				spur := 0.0
				for b in int(20 / bin_hz) ..< len(power) {
					if !harmonic[b] {spur = max(spur, power[b])}
				}
				// Parabolic refinement of the fundamental's peak bin, in dB.
				k := int(math.round(f0 / bin_hz))
				for b in k - 2 ..= k + 2 {if power[b] > power[k] {k = b}}
				a, m, z := power_db(power[k - 1]), power_db(power[k]), power_db(power[k + 1])
				den := a - 2 * m + z
				off := abs(den) > 1.0e-12 ? 0.5 * (a - z) / den : 0
				cents := 1200 * math.log2((f64(k) + off) * bin_hz / f0)
				cells[side] = fmt.tprintf("%v %v %v %v", sdec1(power_db(arch_line_power(power, bin_hz, 2 * f0)) - power_db(h1), 7),
					sdec1(power_db(arch_line_power(power, bin_hz, 3 * f0)) - power_db(h1), 7), sdec1(power_db(spur) - power_db(h1), 7), sdec3(cents, 8))
			} else {
				total, away := 0.0, 0.0
				for b in int(20 / bin_hz) ..< len(power) {
					total += power[b]
					if !harmonic[b] {away += power[b]}
				}
				cells[side] = fmt.tprintf("inharmonic %v dB", sdec1(power_db(away) - power_db(total), 7))
			}
			delete(harmonic)
			delete(power)
			delete(x)
		}
		arch_free_pair(ref, ours)
		fmt.printfln("  %-10v | %-38v | %-38v", fmt.tprintf("%v %v", cs.shape == 0 ? "sine" : cs.shape == 1 ? "saw" : "pulse", cs.note), cells[0], cells[1])
		free_all(context.temp_allocator)
	}
}

// ------------------------------------------------------------------ voices

Voice_Case :: struct {
	label:     string,
	mode:      int, // parameter 38: 0 poly, 1 mono
	polyphony: int,
	unison:    int, // 1 is off
	notes:     int, // 2 or 3 overlapping notes
}

// Notes 60, 72 and 84 are one line each, started 0.3 s apart and all
// released at 1.0 s. Unison layers are not detuned or spread, so a note with
// any number of layers is still one line.
VOICE_CASES := []Voice_Case {
	{"mono, poly 16", 1, 16, 1, 2},
	{"poly 16", 0, 16, 1, 2},
	{"poly 1", 0, 1, 1, 2},
	{"poly 1, unison 2", 0, 1, 2, 3},
	{"poly 2, unison 2", 0, 2, 2, 3},
	{"poly 3, unison 2", 0, 3, 2, 3},
	{"poly 4, unison 2", 0, 4, 2, 3},
	{"poly 5, unison 2", 0, 5, 2, 3},
	{"poly 6, unison 2", 0, 6, 2, 3},
	{"poly 16, unison 2", 0, 16, 2, 3},
	{"poly 4, unison 4", 0, 4, 4, 3},
	{"poly 7, unison 4", 0, 7, 4, 3},
	{"poly 8, unison 4", 0, 8, 4, 3},
	{"poly 12, unison 4", 0, 12, 4, 3},
	{"poly 16, unison 8", 0, 16, 8, 3},
	{"poly 24, unison 8", 0, 24, 8, 3},
}

VOICE_NOTES := [3]int{60, 72, 84}

voice_case_patch :: proc(vc: Voice_Case) -> cpatch.Patch {
	p := arch_sine_patch()
	set_param(&p, 38, vc.mode)
	set_param(&p, 94, arch_stored_for_number(94, f32(vc.polyphony)))
	if vc.unison > 1 {
		set_param(&p, 73, 1)
		set_param(&p, 93, arch_stored_for_display(93, fmt.tprint(vc.unison)))
		set_param(&p, 75, 0)
		set_param(&p, 84, 64)
		set_param(&p, 85, arch_stored_for_number(85, 0))
		set_param(&p, 92, 0)
	}
	return p
}

// Each note's line just after its own onset and at 0.8-0.95 s, as an amplitude
// in units of one layer: `single` is the same line's amplitude from a one-note,
// unison-off render of the same engine. Layers are in phase (detune 0, phase
// shift 0, phase fixed), so a note with U layers reads U, and a note whose
// layers were taken reads fewer.
Voice_Reading :: struct {
	onset: [3]f64,
	final: [3]f64,
}

VOICE_FFT :: 4096

voice_line_amplitude :: proc(x: []f32, from: int, note: int) -> f64 {
	power := arch_spectrum(x, from, from + VOICE_FFT, VOICE_FFT)
	defer delete(power)
	return math.sqrt(arch_line_power(power, f64(SAMPLE_RATE) / VOICE_FFT, note_hz(f64(note))))
}

voice_case_read :: proc(audio: []f32, notes: int, single: [3]f64) -> (r: Voice_Reading) {
	x := script_channel(audio, -1)
	defer delete(x)
	for k in 0 ..< notes {
		r.onset[k] = voice_line_amplitude(x, ms_to_frame(300 * f64(k) + 40), VOICE_NOTES[k]) / single[k]
		r.final[k] = voice_line_amplitude(x, ms_to_frame(800), VOICE_NOTES[k]) / single[k]
	}
	return
}

voice_case_events :: proc(notes: int) -> (events: [6]Script_Event, count: int) {
	for k in 0 ..< notes {
		events[k] = script_on(0.3 * f64(k), VOICE_NOTES[k])
		events[notes + k] = script_off(1.0, VOICE_NOTES[k])
	}
	return events, notes * 2
}

voice_reading_text :: proc(r: Voice_Reading, notes: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for k in 0 ..< notes {fmt.sbprintf(&b, "  %v -> %v", dec2(r.onset[k], 5), dec2(r.final[k], 5))}
	return strings.to_string(b)
}

// One case, in this process. Ours first, so a reference that dies still
// leaves this engine's row behind.
cmd_arch_voice_child :: proc(dll: string, c: ^Arch_Chunk, index: int) {
	vc := VOICE_CASES[index]
	p := voice_case_patch(vc)
	events, count := voice_case_events(vc.notes)
	ev := events[:count]
	// One layer of each note alone, for the unit.
	solo := arch_sine_patch()
	set_param(&solo, 38, vc.mode)
	single: [2][3]f64
	for k in 0 ..< vc.notes {
		sev := []Script_Event{script_on(0.3 * f64(k), VOICE_NOTES[k]), script_off(1.0, VOICE_NOTES[k])}
		ours := render_ours_script(solo, sev, script_frame(1.1))
		x := script_channel(ours, -1)
		single[1][k] = voice_line_amplitude(x, ms_to_frame(300 * f64(k) + 40), VOICE_NOTES[k])
		delete(x)
		delete(ours)
		ref := render_reference_script(dll, &solo, c.pristine, c.work, sev, script_frame(1.1))
		x = script_channel(ref, -1)
		single[0][k] = voice_line_amplitude(x, ms_to_frame(300 * f64(k) + 40), VOICE_NOTES[k])
		delete(x)
		delete(ref)
	}
	ours := render_ours_script(p, ev, script_frame(1.1))
	fmt.printfln("  %-20v ours:%v", vc.label, voice_reading_text(voice_case_read(ours, vc.notes, single[1]), vc.notes))
	delete(ours)
	ref := render_reference_script(dll, &p, c.pristine, c.work, ev, script_frame(1.1))
	fmt.printfln("  %-20v ref: %v", vc.label, voice_reading_text(voice_case_read(ref, vc.notes, single[0]), vc.notes))
	delete(ref)
}

cmd_arch_voices :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	if o.child {
		cmd_arch_voice_child(dll, c, o.case_)
		return
	}
	exe, ok := self_path()
	if !ok {
		fmt.eprintln("arch voices: cannot find this executable")
		os.exit(1)
	}
	fmt.println("arch voices: sine, notes 60, 72 (and 84) started 0.3 s apart, all released at 1.0 s")
	fmt.println("  per note: line amplitude just after its onset -> at 0.8-0.95 s, in units of one layer of the")
	fmt.println("  same note alone (layers in phase, so U layers read U; 0 is gone). Each case in a child process.")
	fmt.println()
	for vc, i in VOICE_CASES {
		b := strings.builder_make(context.temp_allocator)
		quote(&b, exe)
		strings.write_string(&b, "arch ")
		quote(&b, dll)
		fmt.sbprintf(&b, "voices --child --case %v", i)
		code, spawned := spawn_and_wait(strings.to_string(b))
		if spawned {
			fmt.printfln("  %-20v child: %v (exit code 0x%08X)", vc.label, exit_reason(code), code)
		} else {
			fmt.printfln("  %-20v child: could not start", vc.label)
		}
	}
}

// ------------------------------------------------------------------ eq

// The magnitude of the cookbook peaking biquad, at `hz`, written out here and not
// taken from the engine: the engine's peak is the reference's own design, and a
// fit to "the nearest cookbook Q" is only a way of putting one number on a width.
rbj_peak_db :: proc(f0, gain_db, q, hz: f64) -> f64 {
	a := math.pow(10.0, gain_db / 40)
	w0 := 2 * math.PI * f0 / f64(SAMPLE_RATE)
	alpha := math.sin(w0) / (2 * q)
	b0, b1, b2 := 1 + alpha * a, -2 * math.cos(w0), 1 - alpha * a
	a0, a1, a2 := 1 + alpha / a, -2 * math.cos(w0), 1 - alpha / a
	w := 2.0 * math.PI * hz / f64(SAMPLE_RATE)
	nr := b0 + b1 * math.cos(w) + b2 * math.cos(2 * w)
	ni := -b1 * math.sin(w) - b2 * math.sin(2 * w)
	dr := a0 + a1 * math.cos(w) + a2 * math.cos(2 * w)
	di := -a1 * math.sin(w) - a2 * math.sin(2 * w)
	return 10.0 * math.log10((nr * nr + ni * ni) / (dr * dr + di * di))
}

// The points every transfer report is read at: sixth octaves, 50 Hz to 12 kHz.
arch_points :: proc() -> [dynamic]f64 {
	out: [dynamic]f64
	for hz := 50.0; hz <= 12000; hz *= math.pow(f64(2.0), 1.0 / 6.0) {append(&out, hz)}
	return out
}

Peak_Fit :: struct {
	peak_db, peak_hz, width_oct, q, residual: f64,
}

// Peak, half-gain width, and the bilinear peaking Q that best fits the curve
// with its centre and gain fixed at the measured peak.
fit_peak :: proc(points, db: []f64) -> Peak_Fit {
	f: Peak_Fit
	k := 0
	for i in 0 ..< len(db) {if abs(db[i]) > abs(db[k]) {k = i}}
	f.peak_db = db[k]
	f.peak_hz = points[k]
	if k > 0 && k < len(db) - 1 {
		a, b, c := db[k - 1], db[k], db[k + 1]
		den := a - 2 * b + c
		if abs(den) > 1.0e-12 {
			off := clamp(0.5 * (a - c) / den, -1, 1)
			f.peak_hz = points[k] * math.pow(2.0, off / 6.0)
			f.peak_db = b - 0.25 * (a - c) * off
		}
	}
	half := f.peak_db / 2
	lo, hi := k, k
	for lo > 0 && abs(db[lo - 1]) >= abs(half) {lo -= 1}
	for hi < len(db) - 1 && abs(db[hi + 1]) >= abs(half) {hi += 1}
	f.width_oct = f64(hi - lo + 1) / 6.0
	best := 1.0e12
	for q := 0.1; q <= 30; q *= 1.01 {
		sum := 0.0
		for i in 0 ..< len(points) {
			d := rbj_peak_db(f.peak_hz, f.peak_db, q, points[i]) - db[i]
			sum += d * d
		}
		rms := math.sqrt(sum / f64(len(points)))
		if rms < best {
			best = rms
			f.q = q
		}
	}
	f.residual = best
	return f
}

cmd_arch_eq :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	N :: 16384
	bin_hz := f64(SAMPLE_RATE) / f64(N)
	freq, hz := arch_eq_stored_near(1000)
	cut := 1
	fmt.println("arch eq: oscillator 2 noise, filter open; transfer = EQ render against the flat render (same noise)")
	fmt.printfln("  EQ frequency stored %v (%q); level stored 127 (%q) and %v (%q)", freq, sengine.resolved_display(61, freq),
		sengine.resolved_display(62, 127), cut, sengine.resolved_display(62, cut))
	fmt.println("  Q fit: the cookbook peaking biquad with centre and gain fixed at the measured peak")
	fmt.println()
	ev := []Script_Event{script_on(0, 60), script_off(3.0, 60)}
	flat := arch_noise_patch()
	set_param(&flat, 61, freq)
	fref, fours := arch_render(dll, &flat, c, ev, 3.1)
	defer arch_free_pair(fref, fours)
	fmids := [2][]f32{script_channel(fref, -1), script_channel(fours, -1)}
	defer for m in fmids {delete(m)}
	points := arch_points()
	defer delete(points)
	qs := o.values[:]
	if len(qs) == 0 {qs = []int{0, 32, 64, 96, 127}}
	fmt.printfln("  %-14v | %-42v | %-42v | %v", "level, Q", "ref peak dB, Hz, width oct, fitted Q, rms", "our peak dB, Hz, width oct, fitted Q, rms", "our bound Q")
	sums: [2][dynamic]f64
	defer for s in sums {delete(s)}
	for q in qs {
		curves: [2][2][]f64 // [level][side]
		for level, li in ([2]int{127, cut}) {
			p := arch_noise_patch()
			set_param(&p, 61, freq)
			set_param(&p, 62, level)
			set_param(&p, 63, q)
			ref, ours := arch_render(dll, &p, c, ev, 3.1)
			write_pair(o.wav, fmt.tprintf("eq-l%v-q%v", level, q), ref, ours)
			cells: [2]string
			for audio, side in ([2][]f32{ref, ours}) {
				x := script_channel(audio, -1)
				h := arch_transfer(fmids[side], x, ms_to_frame(300), ms_to_frame(2900), N)
				db := make([]f64, len(points))
				for pt, i in points {db[i] = arch_transfer_db_at(h, bin_hz, pt)}
				curves[li][side] = db
				fit := fit_peak(points[:], db)
				cells[side] = fmt.tprintf("%v %v %v %v %v", sdec2(fit.peak_db, 7), dec0(fit.peak_hz, 6), dec2(fit.width_oct, 5), dec3(fit.q, 6), dec2(fit.residual, 5))
				delete(h)
				delete(x)
			}
			arch_free_pair(ref, ours)
			bound := sengine.bind_patch(p).eq_q
			fmt.printfln("  %-14v | %-42v | %-42v | %v", fmt.tprintf("%v, %v", level, q), cells[0], cells[1], dec3(f64(bound), 6))
		}
		for side in 0 ..< 2 {
			sum := 0.0
			for i in 0 ..< len(points) {
				d := curves[0][side][i] + curves[1][side][i]
				sum += d * d
			}
			append(&sums[side], math.sqrt(sum / f64(len(points))))
			delete(curves[0][side])
			delete(curves[1][side])
		}
		free_all(context.temp_allocator)
	}
	fmt.println()
	fmt.println("  boost + cut, RMS over the points (0 for a boost and cut that mirror each other in dB):")
	for q, i in qs {
		fmt.printfln("    Q stored %v: ref %v dB, ours %v dB", q, dec2(sums[0][i]), dec2(sums[1][i]))
	}
}

// ------------------------------------------------------------------ filtertype

cmd_arch_filtertype :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	N :: 16384
	bin_hz := f64(SAMPLE_RATE) / f64(N)
	cutoff := 64
	resonance := 0
	if len(o.values) > 0 {cutoff = o.values[0]}
	if len(o.values) > 1 {resonance = o.values[1]}
	fmt.printfln("arch filtertype: noise, cutoff %v (%v Hz on the axis), resonance %v; transfer against the 12 dB low pass at 127",
		cutoff, dec1(f64(sengine.filter_index_hz(sengine.filter_knob_index(f32(cutoff))))), resonance)
	fmt.println("  dB at octaves around the table corner, then the slope over the two octaves below and above it")
	fmt.println()
	ev := []Script_Event{script_on(0, 60), script_off(3.0, 60)}
	open := arch_noise_patch()
	set_param(&open, 14, arch_stored_for_id(14, 0))
	oref, oours := arch_render(dll, &open, c, ev, 3.1)
	defer arch_free_pair(oref, oours)
	omids := [2][]f32{script_channel(oref, -1), script_channel(oours, -1)}
	defer for m in omids {delete(m)}
	fc := f64(sengine.filter_index_hz(sengine.filter_knob_index(f32(cutoff))))
	octaves := []f64{-3, -2, -1, 0, 1, 2, 3, 4}
	header := strings.builder_make(context.temp_allocator)
	for oc in octaves {fmt.sbprintf(&header, " %v", pad_left(fmt.tprintf("%+.0f", oc), 6))}
	fmt.printfln("  %-6v %-4v |%v | %8v %8v", "type", "", strings.to_string(header), "below", "above")
	for t in 0 ..< 5 {
		p := arch_noise_patch()
		set_param(&p, 14, arch_stored_for_id(14, t))
		set_param(&p, 19, cutoff)
		set_param(&p, 20, resonance)
		ref, ours := arch_render(dll, &p, c, ev, 3.1)
		write_pair(o.wav, fmt.tprintf("filtertype-%v", t), ref, ours)
		for audio, side in ([2][]f32{ref, ours}) {
			x := script_channel(audio, -1)
			h := arch_transfer(omids[side], x, ms_to_frame(300), ms_to_frame(2900), N)
			row := strings.builder_make(context.temp_allocator)
			for oc in octaves {
				fmt.sbprintf(&row, " %v", sdec1(arch_transfer_db_at(h, bin_hz, fc * math.pow(2.0, oc)), 6))
			}
			below := (arch_transfer_db_at(h, bin_hz, fc / 2) - arch_transfer_db_at(h, bin_hz, fc / 8)) / 2
			above := (arch_transfer_db_at(h, bin_hz, fc * 8) - arch_transfer_db_at(h, bin_hz, fc * 2)) / 2
			fmt.printfln("  %-6v %-4v |%v | %v %v", side == 0 ? fmt.tprintf("%v %q", t, sengine.resolved_display(14, arch_stored_for_id(14, t))) : "",
				side == 0 ? "ref" : "ours", strings.to_string(row), sdec1(below, 8), sdec1(above, 8))
			delete(h)
			delete(x)
		}
		arch_free_pair(ref, ours)
		free_all(context.temp_allocator)
	}
}

// ------------------------------------------------------------------ tone

// The equaliser's tone control against its own next step up. Stored 65 is a high
// pass at 10 Hz, which is flat across the audible band, so the render at 65 is the
// baseline and every other setting's transfer against it is that setting's own
// section: a low pass up to the centre (22 kHz at 64, so a little under a decibel
// down at 10 kHz) and a high pass above it.
cmd_arch_tone :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	N :: 16384
	bin_hz := f64(SAMPLE_RATE) / f64(N)
	states := o.values[:]
	if len(states) == 0 {
		states = []int{64, 48, 32, 16, 0, 80, 96, 112, 127}
	}
	fmt.println("arch tone: noise, equaliser tone at each stored state against stored 65 (a 10 Hz high pass)")
	fmt.println()
	freqs := []f64{100, 500, 1000, 2000, 4000, 7000, 10000, 14000, 18000}
	header := strings.builder_make(context.temp_allocator)
	for hz in freqs {fmt.sbprintf(&header, " %v", pad_left(fmt.tprintf("%.0f", hz), 6))}
	fmt.printfln("  %-6v %-4v |%v", "state", "", strings.to_string(header))

	ev := []Script_Event{script_on(0, 60), script_off(3.0, 60)}
	base := arch_noise_patch()
	set_param(&base, 60, 65)
	bref, bours := arch_render(dll, &base, c, ev, 3.1)
	defer arch_free_pair(bref, bours)
	bmids := [2][]f32{script_channel(bref, -1), script_channel(bours, -1)}
	defer for m in bmids {delete(m)}

	for state in states {
		p := arch_noise_patch()
		set_param(&p, 60, state)
		ref, ours := arch_render(dll, &p, c, ev, 3.1)
		for audio, side in ([2][]f32{ref, ours}) {
			x := script_channel(audio, -1)
			h := arch_transfer(bmids[side], x, ms_to_frame(300), ms_to_frame(2900), N)
			row := strings.builder_make(context.temp_allocator)
			for hz in freqs {
				fmt.sbprintf(&row, " %v", sdec1(arch_transfer_db_at(h, bin_hz, hz), 6))
			}
			fmt.printfln("  %-6v %-4v |%v", side == 0 ? fmt.tprintf("%v", state) : "", side == 0 ? "ref" : "ours", strings.to_string(row))
			delete(h)
			delete(x)
		}
		arch_free_pair(ref, ours)
		free_all(context.temp_allocator)
	}
}

// ------------------------------------------------------------------ hits

// A short sound, read properly. The envelope of a hat or a click is a few
// milliseconds of band-limited noise, and the two engines' noise is not the same
// noise, so the level in any one window of one note is a sample of a distribution
// several decibels wide and the difference between engines is mostly that. This
// plays the patch `--values <n>` times (60 by default) in one render, a hit every
// 250 ms, and averages the power in each bin across the hits, which is the
// quantity the engines are supposed to agree on. `--what <file.sy1>` names the
// patch.
// Mean power of x over the frames [onset + from, onset + to) of every onset.
mean_power_across_hits :: proc(x: []f32, onsets: []int, from, to: int) -> f64 {
	total := 0.0
	count := 0
	for onset in onsets {
		for k in max(onset + from, 0) ..< min(onset + to, len(x)) {
			total += f64(x[k]) * f64(x[k])
			count += 1
		}
	}
	return total / f64(max(count, 1))
}

cmd_arch_hits :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	if len(o.what) == 0 {
		fmt.eprintln("arch hits: --what <patch.sy1> names the patch")
		os.exit(1)
	}
	data, read_err := os.read_entire_file(o.what, context.allocator)
	if read_err != nil {
		fmt.eprintfln("arch hits: cannot read %v", o.what)
		os.exit(1)
	}
	defer delete(data)
	patch, parse_err := cpatch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("arch hits: %v is not a patch", o.what)
		os.exit(1)
	}

	hits := 60
	if len(o.values) > 0 {hits = o.values[0]}
	PERIOD :: 0.25
	HOLD :: 0.12
	events: [dynamic]Script_Event
	defer delete(events)
	for h in 0 ..< hits {
		t := 0.1 + f64(h) * PERIOD
		append(&events, script_on(t, 60))
		append(&events, script_off(t + HOLD, 60))
	}
	seconds := 0.1 + f64(hits) * PERIOD + 0.2
	ref, ours := arch_render(dll, &patch, c, events[:], seconds)
	defer arch_free_pair(ref, ours)
	mids := [2][]f32{script_channel(ref, -1), script_channel(ours, -1)}
	defer for m in mids {delete(m)}

	onsets: [dynamic]int
	defer delete(onsets)
	for i := 0; i < len(events); i += 2 {
		append(&onsets, events[i].frame)
	}

	fmt.printfln("arch hits: %v, %v hits of note 60, a hit every %v ms; power averaged across hits", o.what, hits, int(PERIOD * 1000))
	fmt.println()
	fmt.println("   window ms      ref dB    ours dB    ours-ref")
	edges := [?]f64{0, 0.5, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 30, 40, 60, 80, 100}
	for b in 0 ..< len(edges) - 1 {
		power: [2]f64
		for side in 0 ..< 2 {
			power[side] = mean_power_across_hits(mids[side], onsets[:], ms_to_frame(edges[b]), ms_to_frame(edges[b + 1]))
		}
		r_db := 10.0 * math.log10(max(power[0], 1.0e-20))
		o_db := 10.0 * math.log10(max(power[1], 1.0e-20))
		fmt.printfln("  %4v - %-4v   %8v   %8v   %8v", edges[b], edges[b + 1], sdec1(r_db, 8), sdec1(o_db, 8), sdec1(o_db - r_db, 8))
	}
}

// ------------------------------------------------------------------ arp

// Which stored arpeggiator types play the same thing, in both engines. A chord is
// held (60, 64, 67) with the arpeggiator on, each stored value is rendered, and
// the values whose renders are bit-identical are grouped. The step pitches are
// not read: they come back as octaves and harmonics of the chord and the detector's
// scatter is larger than the difference being looked for. `--what <patch.sy1>` is
// the base (a patch the reference renders under every arpeggiator setting, such
// as factory 110), `--values` the stored types to try.
cmd_arch_arp :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	if len(o.what) == 0 {
		fmt.eprintln("arch arp: --what <patch.sy1> names the base patch")
		os.exit(1)
	}
	data, read_err := os.read_entire_file(o.what, context.allocator)
	if read_err != nil {
		fmt.eprintfln("arch arp: cannot read %v", o.what)
		os.exit(1)
	}
	defer delete(data)
	base, parse_err := cpatch.parse_sy1(data)
	if parse_err != .None {
		fmt.eprintfln("arch arp: %v is not a patch", o.what)
		os.exit(1)
	}
	values := o.values[:]
	if len(values) == 0 {
		values = []int{-1, 0, 1, 2, 3, 4, 5, 9}
	}

	fmt.printfln("arch arp: %v, chord 60 64 67 held, arpeggiator on, beat division 9, range 0", o.what)
	fmt.println("  stored values whose renders are bit-identical")
	fmt.println()
	notes := []int{60, 64, 67}
	hashes: [2][dynamic]u64
	defer {for h in hashes {delete(h)}}
	for stored in values {
		patch := base
		for pair in ([][2]int{{59, 1}, {31, stored}, {32, 0}, {33, 9}, {34, 64}}) {
			patch.values[pair[0]] = pair[1]
			patch.present[pair[0]] = true
		}
		events: [dynamic]Script_Event
		for n in notes {append(&events, script_on(0, n))}
		ref, ours := arch_render(dll, &patch, c, events[:], 4.0)
		for audio, side in ([2][]f32{ref, ours}) {
			hash := u64(14695981039346656037)
			for sample in audio {
				hash = (hash ~ u64(transmute(u32)sample)) * 1099511628211
			}
			append(&hashes[side], hash)
		}
		delete(events)
		arch_free_pair(ref, ours)
	}
	for side in 0 ..< 2 {
		fmt.printf("  %-4v", side == 0 ? "ref" : "ours")
		groups := identical_groups(hashes[side][:])
		for group in groups {
			fmt.print(" {")
			for index, k in group {
				fmt.printf("%v%v", k == 0 ? "" : ",", values[index])
			}
			fmt.print("}")
			delete(group)
		}
		delete(groups)
		fmt.println()
	}
}

// The indices of equal hashes, grouped, each group in order and the groups in order
// of their first member.
identical_groups :: proc(hashes: []u64) -> [dynamic][dynamic]int {
	groups: [dynamic][dynamic]int
	done := make([]bool, len(hashes))
	defer delete(done)
	for i in 0 ..< len(hashes) {
		if done[i] {continue}
		group: [dynamic]int
		for j in i ..< len(hashes) {
			if !done[j] && hashes[j] == hashes[i] {
				append(&group, j)
				done[j] = true
			}
		}
		append(&groups, group)
	}
	return groups
}

// ------------------------------------------------------------------ chorus

Chorus_Case :: struct {
	name:     string,
	type:     int,
	delay:    int,
	depth:    int,
	rate:     int,
	feedback: int,
	level:    int,
}

// A stereo source with different content in the two channels: two detuned saw
// layers panned apart, so a chorus that mixes the channels or reads the wrong one
// cannot hide behind a mono input.
chorus_source_patch :: proc() -> cpatch.Patch {
	p := arch_sine_patch()
	set_param(&p, 0, arch_stored_for_id(0, 1))
	set_param(&p, 5, 0)
	set_param(&p, 73, 1)
	set_param(&p, 93, 2)
	set_param(&p, 75, 40)
	set_param(&p, 84, 127)
	set_param(&p, 65, 0)
	switch g_chorus_source {
	case 1: // one saw, panned off centre: the two channels are scaled copies
		set_param(&p, 73, 0)
		set_param(&p, 90, 40)
	case 2: // two unison sines, different content in each channel and nothing broadband
		set_param(&p, 0, 0)
	}
	return p
}

// Which source the chorus probe plays: 0 two detuned saws, 1 one panned saw, 2 two
// unison sines. Set by `--what`.
g_chorus_source: int

// How deeply `b` cancels against `a` over [from, to), in dB (0 is none, lower is
// closer), and `b`'s level over `a`'s in dB.
null_and_level :: proc(a, b: []f32, from, to: int) -> (null_db, level_db: f64) {
	residual, power_a, power_b := 0.0, 0.0, 0.0
	for i in max(from, 0) ..< min(to, min(len(a), len(b))) {
		d := f64(a[i]) - f64(b[i])
		residual += d * d
		power_a += f64(a[i]) * f64(a[i])
		power_b += f64(b[i]) * f64(b[i])
	}
	null_db = 10.0 * math.log10(max(residual, 1.0e-30) / max(power_a, 1.0e-30))
	level_db = 10.0 * math.log10(max(power_b, 1.0e-30) / max(power_a, 1.0e-30))
	return
}

// The chorus's wet in both engines, one channel at a time, by rendering the same
// patch with the section on and off and subtracting.
chorus_wet :: proc(dll: string, c: ^Arch_Chunk, cs: Chorus_Case, events: []Script_Event) -> (wet: [2][2][]f32) {
	renders: [2][2][]f32
	for state in 0 ..< 2 {
		p := chorus_source_patch()
		set_param(&p, 66, state)
		set_param(&p, 64, cs.type)
		set_param(&p, 52, cs.delay)
		set_param(&p, 53, cs.depth)
		set_param(&p, 54, cs.rate)
		set_param(&p, 55, cs.feedback)
		set_param(&p, 56, cs.level)
		ref, ours := arch_render(dll, &p, c, events, 2.6)
		renders[state] = {ref, ours}
	}
	for side in 0 ..< 2 {
		for ch in 0 ..< 2 {
			on := script_channel(renders[1][side], ch)
			off := script_channel(renders[0][side], ch)
			for i in 0 ..< len(on) {on[i] -= off[i]}
			delete(off)
			wet[side][ch] = on
		}
	}
	for state in 0 ..< 2 {
		arch_free_pair(renders[state][0], renders[state][1])
	}
	return
}

// `s1probe arch chorus [--values <case indices>]`. Reports, per channel, how deeply
// the two engines' wets cancel (0 dB is no cancellation) and ours over the
// reference's in level. The first row is the floor: the same measure on the dry
// source, which is as deep as any wet can cancel.
cmd_arch_chorus :: proc(dll: string, c: ^Arch_Chunk, o: ^Arch_Options) {
	cases := [?]Chorus_Case {
		{"type 1, centre", 1, 64, 64, 64, 64, 127},
		{"type 2, centre", 2, 64, 64, 64, 64, 127},
		{"type 4, centre", 4, 64, 64, 64, 64, 127},
		{"type 1, deep slow", 1, 100, 100, 40, 64, 127},
		{"type 2, deep slow", 2, 100, 100, 40, 64, 127},
		{"type 4, deep slow", 4, 100, 100, 40, 64, 127},
		{"type 2, half level", 2, 64, 64, 64, 64, 64},
		{"type 2, feedback +50%", 2, 64, 64, 64, 96, 127},
		{"type 2, feedback -99%", 2, 64, 64, 64, 0, 127},
		{"type 2, flanger", 2, 8, 90, 80, 100, 127},
		{"type 4, flanger", 4, 8, 90, 80, 100, 127},
		{"type 2, fast and deep", 2, 100, 127, 120, 64, 127},
		{"type 4, fast and deep", 4, 100, 127, 120, 64, 127},
		{"type 2, no depth", 2, 64, 0, 64, 64, 127},
		{"type 2, rate 0", 2, 100, 127, 0, 64, 127},
		{"type 2, rate 1", 2, 100, 127, 1, 64, 127},
		{"type 2, rate 8", 2, 100, 127, 8, 64, 127},
		{"type 1, delay 20", 1, 20, 127, 40, 64, 127},
		{"type 2, delay 60", 2, 60, 80, 40, 64, 127},
	}
	events := []Script_Event{script_on(0, 60), script_off(2.5, 60)}
	from, to := ms_to_frame(500), ms_to_frame(2400)
	g_chorus_source = o.what == "pan" ? 1 : (o.what == "sine" ? 2 : 0)

	fmt.println("arch chorus: note 60 through a source chosen by --what (default two detuned saws, `pan` one panned saw, `sine` two unison sines); wet = chorus on minus off")
	fmt.println("  null: how deeply the two engines' wets cancel (dB, lower is closer); level: ours over reference (dB)")
	fmt.println()
	fmt.println("  case                       |  null L   null R | level L  level R")

	dry := chorus_source_patch()
	set_param(&dry, 66, 0)
	dref, dours := arch_render(dll, &dry, c, events, 2.6)
	defer arch_free_pair(dref, dours)
	floor: [2]f64
	for ch in 0 ..< 2 {
		a := script_channel(dref, ch)
		b := script_channel(dours, ch)
		floor[ch], _ = null_and_level(a, b, from, to)
		delete(a)
		delete(b)
	}
	fmt.printfln("  %-26v | %7v  %7v |", "(dry source, no chorus)", sdec1(floor[0], 7), sdec1(floor[1], 7))

	for cs, index in cases {
		if len(o.values) > 0 {
			listed := false
			for v in o.values {if v == index {listed = true}}
			if !listed {continue}
		}
		wet := chorus_wet(dll, c, cs, events)
		nulls, levels: [2]f64
		for ch in 0 ..< 2 {
			nulls[ch], levels[ch] = null_and_level(wet[0][ch], wet[1][ch], from, to)
		}
		fmt.printfln(
			"  %-26v | %7v  %7v | %7v  %7v",
			cs.name, sdec1(nulls[0], 7), sdec1(nulls[1], 7), sdec1(levels[0], 7), sdec1(levels[1], 7),
		)
		if len(o.values) > 0 {
			fmt.printf("      left null by window (s):")
			for w in 0 ..< 6 {
				a, b := ms_to_frame(300 + f64(w) * 350), ms_to_frame(650 + f64(w) * 350)
				n, _ := null_and_level(wet[0][0], wet[1][0], a, b)
				fmt.printf("  %.2f-%.2f %v", 0.3 + f64(w) * 0.35, 0.65 + f64(w) * 0.35, sdec1(n, 6))
			}
			fmt.println()
		}
		for side in 0 ..< 2 {
			for ch in 0 ..< 2 {delete(wet[side][ch])}
		}
	}
}

// ------------------------------------------------------------------ entry

cmd_arch :: proc(dll: string, args: []string) {
	if len(args) < 1 {usage()}
	o: Arch_Options
	defer delete(o.values)
	sub := args[0]
	i := 1
	for i < len(args) {
		need :: proc(args: []string, i: int) -> string {
			if i + 1 >= len(args) {usage()}
			return args[i + 1]
		}
		switch args[i] {
		case "--wav":
			o.wav = need(args, i)
			i += 2
		case "--what":
			o.what = need(args, i)
			i += 2
		case "--case":
			o.case_, _ = strconv.parse_int(need(args, i))
			i += 2
		case "--child":
			o.child = true
			i += 1
		case "--values":
			for f in strings.split(need(args, i), ",", context.temp_allocator) {
				if v, ok := strconv.parse_int(strings.trim_space(f)); ok {append(&o.values, v)}
			}
			i += 2
		case:
			usage()
		}
	}
	c: Arch_Chunk
	c.pristine, c.work = probe_open_chunk(dll)
	defer delete(c.pristine)
	defer delete(c.work)
	switch sub {
	case "fxorder": cmd_arch_fxorder(dll, &c, &o)
	case "pan": cmd_arch_pan(dll, &c, &o)
	case "lfocutoff": cmd_arch_lfocutoff(dll, &c, &o)
	case "lfophase": cmd_arch_lfophase(dll, &c, &o)
	case "envshape": cmd_arch_envshape(dll, &c, &o)
	case "envlaw": cmd_arch_envlaw(dll, &c, &o)
	case "ramp": cmd_arch_ramp(dll, &c, &o)
	case "clip": cmd_arch_clip(dll, &c, &o)
	case "rate": cmd_arch_rate(dll, &c, &o)
	case "osc": cmd_arch_osc(dll, &c, &o)
	case "voices": cmd_arch_voices(dll, &c, &o)
	case "eq": cmd_arch_eq(dll, &c, &o)
	case "filtertype": cmd_arch_filtertype(dll, &c, &o)
	case "tone": cmd_arch_tone(dll, &c, &o)
	case "hits": cmd_arch_hits(dll, &c, &o)
	case "arp": cmd_arch_arp(dll, &c, &o)
	case "chorus": cmd_arch_chorus(dll, &c, &o)
	case: usage()
	}
}
