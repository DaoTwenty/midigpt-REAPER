"""Tests for the dashboard's pure settings logic (midigpt_dashboard/constants.py)."""

import pytest

from midigpt_dashboard.constants import (
    ENABLE_START_VALUES,
    TRACK_ATTRIBUTE_SUPPORT,
    value_when_enabled,
)
from midi_extraction import get_instrument_from_track_name


class TestValueWhenEnabled:
    @pytest.mark.parametrize("key", [k for k in ENABLE_START_VALUES if k != "top_p"])
    def test_off_value_zero_gets_start_value(self, key):
        assert value_when_enabled(key, 0) == ENABLE_START_VALUES[key]

    def test_top_p_off_value_is_one(self):
        assert value_when_enabled("top_p", 1.0) == ENABLE_START_VALUES["top_p"]

    def test_user_value_is_kept(self):
        assert value_when_enabled("top_k", 7) == 7
        assert value_when_enabled("top_p", 0.5) == 0.5

    def test_start_values_are_not_off_values(self):
        # A start value equal to the off value would leave the box meaning "off".
        for key, start in ENABLE_START_VALUES.items():
            assert start != (1.0 if key == "top_p" else 0), key

    def test_unknown_key_is_unchanged(self):
        assert value_when_enabled("temperature", 0) == 0


class TestTrackAttributeSupport:
    @pytest.mark.parametrize("model_type", ["yellow", "prism", "expressive"])
    def test_every_model_hides_controls_by_role(self, model_type):
        # Mirrors the role checks in MIDI-GPT Generate.py's
        # _compute_track_prompt_fields(), which apply to every model type.
        support = TRACK_ATTRIBUTE_SUPPORT[model_type]
        assert support["drum"] == {"density"}
        assert support["melodic"] == {"polyphony", "duration"}


class TestDashboardDrumNames:
    """The dashboard's _is_drum_track() uses get_instrument_from_track_name(),
    so keyword-named drum tracks get drum controls, not just "drums"."""

    @pytest.mark.parametrize("name", ["drums", "Kick", "Snare Top", "Hi-Hat", "Toms"])
    def test_drum_names(self, name):
        assert get_instrument_from_track_name(name) == 128

    @pytest.mark.parametrize("name", ["Bass", "Piano", "Track 1"])
    def test_non_drum_names(self, name):
        assert get_instrument_from_track_name(name) != 128
