# -*- coding: utf-8 -*-
"""
REAPER_midigpt_apply_soundfont_template.py  --  force re-add Sforzando+Arachno
on selected tracks

REAPER_midigpt_setup_tracks.py only adds an instrument to tracks that don't
have one yet, so it won't touch a track that already has some other (or
empty) instrument on it. This action replaces whatever instrument FX is on
each *selected* track with a freshly generated Sforzando+Arachno instance
for that track's resolved GM instrument -- the same on-the-fly generation
Setup Tracks itself uses (see REAPER_midigpt_setup_tracks.py), just forced.
Scoped to selection only, since it overwrites -- select just the tracks
you actually want replaced.
"""

import sys

from reaper_python import *
import REAPER_midigpt_setup_tracks as setup_tracks


class _ReaperConsole:
    def write(self, s):
        RPR_ShowConsoleMsg(s)
    def flush(self):
        pass

sys.stdout = sys.stderr = _ReaperConsole()


def run_apply_soundfont_template():
    RPR_ClearConsole()

    n_sel = RPR_CountSelectedTracks(0)
    if n_sel == 0:
        print("Select the tracks you want to (re)configure first.\n")
        return

    tracks = [RPR_GetSelectedTrack(0, i) for i in range(n_sel)]
    instruments = setup_tracks.resolve_track_instruments(tracks)

    source_pool = {}
    RPR_Undo_BeginBlock()
    try:
        for track in tracks:
            instrument = instruments.get(track)
            name = setup_tracks.get_track_name(track) or "(unnamed)"
            if instrument is None:
                print(f"{name}: couldn't resolve a GM instrument -- skipped")
                continue
            setup_tracks.set_track_name(track, setup_tracks.gm_internal_name(instrument))

            existing_fx = RPR_TrackFX_GetInstrument(track)
            if existing_fx >= 0:
                RPR_TrackFX_Delete(track, existing_fx)

            source = setup_tracks.get_or_create_instrument_source(source_pool, instrument)
            if source is None:
                print(f"{name}: FAILED to add Sforzando+Arachno -- make sure Sforzando is "
                      "installed and the Arachno SoundFont has been downloaded (see VST.md)")
                continue

            source_fx = RPR_TrackFX_GetInstrument(source)
            dest_idx = RPR_TrackFX_GetCount(track)
            RPR_TrackFX_CopyToTrack(source, source_fx, track, dest_idx, False)
            if RPR_TrackFX_GetInstrument(track) >= 0:
                setup_tracks.mark_owned(track)
                print(f"{name}: replaced with Sforzando+Arachno ({setup_tracks.gm_internal_name(instrument)})")
            else:
                print(f"{name}: FAILED to copy instrument onto track")
    finally:
        setup_tracks.cleanup_instrument_sources(source_pool)
    RPR_Undo_EndBlock("MIDI-GPT: Apply soundfont template", -1)

    print("\nDone.\n")


if __name__ == "__main__":
    run_apply_soundfont_template()
