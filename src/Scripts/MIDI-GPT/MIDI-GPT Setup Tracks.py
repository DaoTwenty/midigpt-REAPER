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
import os
import platform
import struct
import subprocess
import time
import zlib

from reaper_python import *
from midi_extraction import INST_TO_MATCHING_STRINGS

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

EXT_STATE_SECTION = "MIDI-GPT"

# GM program 0-127 -> canonical name, exactly matching INSTRUMENTS.md.
GM_INTERNAL_NAMES = [
    "acoustic_grand_piano", "bright_acoustic_piano", "electric_grand_piano", "honky_tonk_piano",
    "electric_piano_1", "electric_piano_2", "harpsichord", "clavi",
    "celesta", "glockenspiel", "music_box", "vibraphone",
    "marimba", "xylophone", "tubular_bells", "dulcimer",
    "drawbar_organ", "percussive_organ", "rock_organ", "church_organ",
    "reed_organ", "accordion", "harmonica", "tango_accordion",
    "acoustic_guitar_nylon", "acoustic_guitar_steel", "electric_guitar_jazz", "electric_guitar_clean",
    "electric_guitar_muted", "overdriven_guitar", "distortion_guitar", "guitar_harmonics",
    "acoustic_bass", "electric_bass_finger", "electric_bass_pick", "fretless_bass",
    "slap_bass_1", "slap_bass_2", "synth_bass_1", "synth_bass_2",
    "violin", "viola", "cello", "contrabass",
    "tremolo_strings", "pizzicato_strings", "orchestral_harp", "timpani",
    "string_ensemble_1", "string_ensemble_2", "synth_strings_1", "synth_strings_2",
    "choir_aahs", "voice_oohs", "synth_voice", "orchestra_hit",
    "trumpet", "trombone", "tuba", "muted_trumpet",
    "french_horn", "brass_section", "synth_brass_1", "synth_brass_2",
    "soprano_sax", "alto_sax", "tenor_sax", "baritone_sax",
    "oboe", "english_horn", "bassoon", "clarinet",
    "piccolo", "flute", "recorder", "pan_flute",
    "blown_bottle", "shakuhachi", "whistle", "ocarina",
    "lead_1_square", "lead_2_sawtooth", "lead_3_calliope", "lead_4_chiff",
    "lead_5_charang", "lead_6_voice", "lead_7_fifths", "lead_8_bass__lead",
    "pad_1_new_age", "pad_2_warm", "pad_3_polysynth", "pad_4_choir",
    "pad_5_bowed", "pad_6_metallic", "pad_7_halo", "pad_8_sweep",
    "fx_1_rain", "fx_2_soundtrack", "fx_3_crystal", "fx_4_atmosphere",
    "fx_5_brightness", "fx_6_goblins", "fx_7_echoes", "fx_8_sci_fi",
    "sitar", "banjo", "shamisen", "koto",
    "kalimba", "bag_pipe", "fiddle", "shanai",
    "tinkle_bell", "agogo", "steel_drums", "woodblock",
    "taiko_drum", "melodic_tom", "synth_drum", "reverse_cymbal",
    "guitar_fret_noise", "breath_noise", "seashore", "bird_tweet",
    "telephone_ring", "helicopter", "applause", "gunshot",
]

# ---------------------------------------------------------------------------
# Fully-automatic Sforzando+Arachno instrument generation -- no template
# track, no clone source, no manual per-instrument setup, ever.
#
# Sforzando's SF2-import state turns out to be a small, plain-text XML blob
# (Aria Engine's "AriaSave" format), not an opaque binary blob and not an
# absolute file path -- it references the SoundFont by a sanitized filename
# plus bank/program, e.g.:
#   sf2/Arachno_SoundFont_-_Version_1_0_sf2/000/000_Grand_Piano
# Reverse-engineered from one real captured FX chunk (Sforzando with
# Arachno.sf2 imported, GM program 0 selected, via REAPER's own
# GetTrackStateChunk). That means the exact same XML -- with just the
# bank/program/name swapped -- selects any of Arachno's 138 presets, so a
# fully configured instance can be built from scratch for any GM program,
# with no dependency on any pre-existing track. See ARACHNO_MELODIC_NAMES
# below for the preset name table, extracted directly from Arachno.sf2's
# own phdr (preset header) chunk -- standard SF2/RIFF format, not guessed.
#
# The REAPER-side chunk format wrapping that XML (the base64 "header" and
# "CEGP"-tagged block below) was captured from that same real FX chunk and
# is fixed/reused as-is -- only the XML payload (and the one length field
# that has to match its size) changes per instrument. This has been
# verified to round-trip byte-for-byte (decode -> rebuild -> decode gives
# back identical content) but has NOT been tested against a running
# REAPER+Sforzando -- if a generated instrument doesn't produce sound,
# that's the first thing to suspect.
# ---------------------------------------------------------------------------

# Captured once from a real Sforzando FX chunk; the 4-byte field at
# _SFZ_HEADER_LEN_OFFSET is the only part of this that changes per
# instrument (it's the byte length of the CEGP block that follows).
_SFZ_HEADER_B64 = "UUdMUO5e7f4AAAAAAgAAAAEAAAAAAAAAAgAAAAAAAACxAQAAAQAAAAAAAAA="
_SFZ_HEADER_LEN_OFFSET = 32
_SFZ_CEGP_TAG = b"CEGP"
_SFZ_VST_HEADER_LINE = (
    '    <VST "VSTi: sforzando (Plogue Art et Technologie, Inc)" sforzando.vst 0 "" '
    '1347176273<5C5CA79682FC437AB6539BA204BAB349> ""'
)

_ARIA_XML_TEMPLATE = (
    '<?xml version="1.0" ?>\n'
    '<AriaSave version="1982" productID="1014">\n'
    '    <Settings quality="1" streaming="32" MIDIOutMode="1" automationSlot="0" liveMode="0" sc="4" scala="01 - equal.scl" scalaCenter="60" globalTuning="0" />\n'
    '    <Slot id="0" name="{slot_name}" bankId="4000" version="0" channel="-1" poly="64" tuning="0" pb_range="-1" ptrans="0" mtrans="0" moctave="0" sc="3" mute="0">\n'
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
    """Aria's own name sanitizer, as used in its SoundFont/preset slot
    references. Confirmed against the one real captured example: space and
    '.' become '_' (e.g. 'Grand Piano' -> 'Grand_Piano', and the SoundFont
    filename 'Arachno SoundFont - Version 1.0.sf2' ->
    'Arachno_SoundFont_-_Version_1_0_sf2' -- note the literal '-' survives
    unchanged). Unconfirmed for the ~6 Arachno preset names with '&', '(',
    ')', '/' -- if one of those specific instruments doesn't sound right,
    that's the first thing to check."""
    return name.replace(" ", "_").replace(".", "_")

def _find_arachno_sf2_name():
    """The exact filename of the Arachno SoundFont install.sh downloads
    into <repo>/soundfonts/ (see download_arachno_soundfont in install.sh)
    -- read directly off disk rather than hardcoded, so this keeps working
    even if Arachnosoft ever ships a differently-named file. Returns None
    if it's not there yet."""
    # This file lives at <repo>/src/Scripts/MIDI-GPT/ -- four levels down
    # from <repo> itself (it's loaded through a symlink from REAPER's
    # Scripts folder, so realpath() is needed to resolve back to it).
    repo_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.realpath(__file__)))))
    soundfont_dir = os.path.join(repo_dir, "soundfonts")
    try:
        for entry in sorted(os.listdir(soundfont_dir)):
            if entry.lower().endswith(".sf2"):
                return entry
    except OSError:
        pass
    return None

def _arachno_slot_name(bank, program, preset_name):
    sf2_name = _find_arachno_sf2_name()
    if sf2_name is None:
        return None
    return f"sf2/{_sanitize_aria_name(sf2_name)}/{bank:03d}/{program:03d}_{_sanitize_aria_name(preset_name)}"

def _build_sforzando_vst_block(instrument):
    """The '<VST ...> ... >' block text for a Sforzando instance with
    Arachno.sf2 loaded and the given GM instrument (0-127, or 128 for
    drums) already selected -- see the module-level comment above for how
    this is derived. Indented to sit directly inside an <FXCHAIN> block.
    Returns None if the Arachno SoundFont hasn't been downloaded yet (see
    install.sh)."""
    if instrument == 128:
        bank, program, name = ARACHNO_DRUM_KIT
    else:
        bank, program, name = 0, instrument, ARACHNO_MELODIC_NAMES[instrument]
    slot_name = _arachno_slot_name(bank, program, name)
    if slot_name is None:
        return None
    xml = _ARIA_XML_TEMPLATE.format(slot_name=slot_name)

    compressed = zlib.compress(xml.encode("utf-8"), 9)
    cegp_blob = _SFZ_CEGP_TAG + struct.pack("<I", len(xml)) + compressed

    header = bytearray(base64.b64decode(_SFZ_HEADER_B64))
    struct.pack_into("<I", header, _SFZ_HEADER_LEN_OFFSET, len(cegp_blob))

    b64_header = base64.b64encode(bytes(header)).decode()
    b64_body = base64.b64encode(cegp_blob).decode()
    body_lines = [b64_body[i:i + 128] for i in range(0, len(b64_body), 128)]

    lines = [_SFZ_VST_HEADER_LINE, f"      {b64_header}"]
    lines += [f"      {ln}" for ln in body_lines]
    lines.append("    >")
    return "\n".join(lines)

def _build_source_track_chunk(track_name, instrument):
    """A minimal, self-contained TRACK chunk with just Sforzando+Arachno as
    its FX chain -- for a brand new, throwaway track (see
    get_or_create_instrument_source). Never applied to a track that already
    has content: SetTrackStateChunk replaces the *whole* track. Returns
    None if the SoundFont isn't downloaded yet (see _build_sforzando_vst_block)."""
    vst_block = _build_sforzando_vst_block(instrument)
    if vst_block is None:
        return None
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

GM_NAME_TO_INSTRUMENT = {name: i for i, name in enumerate(GM_INTERNAL_NAMES)}
GM_NAME_TO_INSTRUMENT["drums"] = 128

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

def get_or_create_instrument_source(source_pool, instrument):
    """Return a throwaway track whose only FX is a correctly configured
    Sforzando+Arachno instance for `instrument`, creating and caching one
    per distinct instrument the first time it's needed (source_pool is a
    plain dict the caller owns and cleans up via
    cleanup_instrument_sources). Returns None if Sforzando couldn't be
    instantiated (e.g. it isn't installed) -- cached too, so it's not
    retried for every track in the same run."""
    if instrument in source_pool:
        return source_pool[instrument]

    chunk = _build_source_track_chunk("MIDI-GPT source", instrument)
    track = None
    if chunk is not None:
        idx = RPR_CountTracks(0)
        RPR_InsertTrackAtIndex(idx, False)
        track = RPR_GetTrack(0, idx)
        ok = bool(track) and RPR_SetTrackStateChunk(track, chunk, False) \
            and RPR_TrackFX_GetInstrument(track) >= 0
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

def ensure_instrument(track, instrument, source_pool):
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

    source = get_or_create_instrument_source(source_pool, instrument)
    if source is None:
        return ("FAILED to add Sforzando+Arachno -- make sure Sforzando is installed and "
                "the Arachno SoundFont has been downloaded (re-run install.sh) (see VST.md)")

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

            inst_result = ensure_instrument(track, instrument, source_pool)
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
