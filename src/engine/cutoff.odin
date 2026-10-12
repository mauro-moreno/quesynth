package engine

import "core:math"

// The filter cutoff as the reference keeps it: a position on a 1024-step
// exponential axis, not a frequency.
//
// Everything that moves the corner -- the knob, keyboard tracking, the filter
// envelope, the LFO -- moves that position, and only the sum is turned into a
// frequency. That is observable, and it is why the earlier model, which
// multiplied a measured frequency by a number of octaves per source, was wrong
// in two places: a cutoff LFO opens the filter by a fraction of the travel left
// above the knob rather than by a fixed number of octaves, and keyboard
// tracking is not linear in the knob.
//
// Position 0 is 15 Hz and position 1024 is 16 kHz, so one step is
// ln(16000/15)/1024 of a natural-log unit, about 12 cents.
// Parameter 19 has 128 states, and parameter 21 moves the envelope's endpoint by
// two of them per step: 16 steps of the axis, 0.157 octaves.
FILTER_TABLE_SIZE :: 128
FILTER_ENV_CENTRE_STATE :: 63
FILTER_ENV_OCTAVES_PER_STEP :: f32(0.157170)

FILTER_INDEX_STEPS :: f32(1024)
FILTER_INDEX_MAX :: f32(1023)
FILTER_INDEX_LOW_HZ :: f32(15)
FILTER_INDEX_HIGH_HZ :: f32(16000)

// How long a change of knob, envelope amount or tracking takes to reach the
// filter: fifty milliseconds, linear in position, whatever the size of the step.
// A quarter-step takes as long as a full sweep, so this is a duration and not a
// rate, and it is linear rather than the one-pole the engine used before, which
// covered 10% of the way in the first 2 ms and had barely finished at 10.
FILTER_RAMP_SECONDS :: f32(0.05)

// The knob's own position. The state is a stored 0..127 and the axis has 1023
// usable steps, so the knob does not land on a multiple of eight.
filter_knob_index :: proc "contextless" (state: f32) -> f32 {
	top := f32(FILTER_TABLE_SIZE - 1)
	return math.floor(clamp(state, 0, top) * FILTER_INDEX_MAX / top)
}

// The fractional stored state a position corresponds to, for the measured
// surfaces that are still indexed by state.
filter_state_of_index :: proc "contextless" (index: f32) -> f32 {
	return clamp(index, 0, FILTER_INDEX_MAX) * f32(FILTER_TABLE_SIZE - 1) / FILTER_INDEX_MAX
}

// Corner frequency of a position on the axis.
filter_index_hz :: proc "contextless" (index: f32) -> f32 {
	return FILTER_INDEX_LOW_HZ * math.pow(FILTER_INDEX_HIGH_HZ / FILTER_INDEX_LOW_HZ, index / FILTER_INDEX_STEPS)
}

// Keyboard tracking moves the position by `(1 + amount)^((note - 48) / 12)` in
// frequency, so a tracking knob at half travel is not half an octave per octave
// but log2(1.5) = 0.585 of one, and full travel is exactly one. The result is
// held to the ends of the axis, which is where the corner stops however high
// the note.
filter_track_shift :: proc "contextless" (knob, amount, note: f32) -> f32 {
	if amount <= 0 {
		return 0
	}
	ratio_log := (note - FILTER_TRACK_REFERENCE_NOTE) / 12.0 * math.ln(1.0 + amount)
	axis_span := math.ln(FILTER_INDEX_HIGH_HZ / FILTER_INDEX_LOW_HZ)
	moved := math.floor(knob + FILTER_INDEX_STEPS * ratio_log / axis_span)
	return clamp(moved, 0, FILTER_INDEX_STEPS) - knob
}

// The envelope's share of the travel. The amount is held to the room the knob
// and tracking leave on each side before the envelope level is applied, so a
// large amount near either end reaches the end of the axis exactly when the
// envelope is at full level and not before.
filter_env_shift :: proc "contextless" (base, amount_steps, level: f32) -> f32 {
	held := clamp(amount_steps, -base, FILTER_INDEX_STEPS - base)
	return held * level
}

// A modulation depth `m`, in steps, applied last: upward it takes the same
// fraction of what is left above the position, downward of what is below it.
// Depth 1024 therefore takes the corner to the top from anywhere.
filter_modulate_index :: proc "contextless" (index, modulation: f32) -> f32 {
	room := modulation > 0 ? FILTER_INDEX_STEPS - index : index
	moved := math.trunc(index + math.trunc(room * modulation / FILTER_INDEX_STEPS))
	return clamp(moved, 0, FILTER_INDEX_MAX)
}

// A voice's cutoff position, ramped.
//
// The ramp restarts when the knob, the envelope amount or the tracking amount
// is edited, from wherever the position is then, and runs toward the *current*
// target, so an LFO or envelope that is still moving is followed rather than
// frozen at the value it had when the edit arrived. After the ramp the position
// is the target outright.
Cutoff_Ramp :: struct {
	current:   f32,
	start:     f32,
	position:  int,
	primed:    bool,
	knob:      f32,
	env_steps: f32,
	tracking:  f32,
}

cutoff_ramp_samples :: proc "contextless" (sample_rate: f32) -> int {
	return max(1, int(sample_rate * FILTER_RAMP_SECONDS))
}

// A fresh note starts at its target. Only a change heard while the note sounds
// is ramped.
cutoff_ramp_reset :: proc "contextless" (r: ^Cutoff_Ramp) {
	r.primed = false
}

cutoff_ramp_step :: proc "contextless" (
	r: ^Cutoff_Ramp,
	target, knob, env_steps, tracking: f32,
	length: int,
) -> f32 {
	if !r.primed {
		r^ = {
			current   = target,
			start     = target,
			position  = length,
			primed    = true,
			knob      = knob,
			env_steps = env_steps,
			tracking  = tracking,
		}
		return target
	}

	if knob != r.knob || env_steps != r.env_steps || tracking != r.tracking {
		r.start = r.current
		r.position = 0
		r.knob = knob
		r.env_steps = env_steps
		r.tracking = tracking
	}

	if r.position >= length || target == r.current {
		r.current = target
	} else {
		r.current = r.start + math.trunc((target - r.start) * f32(r.position) / f32(length))
	}
	if r.position < length {
		r.position += 1
	}
	return r.current
}
