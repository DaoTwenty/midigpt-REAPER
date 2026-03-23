"""
Tests for midi_extraction.py data structures and logic.

These tests exercise the pure-Python data structures (MIDINote, MIDIMeasure,
MIDISongByMeasure, MeasureMask, TempoMap, TrackInfo) without requiring REAPER.
"""

import pytest

# conftest.py handles reaper_python stub and sys.path setup
from midi_extraction import (
    MIDINote,
    MIDIMeasure,
    MIDISongByMeasure,
    MeasureMask,
    TempoMap,
    TrackInfo,
    TimeSelection,
    get_instrument_from_track_name,
)


# ===================================================================
# MIDINote
# ===================================================================

class TestMIDINote:
    def test_duration(self):
        note = MIDINote(pitch=60, velocity=100, start_time=0.0, end_time=0.5)
        assert note.duration == pytest.approx(0.5)

    def test_zero_duration(self):
        note = MIDINote(pitch=60, velocity=100, start_time=1.0, end_time=1.0)
        assert note.duration == pytest.approx(0.0)

    def test_attributes(self):
        note = MIDINote(pitch=72, velocity=64, start_time=0.1, end_time=0.3)
        assert note.pitch == 72
        assert note.velocity == 64


# ===================================================================
# MIDIMeasure
# ===================================================================

class TestMIDIMeasure:
    def _make_measure(self, notes=None, **kwargs):
        defaults = dict(
            measure_number=0, track_index=0, instrument=0,
            notes=notes or [], start_time=0.0, end_time=2.0,
            tempo=120.0, time_signature=(4, 4),
        )
        defaults.update(kwargs)
        return MIDIMeasure(**defaults)

    def test_is_empty_true(self):
        m = self._make_measure(notes=[])
        assert m.is_empty is True

    def test_is_empty_false(self):
        note = MIDINote(60, 100, 0.0, 0.5)
        m = self._make_measure(notes=[note])
        assert m.is_empty is False

    def test_duration(self):
        m = self._make_measure(start_time=1.0, end_time=3.0)
        assert m.duration == pytest.approx(2.0)

    def test_drum_instrument(self):
        m = self._make_measure(instrument=128)
        assert m.instrument == 128


# ===================================================================
# MIDISongByMeasure
# ===================================================================

class TestMIDISongByMeasure:
    def _make_song(self, num_tracks=3, num_measures=4):
        song = MIDISongByMeasure(num_tracks, num_measures)
        infos = [
            TrackInfo(i, None, f"Track {i}", 0)
            for i in range(num_tracks)
        ]
        song.set_track_info(infos)
        return song

    def test_dimensions(self):
        song = self._make_song(3, 4)
        assert song.num_tracks == 3
        assert song.num_measures == 4

    def test_set_and_get_measure(self):
        song = self._make_song(2, 2)
        note = MIDINote(60, 100, 0.0, 0.5)
        m = MIDIMeasure(0, 0, 0, [note], 0.0, 2.0)
        song.set_measure(0, 0, m)
        assert song.get_measure(0, 0) is m

    def test_get_measure_out_of_bounds(self):
        song = self._make_song(2, 2)
        assert song.get_measure(5, 0) is None
        assert song.get_measure(0, 5) is None
        assert song.get_measure(-1, 0) is None

    def test_set_measure_out_of_bounds_no_crash(self):
        song = self._make_song(2, 2)
        m = MIDIMeasure(0, 0, 0, [], 0.0, 2.0)
        # Should silently ignore out-of-bounds
        song.set_measure(10, 10, m)
        assert song.get_measure(10, 10) is None

    def test_track_info(self):
        song = self._make_song(2, 2)
        info = song.get_track_info(0)
        assert info is not None
        assert info.track_name == "Track 0"

    def test_track_info_out_of_bounds(self):
        song = self._make_song(2, 2)
        assert song.get_track_info(99) is None

    def test_to_dict_structure(self):
        song = self._make_song(2, 2)
        note = MIDINote(60, 100, 0.0, 0.5)
        m = MIDIMeasure(0, 0, 0, [note], 0.0, 2.0, tempo=120.0)
        song.set_measure(0, 0, m)
        d = song.to_dict()
        assert d["num_tracks"] == 2
        assert d["num_measures"] == 2
        assert len(d["track_info"]) == 2
        # Track 0, measure 0 has notes
        assert d["measures"][0][0] is not None
        assert len(d["measures"][0][0]["notes"]) == 1
        # Track 0, measure 1 is None (never set)
        assert d["measures"][0][1] is None

    def test_to_dict_empty_measure_is_none(self):
        """Unset measures serialize as None."""
        song = self._make_song(1, 3)
        d = song.to_dict()
        assert all(m is None for m in d["measures"][0])

    def test_to_dict_note_fields(self):
        song = self._make_song(1, 1)
        note = MIDINote(pitch=72, velocity=64, start_time=0.1, end_time=0.3)
        m = MIDIMeasure(0, 0, 34, [note], 0.0, 2.0)
        song.set_measure(0, 0, m)
        d = song.to_dict()
        n = d["measures"][0][0]["notes"][0]
        assert n["pitch"] == 72
        assert n["velocity"] == 64
        assert n["start_time"] == pytest.approx(0.1)
        assert n["end_time"] == pytest.approx(0.3)


# ===================================================================
# MeasureMask
# ===================================================================

class TestMeasureMask:
    def test_empty_mask(self):
        mask = MeasureMask()
        assert mask.count == 0
        assert mask.is_masked(0, 0) is False

    def test_add_and_check(self):
        mask = MeasureMask()
        mask.add_mask(1, 2)
        assert mask.is_masked(1, 2) is True
        assert mask.is_masked(0, 0) is False

    def test_count(self):
        mask = MeasureMask()
        mask.add_mask(0, 0)
        mask.add_mask(0, 1)
        mask.add_mask(1, 0)
        assert mask.count == 3

    def test_no_duplicates(self):
        mask = MeasureMask()
        mask.add_mask(0, 0)
        mask.add_mask(0, 0)
        assert mask.count == 1

    def test_to_list_sorted(self):
        mask = MeasureMask()
        mask.add_mask(2, 1)
        mask.add_mask(0, 3)
        mask.add_mask(1, 0)
        result = mask.to_list()
        assert result == [(0, 3), (1, 0), (2, 1)]


# ===================================================================
# TempoMap (non-REAPER methods)
# ===================================================================

class TestTempoMap:
    def test_default_tempo(self):
        tm = TempoMap()
        assert tm.get_tempo_at_time(0.0) == 120.0

    def test_default_time_sig(self):
        tm = TempoMap()
        assert tm.get_time_signature_at_time(0.0) == (4, 4)

    def test_single_tempo_marker(self):
        tm = TempoMap()
        tm.add_tempo(0.0, 140.0)
        assert tm.get_tempo_at_time(0.0) == 140.0
        assert tm.get_tempo_at_time(5.0) == 140.0

    def test_multiple_tempo_markers(self):
        tm = TempoMap()
        tm.add_tempo(0.0, 100.0)
        tm.add_tempo(4.0, 160.0)
        assert tm.get_tempo_at_time(0.0) == 100.0
        assert tm.get_tempo_at_time(3.9) == 100.0
        assert tm.get_tempo_at_time(4.0) == 160.0
        assert tm.get_tempo_at_time(10.0) == 160.0

    def test_time_sig_markers(self):
        tm = TempoMap()
        tm.add_time_signature(0.0, 3, 4)
        tm.add_time_signature(8.0, 6, 8)
        assert tm.get_time_signature_at_time(0.0) == (3, 4)
        assert tm.get_time_signature_at_time(7.9) == (3, 4)
        assert tm.get_time_signature_at_time(8.0) == (6, 8)

    def test_invalid_tempo_rejected(self):
        tm = TempoMap()
        tm.add_tempo(0.0, 0)  # invalid
        tm.add_tempo(0.0, -10)  # invalid
        assert len(tm.tempo_markers) == 0

    def test_invalid_time_sig_rejected(self):
        tm = TempoMap()
        tm.add_time_signature(0.0, 0, 4)  # invalid
        tm.add_time_signature(0.0, 4, 0)  # invalid
        assert len(tm.time_sig_markers) == 0


# ===================================================================
# TimeSelection
# ===================================================================

class TestTimeSelection:
    def test_has_selection(self):
        ts = TimeSelection(1.0, 5.0, 0, 4)
        assert ts.has_selection is True

    def test_no_selection(self):
        ts = TimeSelection(0.0, 0.0, 0, 0)
        assert ts.has_selection is False

    def test_duration(self):
        ts = TimeSelection(2.0, 6.0, 1, 3)
        assert ts.duration == pytest.approx(4.0)


# ===================================================================
# Instrument mapping
# ===================================================================

class TestInstrumentMapping:
    def test_piano_default(self):
        assert get_instrument_from_track_name("Unknown Track") == 0

    def test_drums(self):
        assert get_instrument_from_track_name("Drum Kit") == 128
        assert get_instrument_from_track_name("kick") == 128
        assert get_instrument_from_track_name("Snare Layer") == 128

    def test_bass(self):
        assert get_instrument_from_track_name("Bass") == 34

    def test_guitar(self):
        assert get_instrument_from_track_name("Dist Guitar") == 30

    def test_strings(self):
        assert get_instrument_from_track_name("Violin 1") == 40
        assert get_instrument_from_track_name("Cello") == 42

    def test_case_insensitive(self):
        assert get_instrument_from_track_name("PIANO") == 0
        assert get_instrument_from_track_name("DRUMS") == 128

    def test_flute(self):
        assert get_instrument_from_track_name("Flute") == 73

    def test_organ(self):
        assert get_instrument_from_track_name("Organ") == 16


# ===================================================================
# TrackInfo
# ===================================================================

class TestTrackInfo:
    def test_repr(self):
        ti = TrackInfo(0, None, "Piano", 0)
        assert "Piano" in repr(ti)
        assert "idx=0" in repr(ti)
