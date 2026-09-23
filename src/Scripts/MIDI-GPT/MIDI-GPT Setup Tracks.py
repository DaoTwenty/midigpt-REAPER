# -*- coding: utf-8 -*-
"""
@description MIDI-GPT Setup Tracks
@author Paul Triana
@version 1.0
@about
  Auto-configure MIDI-GPT tracks. For every track in the project:
  1. Detect the track's intended GM instrument from the actual MIDI content
     (channel 10 -> drums, otherwise the track's first Program Change
     event) rather than the track name -- importing a multi-track MIDI file
     usually gives every track the same name (the file name), so name
     matching alone can't tell tracks apart. Tracks with no channel/PC info
     to go on are prompted for individually, via a native dropdown list on
     macOS (falls back to a single keyword-entry dialog elsewhere/if
     cancelled). The track is then renamed to the resolved instrument's
     canonical name (see INSTRUMENTS.md), so tracks are readable and
     distinguishable at a glance.
  2. Add an instrument if the track has none yet, with the correct GM
     program already selected -- no template track, no clone source, no
     manual setup, ever (see get_or_create_instrument_source and the
     module comment above ARACHNO_MELODIC_NAMES for how). A throwaway
     track is generated per distinct instrument needed this run and
     cloned from via TrackFX_CopyToTrack (the official, FX-chain-only copy
     API, so it never touches the destination track's items/name/etc.),
     then deleted.

This automates the manual per-track setup described in VST.md -- run it
right after importing a MIDI file, or after adding new tracks, instead of
adding the instrument plugin by hand on every track.

Safe to re-run: a track's instrument is only ever touched by this script if
the script added it in the first place (tracked per-track in the project) --
on any instrument the user added or changed by hand, re-running leaves it
alone.
"""

import sys
import base64
import glob
import json
import os
import platform
import shutil
import struct
import subprocess
import time
import zlib
from xml.sax.saxutils import escape as xml_escape

from reaper_python import *
# GM_INTERNAL_NAMES/GM_NAME_TO_INSTRUMENT live in midi_extraction.py (also
# needs them, for get_instrument_from_track_name()'s exact-name match) --
# imported from there rather than duplicated here so the two can't drift.
from midi_extraction import INST_TO_MATCHING_STRINGS, GM_INTERNAL_NAMES, GM_NAME_TO_INSTRUMENT

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

EXT_STATE_SECTION = "MIDI-GPT"

# ---------------------------------------------------------------------------
# Fully-automatic Sforzando+Arachno instrument generation -- no template
# track, no clone source, no manual per-instrument setup, ever.
#
# Sforzando's state is a small, plain-text XML blob (Aria Engine's
# "AriaSave" format) whose one <Slot> says what's loaded. Reverse-engineered
# from real captured FX chunks (via REAPER's GetTrackStateChunk / saved
# projects), it can reference an instrument two ways:
#   - By Aria bank: name="sf2/Arachno_SoundFont_-_Version_1_0_sf2/000/000_Grand_Piano"
#     bankId="4000". Bank 4000 is whatever folder Aria's own SF2 import last
#     converted into (its global "Converted_path" setting) -- so this only
#     resolves on a machine where Arachno was imported into Sforzando by
#     hand at least once, and breaks again if the user later imports any
#     other SoundFont. Aria logs "... from bank:4000 was not found!" and the
#     instrument stays silent.
#   - By file: name="C:/.../000/000_Grand_Piano.sfz" bankId="-1" -- an
#     absolute path to a converted .sfz, independent of Aria's bank state.
# This script uses the file form: it converts Arachno.sf2 into .sfz presets
# itself, once, with Aria's own converter (see ensure_arachno_sfz), into
# <repo>/soundfonts/sfz/ -- deliberately not Aria's ARIAConverted folder,
# so it never interacts with Aria's own import state. Where Aria's
# converter can't be found or its output doesn't check out (see
# _find_aria_converter, ensure_arachno_sfz), it falls back to the bank form
# -- only if that bank actually holds Arachno, i.e. after a manual import;
# otherwise it adds nothing and says how to do that import (see
# prepare_instrument_setup).
#
# Either way the rest of the XML is identical, so any of Arachno's presets
# can be selected by swapping the slot reference -- see ARACHNO_MELODIC_NAMES
# below for the preset name table, extracted directly from Arachno.sf2's
# own phdr (preset header) chunk -- standard SF2/RIFF format, not guessed.
#
# The XML is wrapped as a "CEGP"-tagged, zlib-compressed blob (Sforzando's
# own plugin state, the same in its VST2 and VST3 builds), inside REAPER's
# per-format FX chunk wrapper -- see _SFZ_FORMATS. Both wrappers were
# captured from real chunks; the VST3 one rebuilds byte-for-byte from its
# blob (verified against two real Windows captures).
# ---------------------------------------------------------------------------

_SFZ_CEGP_TAG = b"CEGP"
_SFZ_PLUGIN_UID = "5C5CA79682FC437AB6539BA204BAB349"

# REAPER's FX chunk wrapper, per plugin format.
#   VST2 (captured on macOS): a fixed 44-byte header whose u32 at offset 32
#     is the CEGP blob's length, followed by the blob itself.
#   VST3 (captured on Windows): the same header layout (VST3 plugin id,
#     REAPER's 0xFEED5EEE magic, pin config), with the u32 at offset 32 the
#     body length; body = [len(blob)+8, 1, 0, len(blob)] + blob + 8 zero
#     bytes; then a final line of 6 zero bytes.
_SFZ_FORMATS = {
    "vst2": {
        "line": '    <VST "VSTi: sforzando (Plogue Art et Technologie, Inc)" sforzando.vst 0 "" '
                f'1347176273<{_SFZ_PLUGIN_UID}> ""',
        "header_b64": "UUdMUO5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAACxAQAAAQAAAAAAAAA=",
    },
    "vst3": {
        "line": '    <VST "VST3i: sforzando (Plogue Art et Technologie, Inc)" sforzando.vst3 0 "" '
                f'395535903{{{_SFZ_PLUGIN_UID}}} ""',
        "header_b64": "H2aTF+5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAAAAAAAAAQAAAP//AAA=",
    },
}
_SFZ_HEADER_LEN_OFFSET = 32

# Where ensure_arachno_sfz converts Arachno.sf2 to, under <repo>/soundfonts/.
_SFZ_DIR_NAME = "sfz"

_ARIA_XML_TEMPLATE = (
    '<?xml version="1.0" ?>\n'
    '<AriaSave version="1982" productID="1014">\n'
    '    <Settings quality="1" streaming="32" MIDIOutMode="1" automationSlot="0" liveMode="0" sc="4" scala="01 - equal.scl" scalaCenter="60" globalTuning="0" />\n'
    '    <Slot id="0" name="{slot_name}" bankId="{bank_id}" version="0" channel="-1" poly="64" tuning="0" pb_range="-1" ptrans="0" mtrans="0" moctave="0" sc="3" mute="0">\n'
    + "".join(f'        <Main id="{i}" value="{1 if i == 0 else 0}" />\n' for i in range(16))
    + '    </Slot>\n'
    '    <EffectSlot id="0" sc="4" name="Ambience" bankId="1014" version="1949" procMode="0" />\n'
    '    <GUI id="0" activeISlot="0" activeESlot="0" selectedTab="-1" />\n'
    '</AriaSave>'
)

# GM program 0-127 -> Arachno's own preset name (bank 0), read straight out
# of Arachno.sf2's phdr chunk -- these are Arachno's names, not always the
# same wording as GM_INTERNAL_NAMES above (e.g. program 0 is "Grand Piano"
# here vs. "acoustic_grand_piano" there), but in the same GM program order.
ARACHNO_MELODIC_NAMES = [
    "Grand Piano", "Bright Piano", "Rock Piano", "Honky-Tonk Piano",
    "Electric Piano", "Crystal Piano", "Harpsichord", "Clavinet",
    "Celesta", "Glockenspiel", "Music Box", "Vibraphone",
    "Marimba", "Xylophone", "Tubular Bells", "Dulcimer (Santur)",
    "DrawBar Organ", "Percussive Organ", "Rock Organ", "Church Organ",
    "Reed Organ", "Accordion", "Harmonica", "Bandoneon",
    "Nylon Guitar", "Steel String Guitar", "Jazz Guitar", "Clean Guitar",
    "Muted Guitar", "Overdrive Guitar", "Distortion Guitar", "Guitar Harmonics",
    "Acoustic Bass", "Fingered Bass", "Picked Bass", "Fretless Bass",
    "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
    "Violin", "Viola", "Cello", "ContraBass",
    "Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani",
    "Strings Ensemble 1", "Strings Ensemble 2", "Synth Strings 1", "Synth Strings 2",
    "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
    "Trumpet", "Trombone", "Tuba", "Muted Trumpet",
    "French Horns", "Brass Section", "Synth Brass 1", "Synth Brass 2",
    "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax",
    "Oboe", "English Horns", "Bassoon", "Clarinet",
    "Piccolo", "Flute", "Recorder", "Pan Flute",
    "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
    "Square Wave", "Saw Wave", "Synth Calliope", "Chiffer Lead",
    "Charang", "Solo Voice", "5th Saw Wave", "Bass & Lead",
    "Fantasia (New Age)", "Warm Pad", "Poly Synth", "Space Voice",
    "Bowed Glass", "Metal Pad", "Halo Pad", "Sweep Pad",
    "Ice Rain", "Sound Track", "Crystal", "Atmosphere",
    "Brightness", "Goblin", "Echo Drops", "Star Theme",
    "Sitar", "Banjo", "Shamisen", "Koto",
    "Kalimba", "Bag Pipe", "Fiddle", "Shannai",
    "Tinkle Bell", "Agogo", "Steel Drums", "Wood Block",
    "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
    "Guitar Fret Noise", "Breath Noise", "Sea Shore", "Bird Tweets",
    "Telephone", "Helicopter", "Applause", "Gun Shot",
]

# instrument 128 ("drums") -> Arachno's default GM drum kit (bank 128).
# Arachno actually ships 9 different kits on bank 128; this is the
# standard/default one -- picking a different one isn't exposed today.
ARACHNO_DRUM_KIT = (128, 0, "Standard Drum Kit")

def _sanitize_aria_name(name):
    """Aria's own name sanitizer, as used both in its bank slot references
    and in the file/folder names its converter writes -- confirmed against
    real captured slot names and the converter's actual output: space and
    '.' become '_' (e.g. 'Grand Piano' -> 'Grand_Piano', and the SoundFont
    filename 'Arachno SoundFont - Version 1.0.sf2' ->
    'Arachno_SoundFont_-_Version_1_0_sf2' -- the literal '-' survives), and
    everything else is left as-is, including '&', '(' and ')' (the
    converter writes '087_Bass_&_Lead.sfz', '015_Dulcimer_(Santur).sfz').
    Raw text, not XML -- see _xml_attr for escaping it into the AriaSave
    XML (where '&' becomes '&amp;', as in real captured slot names)."""
    return name.replace(" ", "_").replace(".", "_")

def _xml_attr(value):
    """Escape a string for an XML attribute value in _ARIA_XML_TEMPLATE."""
    return xml_escape(value, {'"': "&quot;"})

def _repo_dir():
    # This file lives at <repo>/src/Scripts/MIDI-GPT/ -- four levels down
    # from <repo> itself (it's loaded through a symlink/junction from
    # REAPER's Scripts folder, so realpath() is needed to resolve back to it).
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.realpath(__file__)))))

def _soundfonts_dir():
    return os.path.join(_repo_dir(), "soundfonts")

def _find_arachno_sf2_name():
    """The exact filename of the Arachno SoundFont the installer downloads
    into <repo>/soundfonts/ -- read directly off disk rather than
    hardcoded, so this keeps working even if Arachnosoft ever ships a
    differently-named file. Returns None if it's not there yet."""
    try:
        for entry in sorted(os.listdir(_soundfonts_dir())):
            if entry.lower().endswith(".sf2"):
                return entry
    except OSError:
        pass
    return None

def _arachno_preset(instrument):
    """(bank, program, Arachno preset name) for a GM instrument 0-127, or
    128 for drums."""
    if instrument == 128:
        return ARACHNO_DRUM_KIT
    return 0, instrument, ARACHNO_MELODIC_NAMES[instrument]

def _arachno_slot_name(bank, program, preset_name):
    """Aria bank 4000 reference (see the module comment) -- raw, not
    XML-escaped. None if the SoundFont isn't downloaded."""
    sf2_name = _find_arachno_sf2_name()
    if sf2_name is None:
        return None
    return f"sf2/{_sanitize_aria_name(sf2_name)}/{bank:03d}/{program:03d}_{_sanitize_aria_name(preset_name)}"

def _arachno_sfz_root():
    """Where ensure_arachno_sfz's conversion puts Arachno's .sfz presets:
    <repo>/soundfonts/sfz/<sanitized .sf2 name>/ (the converter names that
    last folder itself). None if the SoundFont isn't downloaded."""
    sf2_name = _find_arachno_sf2_name()
    if sf2_name is None:
        return None
    return os.path.join(_soundfonts_dir(), _SFZ_DIR_NAME, _sanitize_aria_name(sf2_name))

def _arachno_sfz_path(bank, program, preset_name):
    """Absolute path to one converted .sfz preset, with forward slashes as
    Sforzando itself saves it. None if the SoundFont isn't downloaded."""
    root = _arachno_sfz_root()
    if root is None:
        return None
    path = os.path.join(root, f"{bank:03d}", f"{program:03d}_{_sanitize_aria_name(preset_name)}.sfz")
    return path.replace("\\", "/")

# ---------------------------------------------------------------------------
# One-time .sf2 -> .sfz conversion, with Aria's own converter
# ---------------------------------------------------------------------------

def _macos_aria_plist():
    """Parsed contents of Aria's macOS preferences
    (~/Library/Preferences/com.plogue.aria.plist -- confirmed on a real
    install: holds 'base_dir' (Aria's install folder, e.g.
    "/Library/Application Support/Plogue/Aria", where RIFF2sfz lives
    alongside Aria.bundle) and 'Converted_path' (last manual SF2 import,
    once one has been done). None if it can't be read."""
    import plistlib
    path = os.path.expanduser("~/Library/Preferences/com.plogue.aria.plist")
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        return None

_LINUX_ARIA_CONFIG = "/opt/Plogue/Aria/.config"

def _find_aria_converter():
    """Path to Aria's SoundFont converter (Plogue's RIFF2sfz), installed
    alongside Sforzando, or None. On Windows, Aria registers it under
    HKLM\\SOFTWARE\\Plogue Art et Technologie, Inc\\Aria\\Converters. On
    macOS, it lives at <base_dir>/RIFF2sfz, next to Aria.bundle, where
    base_dir is read from Aria's own preferences plist (confirmed on a
    real install: RIFF2sfz 1.98, same "input output_path results.txt"
    argument order as Windows). On Linux, the plogue-aria .deb installs it
    as <base_dir>/riff2sfz and lists it in /opt/Plogue/Aria/.config, a JSON
    file Aria and Sforzando read from that fixed path."""
    system = platform.system()
    if system == "Windows":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                                r"SOFTWARE\Plogue Art et Technologie, Inc\Aria\Converters",
                                0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as key:
                path = winreg.QueryValueEx(key, "sf2")[0]
        except OSError:
            return None
        return path if os.path.isfile(path) else None
    if system == "Darwin":
        plist = _macos_aria_plist()
        base_dir = plist.get("base_dir") if plist else None
        if not base_dir:
            return None
        path = os.path.join(base_dir, "RIFF2sfz")
        return path if os.path.isfile(path) else None
    if system == "Linux":
        try:
            with open(_LINUX_ARIA_CONFIG, encoding="utf-8") as f:
                config = json.load(f)
        except (OSError, ValueError):
            return None
        path = (config.get("Converters") or {}).get("sf2") \
            or os.path.join(config.get("base_dir", ""), "riff2sfz")
        return path if os.path.isfile(path) else None
    return None

def _sfz_conversion_complete(root):
    """Whether root holds a converted Arachno: the sample file every preset
    shares, plus the default melodic and drum presets. (A partial tree
    can't end up here -- ensure_arachno_sfz converts into a scratch folder
    and only moves the result into place once this check passes on it.)"""
    return all(os.path.isfile(os.path.join(root, *parts)) for parts in (
        ("sf2_smpl.wav",),
        ("000", "000_Grand_Piano.sfz"),
        ("128", "000_Standard_Drum_Kit.sfz"),
    ))

def ensure_arachno_sfz():
    """Make sure Arachno's .sfz presets exist under <repo>/soundfonts/sfz/,
    converting the .sf2 once with Aria's own converter if needed -- the same
    conversion Sforzando runs on a manual import, but into this repo's own
    folder and without touching Aria's settings. Returns (True, None) when
    ready, or (False, reason) when not (callers fall back to Aria's bank
    reference)."""
    sf2_name = _find_arachno_sf2_name()
    if sf2_name is None:
        return False, "the Arachno SoundFont isn't downloaded (re-run the installer)"
    root = _arachno_sfz_root()
    if _sfz_conversion_complete(root):
        return True, None

    converter = _find_aria_converter()
    if converter is None:
        return False, "Aria's SoundFont converter wasn't found (it's installed with Sforzando)"

    print("Converting the Arachno SoundFont for Sforzando (one-time, a few seconds)...\n")
    out_dir = os.path.join(_soundfonts_dir(), _SFZ_DIR_NAME)
    work_dir = os.path.join(_soundfonts_dir(), f"{_SFZ_DIR_NAME}.converting")
    shutil.rmtree(work_dir, ignore_errors=True)
    os.makedirs(work_dir)
    try:
        # Same arguments Sforzando passes (seen in Aria's own log): the .sf2,
        # an output folder, and a file it writes the list of presets to.
        result = subprocess.run(
            [converter, os.path.join(_soundfonts_dir(), sf2_name), work_dir,
             os.path.join(work_dir, "presets.ariac")],
            capture_output=True, timeout=600,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        converted_root = os.path.join(work_dir, os.path.basename(root))
        if result.returncode != 0 or not _sfz_conversion_complete(converted_root):
            return False, f"Aria's SoundFont converter failed (exit code {result.returncode})"
        # Converted into a scratch folder first, then moved into place, so an
        # interrupted run never leaves a half-written tree that looks finished.
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(out_dir, exist_ok=True)
        shutil.move(converted_root, root)
    except (OSError, subprocess.SubprocessError) as e:
        return False, f"converting the Arachno SoundFont failed ({e})"
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
    return True, None

def _aria_bank_has_arachno():
    """Whether Aria's bank 4000 (its last manual SF2 import -- see the
    module comment) currently holds Arachno, i.e. whether the bank-reference
    fallback would actually produce sound. True/False on Windows and macOS;
    on Windows Aria keeps the bank's folder in the registry (Converted_path),
    on macOS in its preferences plist (same key, confirmed on a real
    install to hold the same "<Converted_path>/sf2/<sanitized name>/..."
    layout as Windows). None where that can't be checked."""
    system = platform.system()
    if system not in ("Windows", "Darwin"):
        return None
    sf2_name = _find_arachno_sf2_name()
    if sf2_name is None:
        return False
    if system == "Windows":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                r"Software\Plogue Art et Technologie, Inc\Aria") as key:
                converted_path = winreg.QueryValueEx(key, "Converted_path")[0]
        except OSError:
            return False
    else:
        plist = _macos_aria_plist()
        converted_path = plist.get("Converted_path") if plist else None
        if not converted_path:
            return False
    return os.path.isfile(os.path.join(
        converted_path, "sf2", _sanitize_aria_name(sf2_name), "000", "000_Grand_Piano.sfz"))

def _manual_import_instructions():
    sf2_name = _find_arachno_sf2_name() or "the Arachno .sf2"
    # Sforzando's Linux build doesn't accept dropped files (Plogue's own beta
    # notes) -- only its Import menu works there.
    how = ("import it with Sforzando's Import menu (top left)"
           if platform.system() == "Linux" else "drag it onto Sforzando's window")
    return ("To set it up by hand, once: add Sforzando to any track, then\n"
            f"  {os.path.join(_soundfonts_dir(), sf2_name)}\n"
            f"-- {how}; it converts the SoundFont (a few seconds). "
            "Then run Setup Tracks again.")

# ---------------------------------------------------------------------------
# Which Sforzando build REAPER has
# ---------------------------------------------------------------------------

def _sforzando_plugin_format():
    """'vst3' or 'vst2' -- whichever Sforzando build REAPER has actually
    scanned (its reaper-vstplugins*.ini caches), preferring the build each
    platform's chunk format was captured from: VST2 on macOS, VST3
    elsewhere (Sforzando's Windows installer puts its VST2 in a folder
    REAPER doesn't scan by default). None if REAPER hasn't found Sforzando
    at all. If the caches can't be read, assumes that preferred build."""
    preferred, other = ("vst2", "vst3") if platform.system() == "Darwin" else ("vst3", "vst2")
    found = set()
    caches = glob.glob(os.path.join(RPR_GetResourcePath(), "reaper-vstplugins*.ini"))
    for cache in caches:
        try:
            with open(cache, encoding="utf-8", errors="replace") as f:
                for line in f:
                    key = line.split("=", 1)[0].strip().lower()
                    if key == "sforzando.vst3":
                        found.add("vst3")
                    elif key == "sforzando.vst":
                        found.add("vst2")
        except OSError:
            continue
    if not caches:
        return preferred
    for fmt in (preferred, other):
        if fmt in found:
            return fmt
    return None

def _sforzando_au_or_clap_only():
    """True if REAPER has scanned an AU or CLAP build of Sforzando --
    checked only when _sforzando_plugin_format() finds neither VST nor
    VST3, to tell "not installed" apart from "installed, but not in a
    supported format" (Setup Tracks has no FX chunk format for AU or
    CLAP, unlike VST/VST3 -- see VST.md). Matched by substring rather
    than an exact key, since AU's cache key is a free-form
    "<manufacturer>: <name>" string (e.g. "Plogue Art et Technologie:
    sforzando"), not a fixed filename like VST/CLAP's."""
    for pattern in ("reaper-auplugins*.ini", "reaper-clap*.ini"):
        for cache in glob.glob(os.path.join(RPR_GetResourcePath(), pattern)):
            try:
                with open(cache, encoding="utf-8", errors="replace") as f:
                    if "sforzando" in f.read().lower():
                        return True
            except OSError:
                continue
    return False

# ---------------------------------------------------------------------------
# Chunk building
# ---------------------------------------------------------------------------

def _instrument_slot(instrument, use_sfz_files):
    """(slot name, bankId) for a GM instrument -- a converted .sfz file
    path (bankId -1) if use_sfz_files, else Aria's bank reference (bankId
    4000). None if the SoundFont isn't downloaded."""
    bank, program, name = _arachno_preset(instrument)
    if use_sfz_files:
        path = _arachno_sfz_path(bank, program, name)
        return None if path is None else (path, -1)
    slot = _arachno_slot_name(bank, program, name)
    return None if slot is None else (slot, 4000)

def _build_sforzando_vst_block(slot_name, bank_id, plugin_format):
    """The '<VST ...> ... >' block text for a Sforzando instance with the
    given slot loaded (see _instrument_slot), in REAPER's chunk format for
    that plugin build (see _SFZ_FORMATS). Indented to sit directly inside
    an <FXCHAIN> block."""
    fmt = _SFZ_FORMATS[plugin_format]
    xml = _ARIA_XML_TEMPLATE.format(slot_name=_xml_attr(slot_name), bank_id=bank_id)
    xml_bytes = xml.encode("utf-8")
    cegp_blob = _SFZ_CEGP_TAG + struct.pack("<I", len(xml_bytes)) + zlib.compress(xml_bytes, 9)

    if plugin_format == "vst3":
        body = struct.pack("<4I", len(cegp_blob) + 8, 1, 0, len(cegp_blob)) + cegp_blob + bytes(8)
        tail = [base64.b64encode(bytes(6)).decode()]
    else:
        body = cegp_blob
        tail = []
    header = bytearray(base64.b64decode(fmt["header_b64"]))
    struct.pack_into("<I", header, _SFZ_HEADER_LEN_OFFSET, len(body))

    b64_body = base64.b64encode(body).decode()
    b64_lines = [base64.b64encode(bytes(header)).decode()]
    b64_lines += [b64_body[i:i + 128] for i in range(0, len(b64_body), 128)]
    b64_lines += tail

    lines = [fmt["line"]] + [f"      {ln}" for ln in b64_lines] + ["    >"]
    return "\n".join(lines)

def _build_source_track_chunk(track_name, vst_block):
    """A minimal, self-contained TRACK chunk with just the given Sforzando
    block as its FX chain -- for a brand new, throwaway track (see
    get_or_create_instrument_source). Never applied to a track that already
    has content: SetTrackStateChunk replaces the *whole* track."""
    return (
        "<TRACK\n"
        f"  NAME {track_name}\n"
        "  FX 1\n"
        "  <FXCHAIN\n"
        f"{vst_block}\n"
        "  >\n"
        ">\n"
    )


class _ReaperConsole:
    def write(self, s):
        RPR_ShowConsoleMsg(s)
    def flush(self):
        pass

sys.stdout = sys.stderr = _ReaperConsole()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_track_name(track):
    return RPR_GetSetMediaTrackInfo_String(track, "P_NAME", "", False)[3]

def set_track_name(track, name):
    RPR_GetSetMediaTrackInfo_String(track, "P_NAME", name, True)

def gm_internal_name(instrument):
    if instrument == 128:
        return "drums"
    if 0 <= instrument < len(GM_INTERNAL_NAMES):
        return GM_INTERNAL_NAMES[instrument]
    return f"program_{instrument}"

# ---------------------------------------------------------------------------
# Instrument detection (from MIDI content, not track name)
# ---------------------------------------------------------------------------

def _find_program_change(take):
    _, _, _, cc_cnt, _ = RPR_MIDI_CountEvts(take, 0, 0, 0)
    for c in range(cc_cnt):
        cc = RPR_MIDI_GetCC(take, c, 0, 0, 0, 0, 0, 0, 0)
        # cc: (retval, take, ccidx, selected, muted, ppqpos, chanmsg, chan, msg2, msg3)
        if cc[0] and cc[6] == 0xC0:
            return cc[8]
    return None

def detect_track_instrument(track):
    """Best-effort GM instrument detection straight from MIDI content:
    channel 10 (drums) wins; otherwise the track's first Program Change
    event, if any. Returns None if neither is present."""
    for j in range(RPR_CountTrackMediaItems(track)):
        item = RPR_GetTrackMediaItem(track, j)
        take = RPR_GetActiveTake(item)
        if not take or not RPR_TakeIsMIDI(take):
            continue

        _, _, note_cnt, _, _ = RPR_MIDI_CountEvts(take, 0, 0, 0)
        for n in range(min(note_cnt, 32)):
            note = RPR_MIDI_GetNote(take, n, 0, 0, 0, 0, 0, 0, 0)
            # note: (retval, take, noteidx, selected, muted, startppq, endppq, chan, pitch, vel)
            if note[0] and note[7] == 9:
                return 128

        program = _find_program_change(take)
        if program is not None:
            return program
    return None

def keyword_to_instrument(keyword):
    keyword = keyword.strip().lower()
    if not keyword:
        return None
    for inst_num, patterns in INST_TO_MATCHING_STRINGS.items():
        for pattern in patterns:
            if pattern in keyword:
                return inst_num
    return None

def _osascript_choose_from_list(title, prompt, options):
    """macOS-only native list picker (a real dropdown/list dialog), via
    AppleScript's 'choose from list'. Returns the chosen string, or None if
    unavailable, cancelled, or the option isn't installed (rare)."""
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')
    items = ", ".join(f'"{esc(o)}"' for o in options)
    script = (
        f'set chosen to choose from list {{{items}}} '
        f'with title "{esc(title)}" with prompt "{esc(prompt)}"\n'
        f'if chosen is false then\n'
        f'    return ""\n'
        f'else\n'
        f'    return item 1 of chosen\n'
        f'end if'
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=180,
        )
        out = result.stdout.strip()
        return out if out else None
    except Exception:
        return None

def pick_instrument_dropdown(track_name):
    """Native list-picker dialog listing every GM instrument, so the user
    selects instead of typing. Currently macOS only (AppleScript); returns
    None elsewhere so callers fall back to keyword entry."""
    if platform.system() != "Darwin":
        return None
    options = GM_INTERNAL_NAMES + ["drums"]
    choice = _osascript_choose_from_list(
        "MIDI-GPT", f"Instrument for track: {track_name}", options
    )
    return GM_NAME_TO_INSTRUMENT.get(choice) if choice else None

def detect_instruments(tracks):
    """Map track -> GM instrument number (or None if undetected), reading
    real MIDI content first, then falling back to the track's current name
    if it's already an exact canonical instrument name (e.g. a blank track
    resolved on a previous run -- it has no MIDI content to detect from, so
    without this check it would be re-prompted on every single run
    forever). Pure detection, no prompting -- see resolve_track_instruments
    for the native-dialog fallback built on top of this, and the dashboard
    (midigpt_dashboard/setup_panel.py) for the ReaImGui one."""
    resolved = {}
    for track in tracks:
        instrument = detect_track_instrument(track)
        if instrument is None:
            instrument = GM_NAME_TO_INSTRUMENT.get((get_track_name(track) or "").strip())
        resolved[track] = instrument
    return resolved


def resolve_track_instruments(tracks):
    """detect_instruments(), then prompt one-by-one for whatever it
    couldn't resolve (e.g. freshly-created tracks, or an imported file
    where every track shares the file's name). Native-dialog only -- used
    by this script's and MIDI-GPT Replace Instruments.py's own
    standalone/hotkey entry points; the dashboard has its own ReaImGui
    confirmation popup instead (see midigpt_dashboard/setup_panel.py) so it
    isn't limited to the macOS-only picker below.

    On macOS the fallback is the native dropdown list -- cancelling it is a
    deliberate 'skip this track' choice, so that track is just left
    unresolved rather than immediately re-prompted with a second, uglier
    dialog. The keyword-entry text dialog only ever appears on platforms
    without the native list picker, where it's the sole way to specify
    anything -- never as a fallback after a mac user already dismissed the
    list."""
    resolved = detect_instruments(tracks)
    ambiguous = [track for track in tracks if resolved[track] is None]

    has_native_picker = platform.system() == "Darwin"
    still_ambiguous = []
    for track in ambiguous:
        if has_native_picker:
            instrument = pick_instrument_dropdown(get_track_name(track) or "(unnamed)")
            if instrument is not None:
                resolved[track] = instrument
            # else: cancelled -- leave unresolved, don't nag with another dialog.
        else:
            still_ambiguous.append(track)

    if still_ambiguous:
        captions = ",".join(
            f"{get_track_name(t) or '(unnamed)'} - keyword (e.g. piano/bass/drums)"
            for t in still_ambiguous
        )
        defaults = ",".join("" for _ in still_ambiguous)
        ret, _, _, _, csv_out, _ = RPR_GetUserInputs(
            "MIDI-GPT: Track Instruments (could not auto-detect from MIDI)",
            len(still_ambiguous),
            captions,
            defaults,
            1024,
        )
        if ret:
            values = csv_out.split(",")
            for track, value in zip(still_ambiguous, values):
                instrument = keyword_to_instrument(value)
                if instrument is not None:
                    resolved[track] = instrument

    return resolved

# ---------------------------------------------------------------------------
# Per-track ownership, so re-running never touches an instrument the user
# added or changed by hand. Stored in the project (SetProjExtState), keyed
# by track GUID -- survives saves, doesn't leak across projects.
# ---------------------------------------------------------------------------

def get_track_guid(track):
    return RPR_GetSetMediaTrackInfo_String(track, "GUID", "", False)[3]

def is_owned(track):
    return RPR_GetProjExtState(0, EXT_STATE_SECTION, f"owned_{get_track_guid(track)}", "", 8)[0] > 0

def mark_owned(track):
    RPR_SetProjExtState(0, EXT_STATE_SECTION, f"owned_{get_track_guid(track)}", "1")

def is_sforzando(track, fx_index):
    name = RPR_TrackFX_GetFXName(track, fx_index, "", 256)[3]
    return "sforzando" in name.lower()

# ---------------------------------------------------------------------------
# Instrument sourcing -- one throwaway track per distinct instrument needed
# this run, generated from scratch (see _build_source_track_chunk above),
# copied from via the official TrackFX_CopyToTrack API (touches only the
# FX chain, never the destination track's items/name/etc.), then deleted.
# ---------------------------------------------------------------------------

def prepare_instrument_setup():
    """Once per run, before any instrument is added: which Sforzando build
    to generate chunks for, and whether the converted .sfz presets are
    available (converting them now if needed -- see ensure_arachno_sfz).
    Returns a dict for get_or_create_instrument_source, or None (after
    saying why) if Sforzando isn't available to REAPER at all."""
    plugin_format = _sforzando_plugin_format()
    if plugin_format is None:
        if _sforzando_au_or_clap_only():
            print("Sforzando is installed, but only as AU or CLAP -- Setup Tracks doesn't support "
                  "either (see VST.md). Install the VST or VST3 build instead, then in REAPER: "
                  "Options > Preferences > Plug-ins > VST > Re-scan.\n")
        else:
            print("Sforzando isn't in REAPER's plugin list -- install it (see VST.md), then in REAPER: "
                  "Options > Preferences > Plug-ins > VST > Re-scan.\n")
        return None
    use_sfz_files, reason = ensure_arachno_sfz()
    if use_sfz_files:
        return {"plugin_format": plugin_format, "use_sfz_files": True}

    # Fallback: Aria's own bank, as filled by a manual import into
    # Sforzando -- only worth using if it actually holds Arachno.
    if _find_arachno_sf2_name() is None:
        print(f"Can't add instruments: {reason}.\n")
        return None
    bank_ready = _aria_bank_has_arachno()
    if bank_ready is False:
        print(f"Can't add instruments with sound yet: {reason}.\n{_manual_import_instructions()}\n")
        return None
    if bank_ready is None:
        print(f"Note: {reason}, so instruments use Sforzando's imported copy of Arachno. "
              f"If they play no sound, Arachno hasn't been imported yet.\n{_manual_import_instructions()}\n")
    return {"plugin_format": plugin_format, "use_sfz_files": False}

def get_or_create_instrument_source(source_pool, instrument, setup):
    """Return a throwaway track whose only FX is a correctly configured
    Sforzando+Arachno instance for `instrument`, creating and caching one
    per distinct instrument the first time it's needed (source_pool is a
    plain dict the caller owns and cleans up via
    cleanup_instrument_sources; setup comes from prepare_instrument_setup).
    Returns None if Sforzando couldn't be instantiated -- cached too, so
    it's not retried for every track in the same run."""
    if instrument in source_pool:
        return source_pool[instrument]

    slot = _instrument_slot(instrument, setup["use_sfz_files"])
    track = None
    if slot is not None:
        vst_block = _build_sforzando_vst_block(slot[0], slot[1], setup["plugin_format"])
        chunk = _build_source_track_chunk("MIDI-GPT source", vst_block)
        idx = RPR_CountTracks(0)
        RPR_InsertTrackAtIndex(idx, False)
        track = RPR_GetTrack(0, idx)
        fx = RPR_TrackFX_GetInstrument(track) if track and RPR_SetTrackStateChunk(track, chunk, False) else -1
        # An FX slot alone isn't proof: REAPER keeps a placeholder slot for
        # a plugin it can't find (e.g. a chunk naming a build that isn't
        # installed), with no parameters behind it.
        ok = fx >= 0 and RPR_TrackFX_GetNumParams(track, fx) > 0
        if ok:
            # Give Sforzando's own (separately async) chunk restore a
            # moment to settle before anything copies off of it -- copying
            # mid-restore could carry over an incomplete state.
            time.sleep(0.6)
        else:
            if track:
                RPR_DeleteTrack(track)
            track = None

    source_pool[instrument] = track
    return track

def cleanup_instrument_sources(source_pool):
    for track in source_pool.values():
        if track is not None:
            RPR_DeleteTrack(track)
    source_pool.clear()

def ensure_instrument(track, instrument, source_pool, setup):
    """Add Sforzando+Arachno to `track` with the correct GM program already
    selected -- entirely generated (see get_or_create_instrument_source),
    no template/clone-source track to set up, no manual work, ever. Only
    touches tracks that don't already have an instrument, and never
    overwrites one the user added or changed by hand (see is_owned)."""
    fx_index = RPR_TrackFX_GetInstrument(track)
    if fx_index >= 0:
        if not is_owned(track) and is_sforzando(track, fx_index):
            # Sforzando is the only instrument this script ever adds, so a
            # track with one and no ownership record predates ownership
            # tracking -- adopt it rather than leaving it stuck forever.
            mark_owned(track)
        if is_owned(track):
            return "instrument already present"
        return "instrument already present (added by you -- left alone)"

    if instrument is None:
        return "no instrument -- couldn't resolve this track's GM instrument"

    if setup is None:
        return "not added -- see the message above"
    source = get_or_create_instrument_source(source_pool, instrument, setup)
    if source is None:
        return ("FAILED to add Sforzando+Arachno -- Sforzando didn't load, or the Arachno "
                "SoundFont hasn't been downloaded (re-run the installer) (see VST.md)")

    source_fx = RPR_TrackFX_GetInstrument(source)
    dest_idx = RPR_TrackFX_GetCount(track)
    RPR_TrackFX_CopyToTrack(source, source_fx, track, dest_idx, False)
    if RPR_TrackFX_GetInstrument(track) >= 0:
        mark_owned(track)
        return f"added Sforzando+Arachno ({gm_internal_name(instrument)})"

    return "FAILED to copy instrument onto track"

# ---------------------------------------------------------------------------
# Main Workflow
# ---------------------------------------------------------------------------

def apply_track_setup(tracks, instruments, name_only=False, replace_existing=False):
    """Rename (and, unless name_only, instrument) `tracks` per the final
    track -> GM instrument choices in `instruments` (None = leave that
    track's instrument unresolved/untouched). Pure "do it" step, no
    detection or prompting of its own -- callers (run_setup_tracks below,
    MIDI-GPT Replace Instruments.py, and the dashboard's
    ReaImGui wizard) are responsible for arriving at `instruments` first.

    name_only=True never touches FX at all, even on a track that already
    has an instrument -- it only renames. replace_existing=True deletes
    whatever instrument FX is already on a track before adding a fresh
    one (MIDI-GPT Replace Instruments.py's "force" behavior);
    False (the default) leaves a track that already has an instrument
    alone, same as ensure_instrument's own ownership-respecting check."""
    print(f"Configuring {len(tracks)} track(s)...\n")

    setup = None if name_only else prepare_instrument_setup()
    source_pool = {}
    RPR_Undo_BeginBlock()
    try:
        for track in tracks:
            instrument = instruments.get(track)
            if instrument is not None:
                set_track_name(track, gm_internal_name(instrument))
            name = get_track_name(track) or "(unnamed)"
            instrument_note = f"instrument: {gm_internal_name(instrument)}" if instrument is not None else "instrument: unresolved"

            if name_only:
                print(f"{name}: name only; {instrument_note}")
                continue

            if replace_existing:
                existing_fx = RPR_TrackFX_GetInstrument(track)
                if existing_fx >= 0:
                    RPR_TrackFX_Delete(track, existing_fx)

            inst_result = ensure_instrument(track, instrument, source_pool, setup)
            print(f"{name}: {inst_result}; {instrument_note}")
    finally:
        cleanup_instrument_sources(source_pool)
    RPR_Undo_EndBlock("MIDI-GPT: Setup tracks", -1)

    print("\nDone.\n")

def run_setup_tracks():
    RPR_ClearConsole()

    num_tracks = RPR_CountTracks(0)
    tracks = [RPR_GetTrack(0, i) for i in range(num_tracks)]
    if not tracks:
        print("No tracks in project.\n")
        return

    instruments = resolve_track_instruments(tracks)
    apply_track_setup(tracks, instruments, name_only=False, replace_existing=False)

if __name__ == "__main__":
    run_setup_tracks()
