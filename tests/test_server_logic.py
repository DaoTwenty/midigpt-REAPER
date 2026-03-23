"""
Tests for MMM_server.py pure functions and logic.

Tests the server-side functions that don't require the model or C++ extension:
- _gm_program_to_type
- _build_status (empty bar handling, ignore, autoregressive logic)
- _build_param
- _score_to_result_dict
- midisong_dict_to_score (keep_alive / empty track handling)
- Job lifecycle
"""

import os
import json
import pytest

# conftest.py handles reaper_python / mmm_refactored stubs and sys.path setup

from MMM_server import (
    _gm_program_to_type,
    _build_status,
    _build_param,
    _score_to_result_dict,
    midisong_dict_to_score,
    GM_PROGRAM_TO_TYPE,
    Job,
    STATUS_QUEUED,
    STATUS_RUNNING,
    STATUS_DONE,
    STATUS_ERROR,
)


# ===================================================================
# Helpers
# ===================================================================

def _make_track_info(num_tracks, instruments=None):
    """Create a track_info list like what comes from song_dict."""
    if instruments is None:
        instruments = [0] * num_tracks
    return [
        {"track_index": i, "track_name": f"Track {i}", "instrument": instruments[i]}
        for i in range(num_tracks)
    ]


def _make_job(num_tracks=3, num_bars=4, infill_masks=None,
              ignore_tracks=None, autoregressive_tracks=None,
              gen_config_dict=None, per_track_acs=None,
              instruments=None):
    """Create a Job with sensible defaults for testing."""
    if infill_masks is None:
        infill_masks = []
    if ignore_tracks is None:
        ignore_tracks = []
    if autoregressive_tracks is None:
        autoregressive_tracks = []
    if gen_config_dict is None:
        gen_config_dict = {"temperature": 1.0, "model_dim": 4}
    if per_track_acs is None:
        per_track_acs = {}

    # Build a minimal song_dict
    if instruments is None:
        instruments = [0] * num_tracks
    track_info = _make_track_info(num_tracks, instruments)
    measures = []
    for t in range(num_tracks):
        track_measures = []
        for b in range(num_bars):
            track_measures.append({
                "start_time": b * 2.0,
                "end_time": (b + 1) * 2.0,
                "tempo": 120.0,
                "time_signature": [4, 4],
                "notes": [],
            })
        measures.append(track_measures)

    song_dict = {
        "num_tracks": num_tracks,
        "num_measures": num_bars,
        "track_info": track_info,
        "measures": measures,
    }

    return Job(
        job_id="test-job-001",
        song_dict=song_dict,
        infill_masks=infill_masks,
        bar_masks=[],
        ignore_tracks=ignore_tracks,
        autoregressive_tracks=autoregressive_tracks,
        gen_config_dict=gen_config_dict,
        per_track_acs=per_track_acs,
        start_measure=0,
        end_measure=num_bars,
    )


def _identity_mapping(n):
    """1:1 reaper→piece mapping."""
    return {i: i for i in range(n)}


# ===================================================================
# _gm_program_to_type
# ===================================================================

class TestGMProgramToType:
    def test_piano(self):
        assert _gm_program_to_type(0, False) == "acoustic_grand_piano"

    def test_drums(self):
        assert _gm_program_to_type(0, True) == "drums"
        assert _gm_program_to_type(128, True) == "drums"

    def test_out_of_range_defaults_piano(self):
        assert _gm_program_to_type(999, False) == "acoustic_grand_piano"
        assert _gm_program_to_type(-1, False) == "acoustic_grand_piano"

    def test_all_programs_covered(self):
        assert len(GM_PROGRAM_TO_TYPE) == 128

    def test_specific_instruments(self):
        assert _gm_program_to_type(34, False) == "electric_bass_pick"
        assert _gm_program_to_type(73, False) == "flute"
        assert _gm_program_to_type(40, False) == "violin"


# ===================================================================
# _build_status — core logic
# ===================================================================

class TestBuildStatus:
    """Tests for _build_status focusing on empty bar and ignore/AR handling."""

    def test_basic_infill(self):
        """Standard infill: masked bars are selected, unmasked are not."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(0, 1), (0, 2)])
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        assert len(status["tracks"]) == 2
        t0 = status["tracks"][0]
        assert t0["selected_bars"] == [False, True, True, False]
        assert t0["autoregressive"] is False
        assert t0["ignore"] is False

    def test_ignore_track_no_bars_selected(self):
        """Ignored track must have all bars False (CONDITION-only)."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(0, 0), (0, 1), (1, 0), (1, 1)],
                        ignore_tracks=[1])
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t1 = status["tracks"][1]
        assert t1["ignore"] is True
        assert t1["selected_bars"] == [False, False, False, False]
        assert t1["autoregressive"] is False

    def test_autoregressive_all_bars_selected(self):
        """AR track must have ALL bars selected (MIDI-GPT constraint)."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(0, 0), (0, 1)],
                        autoregressive_tracks=[0])
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t0 = status["tracks"][0]
        assert t0["autoregressive"] is True
        assert t0["selected_bars"] == [True, True, True, True]

    def test_ignore_overrides_infill_mask(self):
        """Even if a track has infill masks, ignore=True zeroes them out."""
        job = _make_job(num_tracks=1, num_bars=4,
                        infill_masks=[(0, 0), (0, 1), (0, 2), (0, 3)],
                        ignore_tracks=[0])
        mapping = _identity_mapping(1)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t0 = status["tracks"][0]
        assert t0["ignore"] is True
        assert all(b is False for b in t0["selected_bars"])

    def test_ignore_overrides_autoregressive(self):
        """ignore=True takes precedence over autoregressive."""
        job = _make_job(num_tracks=1, num_bars=4,
                        infill_masks=[(0, 0)],
                        autoregressive_tracks=[0],
                        ignore_tracks=[0])
        mapping = _identity_mapping(1)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t0 = status["tracks"][0]
        assert t0["ignore"] is True
        assert t0["autoregressive"] is False
        assert all(b is False for b in t0["selected_bars"])

    # --- Empty bar / empty track edge cases ---

    def test_empty_track_no_infill_no_ar_has_no_selection(self):
        """An empty track with no infill masks and no AR should have no bars selected.
        This is the 'passive' empty track that should essentially be ignored."""
        job = _make_job(num_tracks=3, num_bars=4,
                        infill_masks=[(0, 0), (0, 1)])  # only track 0 masked
        mapping = _identity_mapping(3)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        # Track 1 and 2 have no masks — all False
        t1 = status["tracks"][1]
        assert t1["selected_bars"] == [False, False, False, False]
        assert t1["autoregressive"] is False
        assert t1["ignore"] is False

    def test_empty_track_with_ar_gets_all_bars_selected(self):
        """An empty track marked autoregressive should get all bars selected.
        This is the 'generate entire track from scratch' use case."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(0, 0)],
                        autoregressive_tracks=[1])  # track 1 is empty but AR
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t1 = status["tracks"][1]
        assert t1["autoregressive"] is True
        assert t1["selected_bars"] == [True, True, True, True]

    def test_empty_track_with_infill_masks_gets_selected(self):
        """An empty track that has infill masks should have those bars selected.
        This is the 'infill specific bars on an otherwise empty track' case."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(1, 1), (1, 2)])  # track 1 bars 1,2
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t1 = status["tracks"][1]
        assert t1["selected_bars"] == [False, True, True, False]

    def test_global_ar_flag_promotes_masked_tracks(self):
        """Global autoregressive toggle promotes any track with at least one
        masked bar to full AR (all bars selected)."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(0, 0), (1, 2)],
                        gen_config_dict={"autoregressive": True, "model_dim": 4})
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        # Both tracks have at least one mask → global AR promotes them
        for t in status["tracks"]:
            assert t["autoregressive"] is True
            assert t["selected_bars"] == [True, True, True, True]

    def test_global_ar_does_not_promote_unmasked_track(self):
        """Global AR only promotes tracks that have at least one masked bar.
        Tracks with zero masks stay unaffected."""
        job = _make_job(num_tracks=3, num_bars=4,
                        infill_masks=[(0, 0)],  # only track 0
                        gen_config_dict={"autoregressive": True, "model_dim": 4})
        mapping = _identity_mapping(3)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        # Track 0: has mask → promoted to AR
        assert status["tracks"][0]["autoregressive"] is True
        assert status["tracks"][0]["selected_bars"] == [True, True, True, True]
        # Track 1, 2: no masks → not promoted
        assert status["tracks"][1]["autoregressive"] is False
        assert status["tracks"][1]["selected_bars"] == [False, False, False, False]

    # --- Drum track type ---

    def test_drum_track_type(self):
        """Track with instrument 128 gets STANDARD_DRUM_TRACK type."""
        job = _make_job(num_tracks=2, num_bars=4, instruments=[0, 128])
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        assert status["tracks"][0]["track_type"] == "STANDARD_TRACK"
        assert status["tracks"][1]["track_type"] == "STANDARD_DRUM_TRACK"
        assert status["tracks"][1]["instrument"] == "drums"

    # --- Track mapping: dropped tracks ---

    def test_dropped_track_excluded_from_status(self):
        """Tracks not in reaper_to_piece mapping are excluded from Status."""
        job = _make_job(num_tracks=3, num_bars=4)
        # Only tracks 0 and 2 survived MIDI roundtrip
        mapping = {0: 0, 2: 1}
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        assert len(status["tracks"]) == 2
        # track_ids should be piece indices
        ids = {t["track_id"] for t in status["tracks"]}
        assert ids == {0, 1}

    # --- Per-track AC values ---

    def test_per_track_temperature_clamped(self):
        """Temperature is clamped to [0.5, 2.0] per protobuf range."""
        job = _make_job(num_tracks=1, num_bars=4,
                        per_track_acs={"0": {"temperature": "0.1"}})
        mapping = _identity_mapping(1)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)
        assert status["tracks"][0]["temperature"] == 0.5

        job2 = _make_job(num_tracks=1, num_bars=4,
                         per_track_acs={"0": {"temperature": "5.0"}})
        status2 = _build_status(job2, job2.song_dict["track_info"], 4, mapping)
        assert status2["tracks"][0]["temperature"] == 2.0

    def test_polyphony_hard_limit_fallback(self):
        """0 in per-track falls back to global, 0 in global falls to 100."""
        job = _make_job(num_tracks=1, num_bars=4,
                        per_track_acs={"0": {"polyphony_hard_limit": "0"}},
                        gen_config_dict={"polyphony_hard_limit": 0, "model_dim": 4})
        mapping = _identity_mapping(1)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)
        assert status["tracks"][0]["polyphony_hard_limit"] == 100

    def test_polyphony_uses_global_when_track_is_zero(self):
        job = _make_job(num_tracks=1, num_bars=4,
                        per_track_acs={"0": {"polyphony_hard_limit": "0"}},
                        gen_config_dict={"polyphony_hard_limit": 8, "model_dim": 4})
        mapping = _identity_mapping(1)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)
        assert status["tracks"][0]["polyphony_hard_limit"] == 8

    # --- Mask boundary checks ---

    def test_mask_out_of_bounds_ignored(self):
        """Masks referencing tracks/bars beyond the actual range are ignored."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(0, 0), (99, 0), (0, 99)])
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t0 = status["tracks"][0]
        assert t0["selected_bars"][0] is True
        assert sum(t0["selected_bars"]) == 1  # only bar 0


# ===================================================================
# _build_param
# ===================================================================

class TestBuildParam:
    def test_defaults(self):
        job = _make_job(gen_config_dict={"model_dim": 4, "temperature": 1.0})
        # Patch CKPT_PATH for the test
        import MMM_server
        old_ckpt = MMM_server.CKPT_PATH
        MMM_server.CKPT_PATH = "/fake/path.pt"
        try:
            param = _build_param(job)
            assert param["model_dim"] == 4
            assert param["temperature"] == 1.0
            assert param["ckpt"] == "/fake/path.pt"
            assert param["bars_per_step"] <= param["model_dim"]
        finally:
            MMM_server.CKPT_PATH = old_ckpt

    def test_bars_per_step_clamped_to_model_dim(self):
        job = _make_job(gen_config_dict={
            "model_dim": 4, "bars_per_step": 8, "temperature": 1.0
        })
        import MMM_server
        old_ckpt = MMM_server.CKPT_PATH
        MMM_server.CKPT_PATH = "/fake/path.pt"
        try:
            param = _build_param(job)
            assert param["bars_per_step"] == 4
        finally:
            MMM_server.CKPT_PATH = old_ckpt

    def test_polyphony_limit_zero_stays_zero(self):
        """0 means no limit in both JSFX and C++ (default_sample_param
        does NOT set polyphony_hard_limit)."""
        job = _make_job(gen_config_dict={
            "model_dim": 4, "polyphony_hard_limit": 0
        })
        import MMM_server
        old_ckpt = MMM_server.CKPT_PATH
        MMM_server.CKPT_PATH = "/fake/path.pt"
        try:
            param = _build_param(job)
            assert param["polyphony_hard_limit"] == 0
        finally:
            MMM_server.CKPT_PATH = old_ckpt

    def test_temperature_clamped(self):
        job = _make_job(gen_config_dict={"model_dim": 4, "temperature": 0.1})
        import MMM_server
        old_ckpt = MMM_server.CKPT_PATH
        MMM_server.CKPT_PATH = "/fake/path.pt"
        try:
            param = _build_param(job)
            assert param["temperature"] == 0.5
        finally:
            MMM_server.CKPT_PATH = old_ckpt

    def test_temperature_upper_bound(self):
        """Proto allows 2.0, should not be capped below that."""
        job = _make_job(gen_config_dict={"model_dim": 4, "temperature": 2.0})
        import MMM_server
        old_ckpt = MMM_server.CKPT_PATH
        MMM_server.CKPT_PATH = "/fake/path.pt"
        try:
            param = _build_param(job)
            assert param["temperature"] == 2.0
        finally:
            MMM_server.CKPT_PATH = old_ckpt


# ===================================================================
# midisong_dict_to_score — keep_alive / empty track handling
# ===================================================================

class TestMidisongDictToScore:
    def _make_song_dict(self, num_tracks=2, num_bars=4, notes_on_tracks=None):
        """Build a song_dict. notes_on_tracks is a set of track indices that
        should have notes; all others are empty."""
        if notes_on_tracks is None:
            notes_on_tracks = set()
        track_info = _make_track_info(num_tracks)
        measures = []
        for t in range(num_tracks):
            track_measures = []
            for b in range(num_bars):
                notes = []
                if t in notes_on_tracks:
                    notes = [{"pitch": 60, "velocity": 100,
                              "start_time": 0.0, "end_time": 0.5}]
                track_measures.append({
                    "start_time": b * 2.0,
                    "end_time": (b + 1) * 2.0,
                    "tempo": 120.0,
                    "time_signature": [4, 4],
                    "notes": notes,
                })
            measures.append(track_measures)
        return {
            "num_tracks": num_tracks,
            "num_measures": num_bars,
            "track_info": track_info,
            "measures": measures,
        }

    def test_basic_conversion(self):
        sd = self._make_song_dict(2, 4, notes_on_tracks={0, 1})
        score = midisong_dict_to_score(sd)
        assert len(score.tracks) == 2
        assert all(len(t.notes) > 0 for t in score.tracks)

    def test_empty_track_without_keep_alive(self):
        """Empty track NOT in keep_alive gets 0 notes (may be dropped by encoder)."""
        sd = self._make_song_dict(2, 4, notes_on_tracks={0})
        score = midisong_dict_to_score(sd)
        assert len(score.tracks) == 2
        # Track 1 has no notes (no keep_alive)
        assert len(score.tracks[1].notes) == 0

    def test_empty_track_with_keep_alive(self):
        """Empty track in keep_alive gets a placeholder note so encoder keeps it."""
        sd = self._make_song_dict(2, 4, notes_on_tracks={0})
        score = midisong_dict_to_score(sd, keep_alive_tracks={1})
        assert len(score.tracks) == 2
        # Track 1 should have a placeholder note
        assert len(score.tracks[1].notes) == 1
        placeholder = score.tracks[1].notes[0]
        assert placeholder.velocity == 1  # silent placeholder
        assert placeholder.duration == 1

    def test_keep_alive_does_not_add_placeholder_if_notes_exist(self):
        """keep_alive should not add placeholder to tracks that already have notes."""
        sd = self._make_song_dict(2, 4, notes_on_tracks={0, 1})
        score = midisong_dict_to_score(sd, keep_alive_tracks={0, 1})
        # All notes should be real, no extra placeholder
        for t in score.tracks:
            for n in t.notes:
                assert n.velocity > 1

    def test_drum_track_is_drum(self):
        sd = self._make_song_dict(2, 4, notes_on_tracks={0, 1})
        sd["track_info"][1]["instrument"] = 128
        score = midisong_dict_to_score(sd)
        assert score.tracks[0].is_drum is False
        assert score.tracks[1].is_drum is True
        assert score.tracks[1].program == 0  # drums always program 0

    def test_tempo_from_measures(self):
        sd = self._make_song_dict(1, 2, notes_on_tracks={0})
        sd["measures"][0][0]["tempo"] = 140.0
        score = midisong_dict_to_score(sd)
        assert any(t.qpm == pytest.approx(140.0, rel=1e-3) for t in score.tempos)

    def test_all_tracks_empty_no_keep_alive(self):
        """When all tracks are empty and no keep_alive, score has 0 total notes."""
        sd = self._make_song_dict(3, 4, notes_on_tracks=set())
        score = midisong_dict_to_score(sd)
        total_notes = sum(len(t.notes) for t in score.tracks)
        assert total_notes == 0

    def test_keep_alive_for_ar_empty_track(self):
        """Simulates the 'generate entire track' scenario: empty track marked AR
        should survive the roundtrip via keep_alive."""
        sd = self._make_song_dict(3, 4, notes_on_tracks={0})
        # Track 2 is empty but AR → keep_alive
        score = midisong_dict_to_score(sd, keep_alive_tracks={2})
        assert len(score.tracks[2].notes) == 1  # placeholder


# ===================================================================
# _score_to_result_dict
# ===================================================================

class TestScoreToResultDict:
    def test_basic_extraction(self):
        from symusic import Score, Track, Note, Tempo, TimeSignature

        tpq = 480
        score = Score(tpq)
        score.tempos.append(Tempo(time=0, qpm=120))
        score.time_signatures.append(TimeSignature(time=0, numerator=4, denominator=4))

        track = Track(program=0, is_drum=False, name="Piano")
        # Bar 0: tick 0-1919, Bar 1: tick 1920-3839
        track.notes.append(Note(time=100, duration=100, pitch=60, velocity=100))
        track.notes.append(Note(time=2000, duration=100, pitch=72, velocity=80))
        score.tracks.append(track)

        masks = [(0, 0), (0, 1)]  # both bars masked
        piece_to_reaper = {0: 0}

        result = _score_to_result_dict(score, masks, 0, 2, piece_to_reaper)

        assert result["tpq"] == tpq
        assert "0" in result["tracks"]
        assert "0" in result["tracks"]["0"]  # bar 0
        assert "1" in result["tracks"]["0"]  # bar 1
        assert len(result["tracks"]["0"]["0"]) == 1
        assert result["tracks"]["0"]["0"][0]["pitch"] == 60

    def test_unmasked_bars_excluded(self):
        from symusic import Score, Track, Note, Tempo, TimeSignature

        tpq = 480
        score = Score(tpq)
        score.tempos.append(Tempo(time=0, qpm=120))
        score.time_signatures.append(TimeSignature(time=0, numerator=4, denominator=4))

        track = Track(program=0, is_drum=False, name="Piano")
        track.notes.append(Note(time=100, duration=100, pitch=60, velocity=100))
        track.notes.append(Note(time=2000, duration=100, pitch=72, velocity=80))
        score.tracks.append(track)

        # Only bar 0 is masked
        masks = [(0, 0)]
        piece_to_reaper = {0: 0}

        result = _score_to_result_dict(score, masks, 0, 2, piece_to_reaper)

        assert "0" in result["tracks"]["0"]
        assert "1" not in result["tracks"]["0"]  # bar 1 not masked

    def test_unmapped_piece_track_ignored(self):
        """Piece tracks not in piece_to_reaper should not appear in result."""
        from symusic import Score, Track, Note, Tempo, TimeSignature

        tpq = 480
        score = Score(tpq)
        score.tempos.append(Tempo(time=0, qpm=120))
        score.time_signatures.append(TimeSignature(time=0, numerator=4, denominator=4))

        t0 = Track(program=0, is_drum=False, name="Piano")
        t0.notes.append(Note(time=100, duration=100, pitch=60, velocity=100))
        t1 = Track(program=0, is_drum=False, name="Unknown")
        t1.notes.append(Note(time=100, duration=100, pitch=72, velocity=100))
        score.tracks.extend([t0, t1])

        masks = [(0, 0), (1, 0)]
        # Only piece track 0 maps to reaper track 0
        piece_to_reaper = {0: 0}

        result = _score_to_result_dict(score, masks, 0, 2, piece_to_reaper)

        assert "0" in result["tracks"]
        assert "1" not in result["tracks"]  # piece track 1 has no mapping

    def test_note_tick_is_relative_to_bar(self):
        """start_tick in result should be relative to bar start, not absolute."""
        from symusic import Score, Track, Note, Tempo, TimeSignature

        tpq = 480
        ticks_per_bar = tpq * 4  # 1920
        score = Score(tpq)
        score.tempos.append(Tempo(time=0, qpm=120))
        score.time_signatures.append(TimeSignature(time=0, numerator=4, denominator=4))

        track = Track(program=0, is_drum=False, name="Piano")
        # Note at absolute tick 2100, which is bar 1 tick 180
        track.notes.append(Note(time=2100, duration=50, pitch=60, velocity=100))
        score.tracks.append(track)

        masks = [(0, 1)]
        piece_to_reaper = {0: 0}

        result = _score_to_result_dict(score, masks, 0, 4, piece_to_reaper)

        note = result["tracks"]["0"]["1"][0]
        assert note["start_tick"] == 2100 - ticks_per_bar  # 180
        assert note["duration_tick"] == 50

    def test_three_four_time_signature(self):
        """Bar boundaries should respect 3/4 time (3 beats per bar, not 4)."""
        from symusic import Score, Track, Note, Tempo, TimeSignature

        tpq = 480
        bar_len_34 = int(3 / 4 * 4 * tpq)  # 1440 ticks
        score = Score(tpq)
        score.tempos.append(Tempo(time=0, qpm=120))
        score.time_signatures.append(TimeSignature(time=0, numerator=3, denominator=4))

        track = Track(program=0, is_drum=False, name="Piano")
        # Note in bar 0 (tick 100)
        track.notes.append(Note(time=100, duration=50, pitch=60, velocity=100))
        # Note in bar 1 (tick 1440 + 200 = 1640)
        track.notes.append(Note(time=bar_len_34 + 200, duration=50, pitch=72, velocity=80))
        score.tracks.append(track)

        masks = [(0, 0), (0, 1)]
        piece_to_reaper = {0: 0}

        result = _score_to_result_dict(score, masks, 0, 4, piece_to_reaper)

        # Bar 0
        assert len(result["tracks"]["0"]["0"]) == 1
        assert result["tracks"]["0"]["0"][0]["start_tick"] == 100
        # Bar 1
        assert len(result["tracks"]["0"]["1"]) == 1
        assert result["tracks"]["0"]["1"][0]["start_tick"] == 200  # relative to bar 1 start


# ===================================================================
# Job lifecycle
# ===================================================================

class TestJob:
    def test_initial_state(self):
        job = _make_job()
        assert job.status == STATUS_QUEUED
        assert job.progress == 0
        assert job.result is None
        assert job.error is None

    def test_status_dict(self):
        job = _make_job()
        d = job.status_dict()
        assert d["status"] == STATUS_QUEUED
        assert d["job_id"] == "test-job-001"
        assert "elapsed" in d
        assert d["error"] == ""


# ===================================================================
# Empty track scenarios end-to-end through _build_status
# ===================================================================

class TestEmptyTrackScenarios:
    """Comprehensive tests for the empty track handling rules:

    1. Empty track, no generation (no infill, no AR) → can be ignored
    2. Empty track, ignore toggle active → must be ignored
    3. Empty track with AR → generate entire track (all bars selected)
    4. Empty track with infill masks → infill those specific bars
    """

    def test_scenario_empty_track_passive(self):
        """Scenario: 3 tracks, track 2 is empty with no masks or AR.
        Expected: track 2 has no bars selected, acts as condition."""
        job = _make_job(num_tracks=3, num_bars=4,
                        infill_masks=[(0, 0), (0, 1), (1, 0)])
        mapping = _identity_mapping(3)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t2 = status["tracks"][2]
        assert t2["selected_bars"] == [False, False, False, False]
        assert t2["ignore"] is False
        assert t2["autoregressive"] is False

    def test_scenario_empty_track_ignored(self):
        """Scenario: track has ignore toggle ON.
        Expected: no bars selected, ignore=True."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(0, 0), (1, 0), (1, 1)],
                        ignore_tracks=[1])
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t1 = status["tracks"][1]
        assert t1["ignore"] is True
        assert t1["selected_bars"] == [False, False, False, False]

    def test_scenario_empty_track_generate_full(self):
        """Scenario: empty track with AR → generate from scratch.
        Expected: all bars selected, autoregressive=True."""
        job = _make_job(num_tracks=2, num_bars=4,
                        infill_masks=[(0, 0)],
                        autoregressive_tracks=[1])
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        t1 = status["tracks"][1]
        assert t1["autoregressive"] is True
        assert t1["selected_bars"] == [True, True, True, True]

    def test_scenario_empty_track_partial_infill(self):
        """Scenario: empty track with only some bars masked.
        Expected: only those bars selected."""
        job = _make_job(num_tracks=2, num_bars=8,
                        infill_masks=[(1, 2), (1, 5)])
        mapping = _identity_mapping(2)
        status = _build_status(job, job.song_dict["track_info"], 8, mapping)

        t1 = status["tracks"][1]
        expected = [False, False, True, False, False, True, False, False]
        assert t1["selected_bars"] == expected

    def test_scenario_mixed_tracks(self):
        """Scenario: 4 tracks — one with notes+infill, one AR empty,
        one ignored, one passive empty.
        Expected: each handled correctly per its role."""
        job = _make_job(
            num_tracks=4, num_bars=4,
            infill_masks=[(0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (1, 3)],
            autoregressive_tracks=[1],
            ignore_tracks=[2],
        )
        mapping = _identity_mapping(4)
        status = _build_status(job, job.song_dict["track_info"], 4, mapping)

        # Track 0: standard infill
        t0 = status["tracks"][0]
        assert t0["selected_bars"] == [False, True, True, False]
        assert t0["ignore"] is False
        assert t0["autoregressive"] is False

        # Track 1: AR → all bars selected
        t1 = status["tracks"][1]
        assert t1["selected_bars"] == [True, True, True, True]
        assert t1["autoregressive"] is True

        # Track 2: ignored → no bars
        t2 = status["tracks"][2]
        assert t2["selected_bars"] == [False, False, False, False]
        assert t2["ignore"] is True

        # Track 3: passive (no masks, no AR, no ignore) → no bars
        t3 = status["tracks"][3]
        assert t3["selected_bars"] == [False, False, False, False]
        assert t3["ignore"] is False
        assert t3["autoregressive"] is False


# ===================================================================
# Config parsing
# ===================================================================

class TestConfigParsing:
    def test_config_json_structure(self):
        config_path = os.path.join(
            os.path.dirname(__file__), "..", "src", "Scripts", "MMM", "models", "config.json"
        )
        with open(config_path) as f:
            cfg = json.load(f)

        assert "ckpt" in cfg
        assert "label" in cfg
        assert "track_fx_id" in cfg
        assert "ac_schema" in cfg
        assert isinstance(cfg["ac_schema"], list)
        assert len(cfg["ac_schema"]) > 0

        # Each AC param must have required fields
        for param in cfg["ac_schema"]:
            assert "ac_key" in param
            assert "min" in param
            assert "max" in param
            assert "default" in param
            assert param["min"] <= param["max"]
            assert param["min"] <= param["default"] <= param["max"]
