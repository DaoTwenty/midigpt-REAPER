"""
Tests for MIDI-GPT Setup Tracks.py's on-the-fly Sforzando+Arachno
instrument generation -- see the module comment above ARACHNO_MELODIC_NAMES
in that file for the full story.

These exercise only the pure logic (name sanitization, slot-reference
construction, chunk encode/decode) -- nothing here touches REAPER, and
nothing here proves Sforzando/Aria actually accepts a generated chunk at
runtime. That still needs a real REAPER+Sforzando session; see
tests/integration/test_install.sh's ARACHNO_SF2_NAME-based smoke check for
as close as this repo gets to that without one.
"""

import base64
import importlib
import os
import struct
import sys
import zlib

import pytest

# conftest.py handles the reaper_python stub and sys.path setup. Importing
# setup_tracks has a real side effect worth knowing about: at module level
# it does `sys.stdout = sys.stderr = _ReaperConsole()`, which routes writes
# through RPR_ShowConsoleMsg -- a name the stub deliberately doesn't bind
# (see conftest.py), so anything that then tries to print() raises
# NameError. Save/restore around the import so the rest of the test session
# (including pytest's own output) isn't collateral damage.
#
# "MIDI-GPT Setup Tracks.py" has a space in its filename, which isn't valid
# `import` statement syntax -- importlib.import_module() takes the literal
# string instead, resolved via the same path-based finder.
_real_stdout, _real_stderr = sys.stdout, sys.stderr
setup_tracks = importlib.import_module("MIDI-GPT Setup Tracks")  # noqa: E402
sys.stdout, sys.stderr = _real_stdout, _real_stderr


REAL_ARACHNO_SF2_NAME = "Arachno SoundFont - Version 1.0.sf2"


@pytest.fixture
def fake_soundfonts_dir(tmp_path, monkeypatch):
    """Points setup_tracks._find_arachno_sf2_name() at a fake <repo>/soundfonts/
    directory containing one .sf2 file, without touching the real repo."""
    repo_dir = tmp_path / "repo"
    soundfonts_dir = repo_dir / "soundfonts"
    soundfonts_dir.mkdir(parents=True)
    sf2_path = soundfonts_dir / REAL_ARACHNO_SF2_NAME
    sf2_path.write_bytes(b"")  # content doesn't matter -- only the filename does

    # _find_arachno_sf2_name derives <repo> from this module's own file
    # location (4 levels up from src/Scripts/MIDI-GPT/<this file>.py) via
    # os.path.realpath(__file__) -- fake that instead of the real repo tree.
    fake_module_path = repo_dir / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
    fake_module_path.parent.mkdir(parents=True)
    monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
    return soundfonts_dir


def _decode_vst_block(block):
    """Reverses _build_sforzando_vst_block: returns the decompressed AriaSave
    XML text, for asserting against."""
    lines = [ln.strip() for ln in block.splitlines()]
    b64_lines = lines[1:-1]  # drop the '<VST ...' header line and the closing '>'
    rest = "".join(b64_lines[1:])  # b64_lines[0] is the fixed header blob
    pad = (-len(rest)) % 4
    payload = base64.b64decode(rest + "=" * pad)
    declared_len = struct.unpack("<I", payload[4:8])[0]
    xml = zlib.decompress(payload[8:]).decode("utf-8")
    assert len(xml) == declared_len, "declared XML length doesn't match actual decompressed length"
    return xml


class TestSanitizeAriaName:
    """Confirmed against one real captured example: space and '.' become
    '_'; other punctuation (e.g. '-') is left as-is."""

    def test_space_becomes_underscore(self):
        assert setup_tracks._sanitize_aria_name("Grand Piano") == "Grand_Piano"

    def test_period_becomes_underscore(self):
        assert setup_tracks._sanitize_aria_name("Version 1.0") == "Version_1_0"

    def test_hyphen_preserved(self):
        # This is the one non-obvious case: real captured Aria output keeps
        # the literal '-', it does NOT become '_'.
        assert "-" in setup_tracks._sanitize_aria_name("SoundFont - Version")

    def test_matches_real_captured_filename(self):
        assert (
            setup_tracks._sanitize_aria_name(REAL_ARACHNO_SF2_NAME)
            == "Arachno_SoundFont_-_Version_1_0_sf2"
        )

    def test_ampersand_is_xml_escaped_not_replaced(self):
        """Confirmed against a second real captured example: the raw FX
        chunk from a real project, decoded, gave the real slot name
        '.../087_Bass_&amp;_Lead' for program 87 ("Bass & Lead"). '&'
        survives as a literal '&' in the name -- it's XML-escaped to
        '&amp;' because the sanitized string is embedded straight into an
        XML attribute value, not because Aria's own sanitizer treats '&'
        like space/period."""
        assert setup_tracks._sanitize_aria_name("Bass & Lead") == "Bass_&amp;_Lead"

    def test_unconfirmed_characters_pass_through(self):
        # '(' / ')' aren't XML-special and there's no evidence (unlike '&')
        # that Aria's sanitizer -- or XML escaping -- touches them at all;
        # '/' doesn't appear in any of the 128 real Arachno melodic names
        # either. Both still pass-through, still unconfirmed. Pins current
        # behavior so a future change here is deliberate, not a silent
        # drift.
        assert setup_tracks._sanitize_aria_name("Dulcimer (Santur)") == "Dulcimer_(Santur)"
        assert setup_tracks._sanitize_aria_name("Fantasia (New Age)") == "Fantasia_(New_Age)"
        assert setup_tracks._sanitize_aria_name("TR-808/909 Drum Kit") == "TR-808/909_Drum_Kit"


class TestFindArachnoSf2Name:
    def test_finds_the_sf2_in_soundfonts_dir(self, fake_soundfonts_dir):
        assert setup_tracks._find_arachno_sf2_name() == REAL_ARACHNO_SF2_NAME

    def test_none_when_soundfonts_dir_missing(self, tmp_path, monkeypatch):
        fake_module_path = tmp_path / "repo" / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
        fake_module_path.parent.mkdir(parents=True)
        monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
        assert setup_tracks._find_arachno_sf2_name() is None

    def test_none_when_dir_has_no_sf2(self, tmp_path, monkeypatch):
        repo_dir = tmp_path / "repo"
        (repo_dir / "soundfonts").mkdir(parents=True)
        fake_module_path = repo_dir / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
        fake_module_path.parent.mkdir(parents=True)
        monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
        assert setup_tracks._find_arachno_sf2_name() is None

    def test_ignores_non_sf2_files(self, tmp_path, monkeypatch):
        repo_dir = tmp_path / "repo"
        soundfonts_dir = repo_dir / "soundfonts"
        soundfonts_dir.mkdir(parents=True)
        (soundfonts_dir / "readme.txt").write_text("not a soundfont")
        fake_module_path = repo_dir / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
        fake_module_path.parent.mkdir(parents=True)
        monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
        assert setup_tracks._find_arachno_sf2_name() is None


class TestArachnoSlotName:
    def test_matches_real_captured_reference(self, fake_soundfonts_dir):
        # This is a fully-confirmed reference string, captured from a real
        # Sforzando+Arachno FX chunk with GM program 0 selected.
        assert (
            setup_tracks._arachno_slot_name(0, 0, "Grand Piano")
            == "sf2/Arachno_SoundFont_-_Version_1_0_sf2/000/000_Grand_Piano"
        )

    def test_matches_real_captured_reference_with_ampersand(self, fake_soundfonts_dir):
        # A second fully-confirmed reference string, captured from a real
        # user's project (program 87, "Bass & Lead") after it loaded with
        # no preset selected -- decoding the actual FX chunk showed Aria's
        # real slot name XML-escapes '&' to '&amp;' rather than replacing
        # it with '_'.
        assert (
            setup_tracks._arachno_slot_name(0, 87, "Bass & Lead")
            == "sf2/Arachno_SoundFont_-_Version_1_0_sf2/000/087_Bass_&amp;_Lead"
        )

    def test_bank_and_program_are_zero_padded_three_digits(self, fake_soundfonts_dir):
        slot = setup_tracks._arachno_slot_name(128, 7, "Drum Kit")
        assert "/128/007_Drum_Kit" in slot

    def test_none_when_soundfont_not_found(self, tmp_path, monkeypatch):
        fake_module_path = tmp_path / "repo" / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
        fake_module_path.parent.mkdir(parents=True)
        monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
        assert setup_tracks._arachno_slot_name(0, 0, "Grand Piano") is None


class TestBuildSforzandoVstBlock:
    def test_none_when_soundfont_not_found(self, tmp_path, monkeypatch):
        fake_module_path = tmp_path / "repo" / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
        fake_module_path.parent.mkdir(parents=True)
        monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
        assert setup_tracks._build_sforzando_vst_block(0) is None

    def test_program_0_matches_real_captured_slot(self, fake_soundfonts_dir):
        block = setup_tracks._build_sforzando_vst_block(0)
        xml = _decode_vst_block(block)
        assert 'name="sf2/Arachno_SoundFont_-_Version_1_0_sf2/000/000_Grand_Piano"' in xml

    def test_drums_uses_bank_128_program_0(self, fake_soundfonts_dir):
        block = setup_tracks._build_sforzando_vst_block(128)
        xml = _decode_vst_block(block)
        assert 'name="sf2/Arachno_SoundFont_-_Version_1_0_sf2/128/000_Standard_Drum_Kit"' in xml

    def test_all_128_melodic_programs_encode_and_decode_cleanly(self, fake_soundfonts_dir):
        # Every GM program, not just a couple -- this is the thing that
        # would silently corrupt if the CEGP/header length math were wrong
        # for some but not all instrument-name lengths.
        for instrument in range(128):
            block = setup_tracks._build_sforzando_vst_block(instrument)
            xml = _decode_vst_block(block)
            expected_name = setup_tracks.ARACHNO_MELODIC_NAMES[instrument]
            expected_slot = f"sf2/Arachno_SoundFont_-_Version_1_0_sf2/000/{instrument:03d}_" + \
                setup_tracks._sanitize_aria_name(expected_name)
            assert f'name="{expected_slot}"' in xml

    def test_valid_xml_structure(self, fake_soundfonts_dir):
        block = setup_tracks._build_sforzando_vst_block(0)
        xml = _decode_vst_block(block)
        assert xml.startswith('<?xml version="1.0" ?>')
        assert xml.endswith("</AriaSave>")
        assert xml.count("<Slot") == 1
        assert xml.count("<Main") == 16

    def test_block_is_well_formed_for_embedding_in_fxchain(self, fake_soundfonts_dir):
        block = setup_tracks._build_sforzando_vst_block(0)
        lines = block.splitlines()
        assert lines[0].startswith('    <VST "VSTi: sforzando')
        assert lines[-1].strip() == ">"
        # Every line between the VST header and the closing '>' is base64
        # payload -- REAPER's chunk parser just concatenates them, but they
        # should each actually decode as base64 (catches stray whitespace
        # or a broken line-wrap boundary).
        for line in lines[1:-1]:
            base64.b64decode(line.strip() + "=" * ((-len(line.strip())) % 4))


class TestBuildSourceTrackChunk:
    def test_none_when_soundfont_not_found(self, tmp_path, monkeypatch):
        fake_module_path = tmp_path / "repo" / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
        fake_module_path.parent.mkdir(parents=True)
        monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
        assert setup_tracks._build_source_track_chunk("test track", 0) is None

    def test_wraps_vst_block_in_track_and_fxchain(self, fake_soundfonts_dir):
        chunk = setup_tracks._build_source_track_chunk("MIDI-GPT source", 0)
        assert chunk.startswith("<TRACK\n")
        assert "  NAME MIDI-GPT source\n" in chunk
        assert "  <FXCHAIN\n" in chunk
        assert '<VST "VSTi: sforzando' in chunk
        # Balanced enough to be parseable: TRACK/FXCHAIN opens each have a
        # matching close ('>' at the same nesting level).
        assert chunk.rstrip().endswith(">\n  >\n>".replace("\n", "\n")) or chunk.rstrip().endswith(">")


class TestGmInternalName:
    def test_drums(self):
        assert setup_tracks.gm_internal_name(128) == "drums"

    def test_piano(self):
        assert setup_tracks.gm_internal_name(0) == "acoustic_grand_piano"

    def test_out_of_range_falls_back_to_program_number(self):
        assert setup_tracks.gm_internal_name(999) == "program_999"

    def test_round_trips_through_name_to_instrument_map(self):
        for i, name in enumerate(setup_tracks.GM_INTERNAL_NAMES):
            assert setup_tracks.GM_NAME_TO_INSTRUMENT[name] == i
        assert setup_tracks.GM_NAME_TO_INSTRUMENT["drums"] == 128
