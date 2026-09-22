"""Shared labels and defaults for the MIDI-GPT dashboard UI."""

VALIDATION_LABELS = ["Off", "Novelty", "Silence", "Novelty + Silence"]
NOTE_DURATION_LABELS = ["Any", "32nd", "16th", "8th", "Quarter", "Half", "Whole"]
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
SCALE_LABELS = ["chromatic", "major", "natural_minor", "harmonic_minor", "melodic_minor", "dorian", "phrygian", "lydian", "mixolydian", "locrian", "major_pentatonic", "minor_pentatonic", "blues", "whole_tone"]

DEFAULT_TRACK_SETTINGS = {
    "density": 0,
    "min_polyphony_q": 0,
    "max_polyphony_q": 0,
    "min_note_duration_q": 0,
    "max_note_duration_q": 0,
    "key_signature": 0,
    "pitch_range": 0,
    "silence_proportion": 0,
    "autoregressive": 0,
    "ignore": 0,
    "density_limit_enabled": False,
    "polyphony_limit_enabled": False,
    "pitch_mask_mode": 0,
    "pitch_mask_scale": "major",
    "pitch_mask_root": 0,
    "pitch_mask_classes": 0,
    "pitch_shape_mode": 0,
    "pitch_shape_min": 48,
    "pitch_shape_max": 72,
    "pitch_shape_mean": 60,
    "pitch_shape_std": 8.0,
    "remix_enabled": 0,
    "remix_amount": 0.3,
    "remix_mode": 0,
}

# Per-model-type constraints that GET /info doesn't expose (checked
# against a live yellow_medium server on 2026-09-22 -- its capabilities.*
# there are flat, model-wide booleans: nothing about which model_dim
# values are actually valid for a checkpoint, and nothing about which
# per-track attribute a control maps to actually applies to a drum vs.
# melodic track). Filled in for "yellow" from values already known;
# other model types are left out on purpose -- a model_type missing here
# means "no constraint known, don't restrict the UI" (see
# MODEL_DIM_OPTIONS.get(model_type) / TRACK_ATTRIBUTE_SUPPORT.get(model_type)
# both returning None at the call sites), not "this model has no limits."

# Valid "Context Length (Bars)" (config.model_dim) values, if the model
# only accepts specific ones rather than any value in the slider's range.
MODEL_DIM_OPTIONS = {
    "yellow": [4, 8],
}

# Which Core-tab per-track attribute controls actually take effect for a
# track's role under a given model. MIDI-GPT Generate.py's
# _compute_track_prompt_fields() already silently drops anything outside
# this for "yellow" (e.g. a density limit set on a melodic track is just
# never sent) -- this is the same mapping, used to hide the control in the
# UI instead of showing one that quietly does nothing.
TRACK_ATTRIBUTE_SUPPORT = {
    "yellow": {
        "drum": {"density"},
        "melodic": {"polyphony", "duration"},
    },
}

DEFAULT_GLOBAL_SETTINGS = {
    "temperature": 1.0,
    "model_dim": 4,
    "bars_per_step": 1,
    "tracks_per_step": 1,
    "polyphony_hard_limit": 0,
    "density_hard_limit": 0,
    "max_attempts": 3,
    "temp_escalation": 1.0,
    "top_p": 1.0,
    "top_k": 0,
    "mask_p": 0.0,
    "mask_k": 0,
    "seed": -1,
    "checks_idx": 3,
    "shuffle": 0,
    "num_candidates": 1,
    "manual_seed": False,
    "polyphony_limit_enabled": False,
    "density_limit_enabled": False,
    "temp_escalation_enabled": False,
    "top_p_enabled": False,
    "top_k_enabled": False,
    "mask_p_enabled": False,
    "mask_k_enabled": False,
}
