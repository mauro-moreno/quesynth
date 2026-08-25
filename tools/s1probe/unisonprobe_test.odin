package s1probe

import "core:math"
import "core:testing"

@(test)
test_unison_spectral_peaks_resolves_close_signed_layers :: proc(t: ^testing.T) {
	n := 65536
	signal := make([]f32, n)
	defer delete(signal)
	want := []f64{995.0, 998.0, 1002.0, 1005.0}
	for i in 0 ..< n {
		x := 0.0
		for hz in want {
			x += math.sin(2.0 * math.PI * hz * f64(i) / 48000.0)
		}
		signal[i] = f32(x)
	}
	got, ok := unison_spectral_peaks(signal, 48000.0, 1000.0, 10.0, 4, n)
	defer delete(got)
	testing.expect(t, ok, "the four close tones were not resolved")
	if !ok {return}
	for hz, i in got {
		testing.expectf(t, abs(hz - want[i]) < 0.08,
			"peak %d read %.4f Hz instead of %.4f Hz", i, hz, want[i])
	}
}

@(test)
test_unison_phasor_preserves_signed_phase_difference :: proc(t: ^testing.T) {
	n := SAMPLE_RATE
	old_hold := g_hold_frames
	g_hold_frames = n
	defer {g_hold_frames = old_hold}
	a := make([]f32, n * 2)
	defer delete(a)
	b := make([]f32, n * 2)
	defer delete(b)
	hz := 1000.0
	shift := 0.125
	for i in 0 ..< n {
		x := f32(math.sin(2.0 * math.PI * hz * f64(i) / f64(SAMPLE_RATE)))
		y := f32(math.sin(2.0 * math.PI * (hz * f64(i) / f64(SAMPLE_RATE) + shift)))
		a[i * 2], a[i * 2 + 1] = x, x
		b[i * 2], b[i * 2 + 1] = y, y
	}
	origin := unison_phasor(a, hz)
	moved := unison_phasor(b, hz)
	relative := Unison_Phasor{
		re = moved.re * origin.re + moved.im * origin.im,
		im = moved.im * origin.re - moved.re * origin.im,
		ok = true,
	}
	testing.expect(t, origin.ok && moved.ok, "phase projection failed")
	testing.expectf(t, abs(unison_turns(relative) - shift) < 0.00001,
		"phase difference read %.6f turns instead of %.6f", unison_turns(relative), shift)
}
