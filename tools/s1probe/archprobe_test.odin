package s1probe

import "core:math"
import "core:testing"

import sengine "../../src/engine"

// The `s1probe arch` instruments, each fed a signal whose answer is known by
// construction, so a reading in docs/synth1-architecture-evidence.md says
// something about the engine it was taken from rather than about the
// instrument. None of these builds its input with the code that reads it.

// ------------------------------------------------------------------ envshape

@(test)
test_decay_shape_reads_an_exponential_as_a_straight_line_in_db :: proc(t: ^testing.T) {
	// 0.1 dB a frame for 600 frames: 60 dB, a constant slope.
	db := make([]f64, 600)
	defer delete(db)
	for i in 0 ..< len(db) {db[i] = -0.1 * f64(i)}
	s := decay_shape(db, 0, 1, 3, 45)
	testing.expect(t, s.ok)
	testing.expectf(t, abs(s.ratio - 1) < 1.0e-6, "late/early slope %v, want 1", s.ratio)
	testing.expectf(t, s.db_line_rms < 1.0e-9, "dB-line residual %v, want 0", s.db_line_rms)
	testing.expectf(t, s.amp_line_rms > 0.05, "amp-line residual %v, an exponential is not a line in amplitude", s.amp_line_rms)
}

@(test)
test_decay_shape_reads_a_linear_ramp_as_a_straight_line_in_amplitude :: proc(t: ^testing.T) {
	// Amplitude falls by the same amount every frame and reaches zero at 1000.
	db := make([]f64, 1000)
	defer delete(db)
	for i in 0 ..< len(db) {db[i] = 20 * math.log10(max(1 - f64(i) / 1000, 1.0e-9))}
	s := decay_shape(db, 0, 1, 3, 45)
	testing.expect(t, s.ok)
	testing.expectf(t, s.amp_line_rms < 1.0e-6, "amp-line residual %v, want 0", s.amp_line_rms)
	testing.expectf(t, s.ratio > 3, "late/early slope %v, a linear ramp steepens in dB", s.ratio)
	testing.expectf(t, s.db_line_rms > 1, "dB-line residual %v", s.db_line_rms)
}

// ------------------------------------------------------------------ rate

@(test)
test_grid_reading_finds_a_gain_held_for_32_samples :: proc(t: ^testing.T) {
	n := 4000
	g := make([]f64, n)
	defer delete(g)
	valid := make([]bool, n)
	defer delete(valid)
	for i in 0 ..< n {
		// A smooth law sampled every 32 samples from sample 7 and held.
		k := (i - 7) / 32 * 32 + 7
		g[i] = math.exp(-f64(max(k, 0)) / 900)
		valid[i] = true
	}
	r := grid_reading(g, valid, 20)
	testing.expect_value(t, r.spacing, 32)
	testing.expectf(t, r.on_grid > 0.99, "on-grid share %v", r.on_grid)
	testing.expect_value(t, r.phase, 7) // each new value first appears at 7 mod 32
	testing.expectf(t, abs(r.zero_d1 - (1 - 1.0 / 32)) < 0.01, "zero first differences %v", r.zero_d1)
}

@(test)
test_grid_reading_finds_no_grid_in_a_per_sample_law :: proc(t: ^testing.T) {
	n := 4000
	g := make([]f64, n)
	defer delete(g)
	valid := make([]bool, n)
	defer delete(valid)
	for i in 0 ..< n {
		g[i] = math.exp(-f64(i) / 900)
		valid[i] = true
	}
	r := grid_reading(g, valid, 20)
	testing.expectf(t, r.spikes < 3, "%v spikes in a smooth law", r.spikes)
	testing.expect_value(t, r.spacing, 0)
	testing.expectf(t, r.zero_d1 < 0.01, "zero first differences %v", r.zero_d1)
}

// ------------------------------------------------------------------ ramp

@(test)
test_step_crossing_times_a_linear_ramp :: proc(t: ^testing.T) {
	// Flat at 3 until index 100, then a linear ramp to 7 over 100 points.
	series := make([]f64, 300)
	defer delete(series)
	for i in 0 ..< len(series) {series[i] = 3 + 4 * clamp(f64(i - 100) / 100, 0, 1)}
	s := step_levels(series, 100, 4, 40, 60)
	testing.expect(t, s.ok)
	t10, ok10 := step_crossing(series, s, 100, 4, 0.1)
	t90, ok90 := step_crossing(series, s, 100, 4, 0.9)
	testing.expect(t, ok10 && ok90)
	testing.expectf(t, abs(t10 - 10) < 1.0e-9 && abs(t90 - 90) < 1.0e-9, "t10 %v, t90 %v; want 10, 90", t10, t90)
	testing.expectf(t, abs(step_progress(s, series[150]) - 0.5) < 1.0e-9, "mid-ramp progress %v", step_progress(s, series[150]))
}

@(test)
test_step_crossing_reports_a_series_that_never_crosses :: proc(t: ^testing.T) {
	// The settled level is reached before the guard ends: there is no
	// crossing to time, and a made-up time would be worse than none.
	series := make([]f64, 300)
	defer delete(series)
	for i in 0 ..< len(series) {series[i] = i < 90 ? 0 : 1}
	s := step_levels(series, 100, 4, 40, 60)
	_, ok := step_crossing(series, s, 100, 4, 0.5)
	testing.expect(t, !ok)
	flat := make([]f64, 300)
	defer delete(flat)
	testing.expect(t, !step_levels(flat, 100, 4, 40, 60).ok)
}

// ------------------------------------------------------------------ lfophase

@(test)
test_onset_phase_reads_a_falling_saw :: proc(t: ^testing.T) {
	// A falling saw of period 50 frames that starts its cycle at frame 20.
	env := make([]f64, 400)
	defer delete(env)
	for i in 0 ..< len(env) {
		ph := f64(i - 20) / 50
		env[i] = 1 - (ph - math.floor(ph))
	}
	jumps := saw_jumps(env, 1, len(env))
	defer delete(jumps)
	testing.expectf(t, len(jumps) == 8 && jumps[0] == 20 && jumps[1] == 70, "jumps %v", jumps[:])
	// An onset 10 frames into a cycle is a fifth of the way through it.
	testing.expectf(t, abs(onset_phase(80, 120, 50) - 0.2) < 1.0e-9, "phase %v, want 0.2", onset_phase(80, 120, 50))
	testing.expectf(t, abs(onset_phase(70, 70, 50)) < 1.0e-9, "an onset on the jump is phase 0, got %v", onset_phase(70, 70, 50))
}

// ------------------------------------------------------------------ pan

@(test)
test_pan_predictions_separate_additive_from_product :: proc(t: ^testing.T) {
	// Two controls half left: added, the position is hard left; multiplied,
	// each halves the right channel.
	half_left := [2]f64{1, 0.5}
	al, ar := pan_additive([]f64{pan_position(half_left[0], half_left[1]), pan_position(half_left[0], half_left[1])})
	testing.expectf(t, abs(al - 1) < 1.0e-12 && abs(ar) < 1.0e-12, "additive %v %v, want 1 0", al, ar)
	ml, mr := pan_product([][2]f64{half_left, half_left})
	testing.expectf(t, abs(ml - 1) < 1.0e-12 && abs(mr - 0.25) < 1.0e-12, "product %v %v, want 1 0.25", ml, mr)
	// The product takes gains as measured, including ones off the law.
	ml, mr = pan_product([][2]f64{{1.3, 0.4}, half_left})
	testing.expectf(t, abs(ml - 1.3) < 1.0e-12 && abs(mr - 0.2) < 1.0e-12, "product %v %v, want 1.3 0.2", ml, mr)
}

@(test)
test_pan_on_law_rejects_a_channel_above_unity :: proc(t: ^testing.T) {
	testing.expect(t, pan_on_law(1.0, 0.5))
	testing.expect(t, pan_on_law(0.0, 1.002))
	testing.expect(t, !pan_on_law(1.292, 0.423))
	testing.expect(t, !pan_on_law(0.7, 0.7))
}

// ------------------------------------------------------------------ lfocutoff

@(test)
test_match_state_interpolates_between_calibrated_states :: proc(t: ^testing.T) {
	// Profiles whose every band moves 1 dB per state, on a grid of 10, 12,
	// 14, 16: a profile built for state 13.5 sits between two grid points and
	// is read there, not snapped to 14.
	states := []f64{10, 12, 14, 16}
	profiles := make([][]f64, len(states))
	defer {
		for p in profiles {delete(p)}
		delete(profiles)
	}
	for s, i in states {
		profiles[i] = make([]f64, 8)
		for b in 0 ..< 8 {profiles[i][b] = -40 + f64(b) - s}
	}
	query := make([]f64, 8)
	defer delete(query)
	for b in 0 ..< 8 {query[b] = -40 + f64(b) - 13.5}
	state, distance := match_state(query, states, profiles)
	testing.expectf(t, abs(state - 13.5) < 0.01, "state %v, want 13.5", state)
	testing.expectf(t, abs(distance - 0.25) < 1.0e-9, "distance %v at the nearest grid point", distance)
}

// ------------------------------------------------------------------ eq

@(test)
test_fit_peak_recovers_a_known_q :: proc(t: ^testing.T) {
	points := arch_points()
	defer delete(points)
	// A peak written out directly from the RBJ cookbook, not through the
	// engine's coefficient code that `fit_peak` searches with.
	db := make([]f64, len(points))
	defer delete(db)
	gain_db, q, f0 := 12.0, 1.4, 1000.0
	a := math.pow(10.0, gain_db / 40)
	w0 := 2 * math.PI * f0 / f64(SAMPLE_RATE)
	alpha := math.sin(w0) / (2 * q)
	b0, b1, b2 := 1 + alpha * a, -2 * math.cos(w0), 1 - alpha * a
	a0, a1, a2 := 1 + alpha / a, -2 * math.cos(w0), 1 - alpha / a
	for hz, i in points {
		w := 2 * math.PI * hz / f64(SAMPLE_RATE)
		nr := b0 + b1 * math.cos(w) + b2 * math.cos(2 * w)
		ni := -b1 * math.sin(w) - b2 * math.sin(2 * w)
		dr := a0 + a1 * math.cos(w) + a2 * math.cos(2 * w)
		di := -a1 * math.sin(w) - a2 * math.sin(2 * w)
		db[i] = 10 * math.log10((nr * nr + ni * ni) / (dr * dr + di * di))
	}
	f := fit_peak(points[:], db)
	testing.expectf(t, abs(f.peak_db - gain_db) < 0.5, "peak %v dB", f.peak_db)
	testing.expectf(t, abs(f.q - q) / q < 0.05, "fitted Q %v, want %v", f.q, q)
	testing.expectf(t, f.residual < 0.3, "residual %v dB", f.residual)
}

@(test)
test_arch_transfer_reads_a_known_gain_from_noise :: proc(t: ^testing.T) {
	n := 48000
	x := make([]f32, n)
	defer delete(x)
	y := make([]f32, n)
	defer delete(y)
	// A fixed linear congruential sequence: broadband, repeatable.
	state := u32(7)
	for i in 0 ..< n {
		state = state * 1664525 + 1013904223
		x[i] = f32(state >> 8) / f32(1 << 23) - 1
		y[i] = 0.5 * x[i]
	}
	h := arch_transfer(x, y, 0, n, 4096)
	defer delete(h)
	bin_hz := f64(SAMPLE_RATE) / 4096
	for hz in ([]f64{100, 1000, 10000}) {
		got := arch_transfer_db_at(h, bin_hz, hz)
		testing.expectf(t, abs(got - 20 * math.log10(f64(0.5))) < 1.0e-6, "transfer at %v Hz: %v dB, want -6.02", hz, got)
	}
}

// ------------------------------------------------------------------ script events

@(test)
test_script_set_param_reaches_this_engine_as_a_host_edit :: proc(t: ^testing.T) {
	ev := script_set(0.5, 19, 70)
	defer delete(ev.label)
	testing.expect_value(t, ev.status, SCRIPT_SET_PARAM)
	testing.expect_value(t, ev.frame, script_frame(0.5))
	testing.expect_value(t, ev.label, "set 19=70")

	eng: sengine.Engine
	sengine.engine_load_patch(&eng, arch_sine_patch(), f32(SAMPLE_RATE))
	defer sengine.engine_destroy(&eng)
	ours_apply_event(&eng, ev)
	testing.expect_value(t, sengine.engine_patch_value(&eng, 19), 70)
}

@(test)
test_script_set_param_changes_the_render_only_after_its_frame :: proc(t: ^testing.T) {
	// A note far above a closed low pass; opening the cutoff mid-note raises
	// its level from the event on and leaves everything before it alone.
	p := arch_sine_patch()
	set_param(&p, 14, arch_stored_for_id(14, 0))
	set_param(&p, 19, 30)
	on := script_on(0, 108)
	defer delete(on.label)
	set := script_set(0.5, 19, 70)
	defer delete(set.label)
	plain := render_ours_script(p, []Script_Event{on}, script_frame(0.8))
	defer delete(plain)
	edited := render_ours_script(p, []Script_Event{on, set}, script_frame(0.8))
	defer delete(edited)
	at := set.frame * 2
	for i in 0 ..< at {
		if plain[i] != edited[i] {
			testing.expectf(t, false, "sample %v differs before the edit", i / 2)
			break
		}
	}
	mid := script_channel(edited, -1)
	defer delete(mid)
	before := window_db(mid, set.frame - 4800, set.frame)
	after := window_db(mid, set.frame + 4800, set.frame + 9600)
	testing.expectf(t, after - before > 10, "level %v dB before the edit, %v after", before, after)
}

// ------------------------------------------------------------------ lfophase, two notes

@(test)
test_line_envelope_separates_two_notes_an_octave_apart :: proc(t: ^testing.T) {
	n := 24000
	x := make([]f32, n)
	defer delete(x)
	for i in 0 ..< n {
		s := f64(i) / f64(SAMPLE_RATE)
		x[i] = f32(0.3 * math.sin(2 * math.PI * note_hz(60) * s) + 0.7 * math.sin(2 * math.PI * note_hz(72) * s + 1))
	}
	for note, k in ([2]int{60, 72}) {
		env := line_envelope(x, note_hz(f64(note)), LINE_WINDOW, LINE_HOP)
		defer delete(env)
		want := k == 0 ? 0.3 : 0.7
		for v, f in env {
			if abs(v - want) > 0.01 * want {
				testing.expectf(t, false, "note %v frame %v reads %v, want %v", note, f, v, want)
				break
			}
		}
	}
}

@(test)
test_rise_times_places_an_amplitude_jump :: proc(t: ^testing.T) {
	// A sawtooth-like amplitude: falls linearly, jumps back up at 10000 and
	// 30000 samples.
	n := 48000
	x := make([]f32, n)
	defer delete(x)
	for i in 0 ..< n {
		cycle := i < 10000 ? f64(i) / 20000 + 0.5 : f64((i - 10000) % 20000) / 20000
		x[i] = f32((1 - cycle) * math.sin(2 * math.PI * note_hz(60) * f64(i) / f64(SAMPLE_RATE)))
	}
	env := line_envelope(x, note_hz(60), LINE_WINDOW, LINE_HOP)
	defer delete(env)
	rises := rise_times(env, LINE_WINDOW / LINE_HOP, LINE_WINDOW, LINE_HOP)
	defer delete(rises)
	testing.expectf(t, len(rises) == 2, "rises %v", rises[:])
	if len(rises) == 2 {
		testing.expectf(t, abs(rises[0] - 10000) <= LINE_HOP && abs(rises[1] - 30000) <= LINE_HOP,
			"rises at %v, want 10000 and 30000 within a hop", rises[:])
	}
}
