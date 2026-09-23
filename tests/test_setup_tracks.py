"""
Tests for MIDI-GPT Setup Tracks.py's on-the-fly Sforzando+Arachno
instrument generation -- see the module comment above ARACHNO_MELODIC_NAMES
in that file for the full story.

These exercise only the pure logic (name sanitization, slot/path
construction, chunk encode/decode, the one-time conversion's bookkeeping,
plugin-format detection) -- nothing here touches REAPER or runs Aria's real
converter, and nothing here proves Sforzando/Aria actually accepts a
generated chunk at runtime. That still needs a real REAPER+Sforzando
session.
"""

import base64
import importlib
import os
import struct
import subprocess
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
SANITIZED_SF2 = "Arachno_SoundFont_-_Version_1_0_sf2"

# The VST3 FX line and first base64 line, exactly as REAPER saved them in a
# real Windows project (Sforzando VST3, Arachno loaded) -- the first line's
# length field (u32 at offset 32) differs per instrument, so it's compared
# with that field zeroed.
REAL_VST3_LINE = ('<VST "VST3i: sforzando (Plogue Art et Technologie, Inc)" sforzando.vst3 0 "" '
                  '395535903{5C5CA79682FC437AB6539BA204BAB349} ""')
REAL_VST3_HEADER_U32S = (395535903, 0xFEED5EEE, 0, 2, 1, 0, 2, 0, None, 1, 0xFFFF)


@pytest.fixture
def fake_repo(tmp_path, monkeypatch):
    """A fake <repo> with soundfonts/<Arachno .sf2>, with setup_tracks'
    repo lookup pointed at it, and its console output silenced."""
    repo_dir = tmp_path / "repo"
    soundfonts_dir = repo_dir / "soundfonts"
    soundfonts_dir.mkdir(parents=True)
    (soundfonts_dir / REAL_ARACHNO_SF2_NAME).write_bytes(b"")  # only the filename matters

    # _repo_dir derives <repo> from this module's own file location (4 levels
    # up from src/Scripts/MIDI-GPT/<this file>.py) via os.path.realpath(__file__).
    fake_module_path = repo_dir / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
    fake_module_path.parent.mkdir(parents=True)
    monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
    monkeypatch.setattr(setup_tracks, "print", lambda *a, **k: None, raising=False)
    return repo_dir


@pytest.fixture
def no_soundfont(tmp_path, monkeypatch):
    fake_module_path = tmp_path / "repo" / "src" / "Scripts" / "MIDI-GPT" / "MIDI-GPT Setup Tracks.py"
    fake_module_path.parent.mkdir(parents=True)
    monkeypatch.setattr(setup_tracks, "__file__", str(fake_module_path))
    monkeypatch.setattr(setup_tracks, "print", lambda *a, **k: None, raising=False)


def _write_converted_tree(root, presets=None):
    """Mimics Aria's converter output layout under root."""
    root.mkdir(parents=True, exist_ok=True)
    (root / "sf2_smpl.wav").write_bytes(b"RIFF")
    for bank, name in presets or [("000", "000_Grand_Piano.sfz"), ("128", "000_Standard_Drum_Kit.sfz")]:
        (root / bank).mkdir(exist_ok=True)
        (root / bank / name).write_text("<region>")


def _decode_vst_block(block):
    """Reverses _build_sforzando_vst_block: returns (header u32s, AriaSave
    XML text, trailing base64 lines after the body)."""
    lines = [ln.strip() for ln in block.splitlines()]
    assert lines[-1] == ">"
    b64_lines = lines[1:-1]
    header = base64.b64decode(b64_lines[0])
    header_u32s = struct.unpack("<11I", header)
    body_len = header_u32s[8]
    body = b""
    rest = b64_lines[1:]
    while rest and len(body) < body_len:
        body += base64.b64decode(rest.pop(0))
    assert len(body) == body_len, "header's length field doesn't match the body"
    i = body.find(b"CEGP")
    declared_len = struct.unpack_from("<I", body, i + 4)[0]
    xml = zlib.decompressobj().decompress(body[i + 8:])
    assert len(xml) == declared_len, "declared XML length doesn't match actual decompressed length"
    return header_u32s, body, xml.decode("utf-8"), rest


class TestSanitizeAriaName:
    """Aria's naming, confirmed against real captured slot names and the
    converter's actual output files: space and '.' become '_', everything
    else is left as-is."""

    def test_space_becomes_underscore(self):
        assert setup_tracks._sanitize_aria_name("Grand Piano") == "Grand_Piano"

    def test_period_becomes_underscore(self):
        assert setup_tracks._sanitize_aria_name("Version 1.0") == "Version_1_0"

    def test_hyphen_preserved(self):
        assert "-" in setup_tracks._sanitize_aria_name("SoundFont - Version")

    def test_matches_real_converter_folder_name(self):
        assert setup_tracks._sanitize_aria_name(REAL_ARACHNO_SF2_NAME) == SANITIZED_SF2

    def test_ampersand_and_parentheses_stay_literal(self):
        # The converter writes '087_Bass_&_Lead.sfz' and
        # '015_Dulcimer_(Santur).sfz' -- the name itself keeps them.
        assert setup_tracks._sanitize_aria_name("Bass & Lead") == "Bass_&_Lead"
        assert setup_tracks._sanitize_aria_name("Dulcimer (Santur)") == "Dulcimer_(Santur)"

    def test_xml_attr_escapes_ampersand_as_in_real_slot_names(self):
        # A real captured slot name for program 87 was '.../087_Bass_&amp;_Lead'
        # -- XML escaping of the literal '&', applied when embedding.
        assert setup_tracks._xml_attr("087_Bass_&_Lead") == "087_Bass_&amp;_Lead"
        assert setup_tracks._xml_attr('a"b') == "a&quot;b"


class TestFindArachnoSf2Name:
    def test_finds_the_sf2_in_soundfonts_dir(self, fake_repo):
        assert setup_tracks._find_arachno_sf2_name() == REAL_ARACHNO_SF2_NAME

    def test_none_when_soundfonts_dir_missing(self, no_soundfont):
        assert setup_tracks._find_arachno_sf2_name() is None

    def test_ignores_non_sf2_files(self, fake_repo):
        (fake_repo / "soundfonts" / REAL_ARACHNO_SF2_NAME).unlink()
        (fake_repo / "soundfonts" / "readme.txt").write_text("not a soundfont")
        assert setup_tracks._find_arachno_sf2_name() is None


class TestArachnoSlotName:
    def test_matches_real_captured_reference(self, fake_repo):
        assert (setup_tracks._arachno_slot_name(0, 0, "Grand Piano")
                == f"sf2/{SANITIZED_SF2}/000/000_Grand_Piano")

    def test_bank_and_program_are_zero_padded_three_digits(self, fake_repo):
        assert "/128/007_Drum_Kit" in setup_tracks._arachno_slot_name(128, 7, "Drum Kit")

    def test_none_when_soundfont_not_found(self, no_soundfont):
        assert setup_tracks._arachno_slot_name(0, 0, "Grand Piano") is None


class TestArachnoSfzPath:
    def test_matches_converter_layout(self, fake_repo):
        expected = (fake_repo / "soundfonts" / "sfz" / SANITIZED_SF2 / "000" / "000_Grand_Piano.sfz")
        assert setup_tracks._arachno_sfz_path(0, 0, "Grand Piano") == str(expected).replace("\\", "/")

    def test_uses_forward_slashes_like_sforzando(self, fake_repo):
        assert "\\" not in setup_tracks._arachno_sfz_path(0, 0, "Grand Piano")

    def test_drums_and_special_characters(self, fake_repo):
        assert setup_tracks._arachno_sfz_path(*setup_tracks.ARACHNO_DRUM_KIT).endswith(
            "/128/000_Standard_Drum_Kit.sfz")
        assert setup_tracks._arachno_sfz_path(0, 87, "Bass & Lead").endswith("/000/087_Bass_&_Lead.sfz")

    def test_none_when_soundfont_not_found(self, no_soundfont):
        assert setup_tracks._arachno_sfz_path(0, 0, "Grand Piano") is None


class TestInstrumentSlot:
    def test_file_form(self, fake_repo):
        name, bank_id = setup_tracks._instrument_slot(0, use_sfz_files=True)
        assert name.endswith("/000/000_Grand_Piano.sfz") and bank_id == -1

    def test_bank_form(self, fake_repo):
        assert setup_tracks._instrument_slot(128, use_sfz_files=False) == (
            f"sf2/{SANITIZED_SF2}/128/000_Standard_Drum_Kit", 4000)

    def test_none_when_soundfont_not_found(self, no_soundfont):
        assert setup_tracks._instrument_slot(0, use_sfz_files=True) is None


class TestBuildSforzandoVstBlock:
    @pytest.mark.parametrize("fmt", ["vst2", "vst3"])
    def test_file_form_xml(self, fmt):
        _, _, xml, _ = _decode_vst_block(
            setup_tracks._build_sforzando_vst_block("C:/x/000/087_Bass_&_Lead.sfz", -1, fmt))
        assert 'name="C:/x/000/087_Bass_&amp;_Lead.sfz" bankId="-1"' in xml

    @pytest.mark.parametrize("fmt", ["vst2", "vst3"])
    def test_bank_form_xml(self, fmt):
        _, _, xml, _ = _decode_vst_block(
            setup_tracks._build_sforzando_vst_block(f"sf2/{SANITIZED_SF2}/000/000_Grand_Piano", 4000, fmt))
        assert f'name="sf2/{SANITIZED_SF2}/000/000_Grand_Piano" bankId="4000"' in xml

    def test_vst3_matches_real_windows_capture(self):
        block = setup_tracks._build_sforzando_vst_block("C:/x.sfz", -1, "vst3")
        lines = block.splitlines()
        assert lines[0].strip() == REAL_VST3_LINE
        header_u32s, body, _, rest = _decode_vst_block(block)
        assert header_u32s[:8] + header_u32s[9:] == REAL_VST3_HEADER_U32S[:8] + REAL_VST3_HEADER_U32S[9:]
        # Body layout captured from REAPER: [len(blob)+8, 1, 0, len(blob)] + blob + 8 zero bytes.
        blob_len = struct.unpack_from("<I", body, 12)[0]
        assert struct.unpack_from("<3I", body, 0) == (blob_len + 8, 1, 0)
        assert body[16:20] == b"CEGP" and len(body) == 16 + blob_len + 8 and body[-8:] == bytes(8)
        assert rest == ["AAAAAAAA"]

    def test_vst2_keeps_captured_macos_format(self):
        block = setup_tracks._build_sforzando_vst_block("C:/x.sfz", -1, "vst2")
        assert block.splitlines()[0].strip().startswith('<VST "VSTi: sforzando')
        header_u32s, body, _, rest = _decode_vst_block(block)
        assert body.startswith(b"CEGP") and rest == []

    @pytest.mark.parametrize("fmt", ["vst2", "vst3"])
    def test_all_presets_encode_and_decode_cleanly(self, fake_repo, fmt):
        # Every GM program and the drum kit -- the thing that would silently
        # corrupt if the length math were wrong for some name lengths.
        for instrument in list(range(128)) + [128]:
            name, bank_id = setup_tracks._instrument_slot(instrument, use_sfz_files=True)
            _, _, xml, _ = _decode_vst_block(setup_tracks._build_sforzando_vst_block(name, bank_id, fmt))
            assert f'name="{setup_tracks._xml_attr(name)}"' in xml

    def test_valid_xml_structure(self):
        _, _, xml, _ = _decode_vst_block(setup_tracks._build_sforzando_vst_block("C:/x.sfz", -1, "vst3"))
        assert xml.startswith('<?xml version="1.0" ?>')
        assert xml.endswith("</AriaSave>")
        assert xml.count("<Slot") == 1
        assert xml.count("<Main") == 16

    @pytest.mark.parametrize("fmt", ["vst2", "vst3"])
    def test_every_payload_line_is_base64(self, fmt):
        lines = setup_tracks._build_sforzando_vst_block("C:/x.sfz", -1, fmt).splitlines()
        for line in lines[1:-1]:
            base64.b64decode(line.strip(), validate=True)


class TestBuildSourceTrackChunk:
    def test_wraps_vst_block_in_track_and_fxchain(self):
        block = setup_tracks._build_sforzando_vst_block("C:/x.sfz", -1, "vst3")
        chunk = setup_tracks._build_source_track_chunk("MIDI-GPT source", block)
        assert chunk.startswith("<TRACK\n")
        assert "  NAME MIDI-GPT source\n" in chunk
        assert "  <FXCHAIN\n" in chunk
        assert block in chunk
        assert chunk.endswith("  >\n>\n")


class TestEnsureArachnoSfz:
    def _root(self, repo):
        return repo / "soundfonts" / "sfz" / SANITIZED_SF2

    def test_already_converted_skips_converter(self, fake_repo, monkeypatch):
        _write_converted_tree(self._root(fake_repo))
        monkeypatch.setattr(setup_tracks, "_find_aria_converter", lambda: pytest.fail("converter called"))
        assert setup_tracks.ensure_arachno_sfz() == (True, None)

    def test_converts_with_arias_arguments_and_moves_into_place(self, fake_repo, monkeypatch):
        calls = []
        monkeypatch.setattr(setup_tracks, "_find_aria_converter", lambda: "RIFF2sfz")

        def fake_run(args, **kwargs):
            calls.append(args)
            # Like the real converter: <out dir>/<sanitized sf2 name>/...
            _write_converted_tree(__import__("pathlib").Path(args[2]) / SANITIZED_SF2)
            return subprocess.CompletedProcess(args, 0)

        monkeypatch.setattr(setup_tracks.subprocess, "run", fake_run)
        assert setup_tracks.ensure_arachno_sfz() == (True, None)
        assert len(calls) == 1
        converter, sf2, out_dir, list_file = calls[0]
        assert converter == "RIFF2sfz"
        assert sf2 == str(fake_repo / "soundfonts" / REAL_ARACHNO_SF2_NAME)
        assert list_file.startswith(out_dir)
        assert (self._root(fake_repo) / "000" / "000_Grand_Piano.sfz").is_file()
        assert not (fake_repo / "soundfonts" / "sfz.converting").exists()

    def test_failed_conversion_leaves_nothing_behind(self, fake_repo, monkeypatch):
        monkeypatch.setattr(setup_tracks, "_find_aria_converter", lambda: "RIFF2sfz")

        def fake_run(args, **kwargs):
            # Partial output, then a failure exit code.
            (__import__("pathlib").Path(args[2]) / SANITIZED_SF2 / "000").mkdir(parents=True)
            return subprocess.CompletedProcess(args, 3)

        monkeypatch.setattr(setup_tracks.subprocess, "run", fake_run)
        ok, reason = setup_tracks.ensure_arachno_sfz()
        assert not ok and "exit code 3" in reason
        assert not self._root(fake_repo).exists()
        assert not (fake_repo / "soundfonts" / "sfz.converting").exists()

    def test_changed_output_layout_is_detected(self, fake_repo, monkeypatch):
        # If a future converter names things differently, don't use it.
        monkeypatch.setattr(setup_tracks, "_find_aria_converter", lambda: "RIFF2sfz")

        def fake_run(args, **kwargs):
            _write_converted_tree(__import__("pathlib").Path(args[2]) / "SomethingElse")
            return subprocess.CompletedProcess(args, 0)

        monkeypatch.setattr(setup_tracks.subprocess, "run", fake_run)
        ok, _ = setup_tracks.ensure_arachno_sfz()
        assert not ok and not self._root(fake_repo).exists()

    def test_no_converter(self, fake_repo, monkeypatch):
        monkeypatch.setattr(setup_tracks, "_find_aria_converter", lambda: None)
        ok, reason = setup_tracks.ensure_arachno_sfz()
        assert not ok and "converter" in reason

    def test_no_soundfont(self, no_soundfont):
        ok, reason = setup_tracks.ensure_arachno_sfz()
        assert not ok and "isn't downloaded" in reason


class TestPrepareInstrumentSetup:
    """Option order: converted .sfz files; else Aria's bank if it holds
    Arachno; else stop with manual-import instructions rather than add
    silent instruments."""

    @pytest.fixture(autouse=True)
    def _vst3(self, monkeypatch):
        monkeypatch.setattr(setup_tracks, "_sforzando_plugin_format", lambda: "vst3")

    def test_uses_sfz_files_when_converted(self, fake_repo, monkeypatch):
        monkeypatch.setattr(setup_tracks, "ensure_arachno_sfz", lambda: (True, None))
        assert setup_tracks.prepare_instrument_setup() == {"plugin_format": "vst3", "use_sfz_files": True}

    def test_falls_back_to_aria_bank_when_it_has_arachno(self, fake_repo, monkeypatch):
        monkeypatch.setattr(setup_tracks, "ensure_arachno_sfz", lambda: (False, "no converter"))
        monkeypatch.setattr(setup_tracks, "_aria_bank_has_arachno", lambda: True)
        assert setup_tracks.prepare_instrument_setup() == {"plugin_format": "vst3", "use_sfz_files": False}

    def test_stops_with_instructions_when_bank_lacks_arachno(self, fake_repo, monkeypatch):
        printed = []
        monkeypatch.setattr(setup_tracks, "print", lambda *a, **k: printed.append(" ".join(map(str, a))), raising=False)
        monkeypatch.setattr(setup_tracks, "ensure_arachno_sfz", lambda: (False, "no converter"))
        monkeypatch.setattr(setup_tracks, "_aria_bank_has_arachno", lambda: False)
        assert setup_tracks.prepare_instrument_setup() is None
        assert any("drag" in p and REAL_ARACHNO_SF2_NAME in p for p in printed)

    def test_unknown_bank_state_uses_bank_with_a_note(self, fake_repo, monkeypatch):
        printed = []
        monkeypatch.setattr(setup_tracks, "print", lambda *a, **k: printed.append(" ".join(map(str, a))), raising=False)
        monkeypatch.setattr(setup_tracks, "ensure_arachno_sfz", lambda: (False, "no converter"))
        monkeypatch.setattr(setup_tracks, "_aria_bank_has_arachno", lambda: None)
        assert setup_tracks.prepare_instrument_setup() == {"plugin_format": "vst3", "use_sfz_files": False}
        assert any("drag" in p for p in printed)

    def test_no_sforzando(self, fake_repo, monkeypatch):
        printed = []
        monkeypatch.setattr(setup_tracks, "print", lambda *a, **k: printed.append(" ".join(map(str, a))), raising=False)
        monkeypatch.setattr(setup_tracks, "_sforzando_plugin_format", lambda: None)
        monkeypatch.setattr(setup_tracks, "_sforzando_au_or_clap_only", lambda: False)
        assert setup_tracks.prepare_instrument_setup() is None
        assert any("isn't in REAPER's plugin list" in p for p in printed)

    def test_au_or_clap_only_gets_a_specific_message(self, fake_repo, monkeypatch):
        printed = []
        monkeypatch.setattr(setup_tracks, "print", lambda *a, **k: printed.append(" ".join(map(str, a))), raising=False)
        monkeypatch.setattr(setup_tracks, "_sforzando_plugin_format", lambda: None)
        monkeypatch.setattr(setup_tracks, "_sforzando_au_or_clap_only", lambda: True)
        assert setup_tracks.prepare_instrument_setup() is None
        assert any("only as AU or CLAP" in p for p in printed)


class TestSforzandoPluginFormat:
    def _resource_dir(self, tmp_path, monkeypatch, system, cache_lines):
        monkeypatch.setattr(setup_tracks, "RPR_GetResourcePath", lambda: str(tmp_path), raising=False)
        monkeypatch.setattr(setup_tracks.platform, "system", lambda: system)
        if cache_lines is not None:
            (tmp_path / "reaper-vstplugins64.ini").write_text("[vstcache]\n" + "\n".join(cache_lines) + "\n")

    def test_windows_vst3(self, tmp_path, monkeypatch):
        # The real line from a Windows REAPER's plugin cache.
        self._resource_dir(tmp_path, monkeypatch, "Windows", [
            "sforzando.vst3=00A061FEF891DC01,395535903{5C5CA79682FC437AB6539BA204BAB349,"
            "sforzando (Plogue Art et Technologie, Inc)!!!VSTi"])
        assert setup_tracks._sforzando_plugin_format() == "vst3"

    def test_macos_prefers_vst2_when_both(self, tmp_path, monkeypatch):
        self._resource_dir(tmp_path, monkeypatch, "Darwin", ["sforzando.vst3=x", "sforzando.vst=x"])
        assert setup_tracks._sforzando_plugin_format() == "vst2"

    def test_macos_uses_vst3_when_only_vst3(self, tmp_path, monkeypatch):
        self._resource_dir(tmp_path, monkeypatch, "Darwin", ["sforzando.vst3=x"])
        assert setup_tracks._sforzando_plugin_format() == "vst3"

    def test_not_scanned(self, tmp_path, monkeypatch):
        self._resource_dir(tmp_path, monkeypatch, "Windows", ["reasynth.dll=x"])
        assert setup_tracks._sforzando_plugin_format() is None

    def test_no_cache_assumes_platform_default(self, tmp_path, monkeypatch):
        self._resource_dir(tmp_path, monkeypatch, "Windows", None)
        assert setup_tracks._sforzando_plugin_format() == "vst3"


class TestSforzandoAuOrClapOnly:
    def _resource_dir(self, tmp_path, monkeypatch):
        monkeypatch.setattr(setup_tracks, "RPR_GetResourcePath", lambda: str(tmp_path), raising=False)

    def test_true_for_real_au_cache_line(self, tmp_path, monkeypatch):
        # The real line from a macOS REAPER's AU cache -- a free-form
        # "<manufacturer>: <name>" key, not a fixed filename like VST/CLAP.
        self._resource_dir(tmp_path, monkeypatch)
        (tmp_path / "reaper-auplugins_arm64.ini").write_text(
            "[auplugins]\nPlogue Art et Technologie: sforzando=<inst>\n")
        assert setup_tracks._sforzando_au_or_clap_only() is True

    def test_true_for_real_clap_cache_line(self, tmp_path, monkeypatch):
        self._resource_dir(tmp_path, monkeypatch)
        (tmp_path / "reaper-clap-macos-aarch64.ini").write_text(
            '[sforzando.clap]\ncom.Plogue Art et Technologie, Inc.sforzando=1|sforzando '
            '(Plogue Art et Technologie, Inc)\n')
        assert setup_tracks._sforzando_au_or_clap_only() is True

    def test_false_when_absent(self, tmp_path, monkeypatch):
        self._resource_dir(tmp_path, monkeypatch)
        (tmp_path / "reaper-auplugins_arm64.ini").write_text("[auplugins]\nApple: AUDelay=<!inst>\n")
        assert setup_tracks._sforzando_au_or_clap_only() is False

    def test_false_when_no_caches_at_all(self, tmp_path, monkeypatch):
        self._resource_dir(tmp_path, monkeypatch)
        assert setup_tracks._sforzando_au_or_clap_only() is False


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
