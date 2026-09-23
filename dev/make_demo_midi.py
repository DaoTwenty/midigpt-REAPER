#!/usr/bin/env python3
"""Generate the tutorial demo MIDI files in docs/tutorials/demo/.

Maintainer-only (dev/ is never shipped). The music is written here note by
note, so the files are original work released under CC0 and can be
regenerated at any time. No dependencies: a minimal Standard MIDI File
(format 1) writer is included below.

Usage:
    python3 dev/make_demo_midi.py
"""

import os
import struct

PPQ = 480
BAR = 4 * PPQ
EIGHTH = PPQ // 2
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "tutorials", "demo")

# General MIDI programs (0-based), named as in INSTRUMENTS.md.
ACOUSTIC_GRAND_PIANO = 0
ELECTRIC_PIANO_1 = 4
ELECTRIC_BASS_FINGER = 33
FLUTE = 73

# GM drum notes (channel 10)
KICK, SNARE, CLOSED_HAT, CRASH = 36, 38, 42, 49

# C - Am - F - G, one chord per bar (root, and the triad voiced around middle C)
PROGRESSION = [
    (36, [60, 64, 67]),  # C
    (33, [57, 60, 64]),  # Am
    (29, [57, 60, 65]),  # F
    (31, [55, 59, 62]),  # G
]


def _vlq(value):
    out = [value & 0x7F]
    value >>= 7
    while value:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(out))


def _meta(kind, data):
    return b"\xff" + bytes([kind]) + _vlq(len(data)) + data


def _track(events):
    """events: list of (abs_tick, order, bytes). Returns an MTrk chunk."""
    events = sorted(events, key=lambda e: (e[0], e[1]))
    body, last = b"", 0
    for tick, _, data in events:
        body += _vlq(tick - last) + data
        last = tick
    body += _vlq(0) + _meta(0x2F, b"")
    return b"MTrk" + struct.pack(">I", len(body)) + body


def _notes(channel, notes):
    """notes: list of (start_tick, length_ticks, pitch, velocity).
    Note-offs sort before note-ons at the same tick."""
    events = []
    for start, length, pitch, vel in notes:
        events.append((start, 1, bytes([0x90 | channel, pitch, vel])))
        events.append((start + length, 0, bytes([0x80 | channel, pitch, 0])))
    return events


def instrument_track(name, channel, program, notes):
    events = [(0, -2, _meta(0x03, name.encode("ascii")))]
    if program is not None:
        events.append((0, -1, bytes([0xC0 | channel, program])))
    return _track(events + _notes(channel, notes))


def conductor_track(bpm=120):
    tempo = round(60_000_000 / bpm)
    return _track([
        (0, 0, _meta(0x51, tempo.to_bytes(3, "big"))),
        (0, 0, _meta(0x58, bytes([4, 2, 24, 8]))),  # 4/4
    ])


def write_midi(filename, tracks):
    header = b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), PPQ)
    path = os.path.join(OUT_DIR, filename)
    with open(path, "wb") as f:
        f.write(header + b"".join(tracks))
    print(f"wrote {os.path.relpath(path)}")


# ---------------------------------------------------------------------------
# The music. `offset` shifts everything (used for the pickup-bar file).
# ---------------------------------------------------------------------------

def drums(bars, offset=0):
    notes = []
    for bar in range(bars):
        t0 = offset + bar * BAR
        if bar % 4 == 0:
            notes.append((t0, EIGHTH, CRASH, 100))
        for beat in range(4):
            notes.append((t0 + beat * PPQ, EIGHTH, KICK if beat in (0, 2) else SNARE, 110 if beat in (0, 2) else 100))
        for eighth in range(8):
            notes.append((t0 + eighth * EIGHTH, EIGHTH // 2, CLOSED_HAT, 80 if eighth % 2 else 95))
        if bar % 4 == 3:  # pickup kick into the next phrase
            notes.append((t0 + 3 * PPQ + EIGHTH, EIGHTH, KICK, 90))
    return notes


def bass(bars, offset=0):
    notes = []
    for bar in range(bars):
        root, _ = PROGRESSION[bar % 4]
        t0 = offset + bar * BAR
        pattern = [0, 0, 12, 0, 0, 7, 12, 7]  # root/octave/fifth in eighths
        for i, interval in enumerate(pattern):
            notes.append((t0 + i * EIGHTH, EIGHTH - 20, root + interval, 100))
    return notes


def keys(bars, offset=0):
    notes = []
    for bar in range(bars):
        _, chord = PROGRESSION[bar % 4]
        t0 = offset + bar * BAR
        for half in (0, 2 * PPQ):
            for pitch in chord:
                notes.append((t0 + half, 2 * PPQ - 40, pitch, 80))
    return notes


# One bar per list: (beat position in eighths, length in eighths, pitch)
LEAD_PHRASE = [
    [(0, 2, 72), (2, 2, 74), (4, 4, 76)],
    [(0, 3, 76), (3, 1, 74), (4, 4, 72)],
    [(0, 2, 72), (2, 2, 69), (4, 2, 72), (6, 2, 77)],
    [(0, 6, 74), (6, 2, 71)],
    [(0, 2, 72), (2, 2, 76), (4, 4, 79)],
    [(0, 2, 81), (2, 2, 79), (4, 4, 76)],
    [(0, 2, 77), (2, 2, 76), (4, 2, 74), (6, 2, 72)],
    [(0, 8, 74)],
]


def lead(bars, offset=0):
    notes = []
    for bar in range(bars):
        t0 = offset + bar * BAR
        for pos, length, pitch in LEAD_PHRASE[bar % len(LEAD_PHRASE)]:
            notes.append((t0 + pos * EIGHTH, length * EIGHTH - 30, pitch, 95))
    return notes


def piano(bars):
    """Left-hand broken chords plus the lead melody an octave up, as one part."""
    notes = []
    for bar in range(bars):
        root, chord = PROGRESSION[bar % 4]
        t0 = bar * BAR
        arpeggio = [root + 12, chord[0], chord[1], chord[2]] * 2
        for i, pitch in enumerate(arpeggio):
            notes.append((t0 + i * EIGHTH, EIGHTH, pitch - 12, 70))
    return notes + [(t, l, p, 90) for t, l, p, _ in lead(bars)]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    bars = 8

    write_midi("pop_groove.mid", [
        conductor_track(),
        instrument_track("drums", 9, None, drums(bars)),
        instrument_track("bass", 0, ELECTRIC_BASS_FINGER, bass(bars)),
        instrument_track("keys", 1, ELECTRIC_PIANO_1, keys(bars)),
        instrument_track("lead", 2, FLUTE, lead(bars)),
    ])

    write_midi("piano_sketch.mid", [
        conductor_track(96),
        instrument_track("piano", 0, ACOUSTIC_GRAND_PIANO, piano(bars)),
    ])

    # Same groove, but it starts with a one-beat pickup: every downbeat of
    # the song lands on beat 2 of REAPER's bars, so a selection snapped to
    # the music is off REAPER's bar grid (triggers the off-grid warning).
    pickup = PPQ
    lead_notes = [(0, PPQ - 30, 67, 90)] + lead(bars, offset=pickup)
    write_midi("pickup_song.mid", [
        conductor_track(),
        instrument_track("drums", 9, None, drums(bars, offset=pickup)),
        instrument_track("bass", 0, ELECTRIC_BASS_FINGER, bass(bars, offset=pickup)),
        instrument_track("lead", 2, FLUTE, lead_notes),
    ])


if __name__ == "__main__":
    main()
