# -*- coding: utf-8 -*-
"""
@description MIDI-GPT Replace Instruments
@author Paul Triana
@version 1.0
@about
  Force re-add Sforzando+Arachno on selected tracks. MIDI-GPT Setup
  Tracks.py only adds an instrument to tracks that don't have one yet, so
  it won't touch a track that already has some other (or empty) instrument
  on it. This action replaces whatever instrument FX is on each *selected*
  track with a freshly generated Sforzando+Arachno instance for that
  track's resolved GM instrument -- the same on-the-fly generation Setup
  Tracks itself uses, just forced. Scoped to selection only, since it
  overwrites -- select just the tracks you actually want replaced.
"""

import sys
import importlib

from reaper_python import *
setup_tracks = importlib.import_module("MIDI-GPT Setup Tracks")


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
    setup_tracks.apply_track_setup(tracks, instruments, name_only=False, replace_existing=True)


if __name__ == "__main__":
    run_apply_soundfont_template()
