"""
REAPER Functions for MMM Integration
Handles parameter reading and server communication
"""

import sys
import os
import json

import mytrackviewstuff as mt
import mymidistuff as mm
import myfunctions as mf
import midisong as ms
import nn_str_functions as nns
import constants as cs
import encoding_functions as enc
import tokenizer_functions as tok
import preprocessing_functions as pre
import midi_inst_to_name

GLOBAL_FX_ID = 54964318
TRACK_FX_ID = 349583025
DEBUG = True

script_path = os.path.dirname(os.path.realpath(__file__))
ca_path = os.path.join(script_path, 'src', 'Scripts', 'composers_assistant_v2')
if os.path.exists(ca_path):
    sys.path.insert(0, os.path.abspath(ca_path))

try:
    from reaper_python import *
    import preprocessing_functions as pre
except ImportError as e:
    print(f"Warning: Could not import REAPER modules: {e}")

def _locate_infiller_global_options_FX_loc() -> int:
    """-1 means not found (or not enabled). Look on monitor FX. Get the first enabled instance."""
    from reaper_python import RPR_GetMasterTrack, RPR_TrackFX_GetEnabled, RPR_TrackFX_GetParam
    tr = RPR_GetMasterTrack(-1)
    n_fx = 100  # search up to 100 FX
    for i in range(0x1000000, 0x1000000 + n_fx):
        if RPR_TrackFX_GetEnabled(tr, i):
            v = RPR_TrackFX_GetParam(tr, i, 0, 0, 0)[0]
            if mf.is_approx(v, GLOBAL_FX_ID):
                return i
    return -1


def _locate_mmm_track_options_FX_loc(track) -> int:
    """-1 means not found (or not enabled). Get the last enabled instance"""
    res = -1
    from reaper_python import RPR_TrackFX_GetEnabled, RPR_TrackFX_GetParam
    for i in range(mt.get_num_FX_on_track(track)):
    # for i, name in enumerate(mt.get_FX_names_on_track(track)):
        if RPR_TrackFX_GetEnabled(track, i):
            val = RPR_TrackFX_GetParam(track, i, 0, 0, 0)[0]
            if mf.is_approx(val, TRACK_FX_ID) or mf.is_approx(val, 349583024):
                res = i
    return res


def get_global_options():
    """
    Read global MMM options from master track FX
    Returns object with all parameters matching MMM server expectations
    """
    class GlobalOptions:
        pass
    
    options = GlobalOptions()
    
    # Default values matching MMM server expectations
    options.temperature = 1.0
    options.tracks_per_step = 1
    options.bars_per_step = 1
    options.model_dim = 4
    options.percentage = 100
    options.max_steps = 200
    options.batch_size = 1
    options.shuffle = True
    options.sampling_seed = -1
    options.mask_top_k = 0
    options.polyphony_hard_limit = 6
    
    # CA-compatible options (used by REAPER scripts but not by MMM)
    options.rhy_cond = 0
    options.do_note_range_cond = 0
    options.enc_no_repeat_ngram_size = 0
    options.variation_alg = 0
    options.disp_tr_to_midi_inst = True
    options.gen_notes_are_selected = True
    options.display_warnings = True
    options.verbose = False
    
    try:
        master = RPR_GetMasterTrack(0)
        if master is None:
            print("Warning: Could not get master track")
            return options
        
        # Search Monitor FX chain (like CA does)
        # Monitor FX uses special index: 0x1000000 + fx_index
        fx_loc = _locate_infiller_global_options_FX_loc()
        
        # REAPER uses sequential parameter indices, not JSFX slider numbers
        # Parameter 0 = slider1 (jsfx_id), so use loc_offset=1 to skip it
        loc_offset = 1
        
        print(f"Reading parameters from FX at index {fx_loc} with loc_offset={loc_offset}")
        
        # Core generation parameters - REAPER returns actual slider values, no scaling needed!
        # slider10-20 map to parameters 1-11
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 0 + loc_offset, 0, 0)
        options.temperature = val
        print(f"  Temperature: {options.temperature:.3f}")
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 1 + loc_offset, 0, 0)
        options.tracks_per_step = int(val)
        print(f"  Tracks per step: {options.tracks_per_step}")
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 2 + loc_offset, 0, 0)
        options.bars_per_step = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 3 + loc_offset, 0, 0)
        options.model_dim = int(val)
        print(f"  Model dim: {options.model_dim}")
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 4 + loc_offset, 0, 0)
        options.percentage = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 5 + loc_offset, 0, 0)
        options.max_steps = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 6 + loc_offset, 0, 0)
        options.batch_size = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 7 + loc_offset, 0, 0)
        options.shuffle = bool(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 8 + loc_offset, 0, 0)
        options.sampling_seed = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 9 + loc_offset, 0, 0)
        options.mask_top_k = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 10 + loc_offset, 0, 0)
        options.polyphony_hard_limit = int(val)
        
        # CA-compatible parameters
        # slider30-33 map to parameters 12-15
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 11 + loc_offset, 0, 0)
        options.rhy_cond = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 12 + loc_offset, 0, 0)
        options.do_note_range_cond = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 13 + loc_offset, 0, 0)
        options.enc_no_repeat_ngram_size = int(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 14 + loc_offset, 0, 0)
        options.variation_alg = int(val)
        
        # UI flags
        # slider40-43 map to parameters 16-19
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 15 + loc_offset, 0, 0)
        options.disp_tr_to_midi_inst = bool(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 16 + loc_offset, 0, 0)
        options.gen_notes_are_selected = bool(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 17 + loc_offset, 0, 0)
        options.display_warnings = bool(val)
        
        val, _, _, _, _, _ = RPR_TrackFX_GetParam(master, fx_loc, 18 + loc_offset, 0, 0)
        options.verbose = bool(val)
    
    except Exception as e:
        print(f"Warning: Could not read global options: {e}")
    
    return options

class MMMTrackOptionsObj:
    track_temperature = -1.0
    vert_density = -1
    n_pitch_classes = -1
    horiz_density = 4
    rhy_ins = 3
    step_bin = 4
    leap_bin = 3
    low_note_strict = -1
    high_note_strict = -1
    low_note_loose = -1
    high_note_loose = -1

def get_mmm_track_options_by_track_idx() -> dict:
    """Read MMM Track Options from all tracks, return dict keyed by track index."""
    res = {}
    
    try:
        from reaper_python import RPR_TrackFX_GetParam, RPR_CountTracks, RPR_GetTrack
        
        num_tracks = RPR_CountTracks(0)
        
        for i in range(num_tracks):
            t = RPR_GetTrack(0, i)
            fx_loc = _locate_mmm_track_options_FX_loc(t)
            
            if fx_loc > -1:
                opts = MMMTrackOptionsObj()
                loc_offset = 1
                
                # Parameter indices after removing unused sliders:
                # 0: jsfx_id
                # 1: track_temperature (slider10)
                # 2: vert_density (slider20)
                # 3: n_pitch_classes (slider21)
                # 4: horiz_density (slider30)
                # 5: rhy_ins (slider31)
                # 6: step_bin (slider40)
                # 7: leap_bin (slider41)
                # 8: low_note_strict (slider50)
                # 9: high_note_strict (slider51)
                # 10: low_note_loose (slider52)
                # 11: high_note_loose (slider53)
                
                opts.track_temperature = RPR_TrackFX_GetParam(t, fx_loc, 0 + loc_offset, 0, 0)[0]
                
                val = RPR_TrackFX_GetParam(t, fx_loc, 1 + loc_offset, 0, 0)[0]
                opts.vert_density = int(val) - 1
                
                val = RPR_TrackFX_GetParam(t, fx_loc, 2 + loc_offset, 0, 0)[0]
                opts.n_pitch_classes = int(val) - 1
                
                val = RPR_TrackFX_GetParam(t, fx_loc, 3 + loc_offset, 0, 0)[0]
                opts.horiz_density = int(val) - 1
                
                val = RPR_TrackFX_GetParam(t, fx_loc, 4 + loc_offset, 0, 0)[0]
                opts.rhy_ins = int(val) - 1
                
                val = RPR_TrackFX_GetParam(t, fx_loc, 5 + loc_offset, 0, 0)[0]
                opts.step_bin = int(val) - 1
                
                val = RPR_TrackFX_GetParam(t, fx_loc, 6 + loc_offset, 0, 0)[0]
                opts.leap_bin = int(val) - 1
                
                opts.low_note_strict = int(RPR_TrackFX_GetParam(t, fx_loc, 7 + loc_offset, 0, 0)[0])
                opts.high_note_strict = int(RPR_TrackFX_GetParam(t, fx_loc, 8 + loc_offset, 0, 0)[0])
                opts.low_note_loose = int(RPR_TrackFX_GetParam(t, fx_loc, 9 + loc_offset, 0, 0)[0])
                opts.high_note_loose = int(RPR_TrackFX_GetParam(t, fx_loc, 10 + loc_offset, 0, 0)[0])
                
                res[str(i)] = opts
                
                if DEBUG:
                    print(f"Track {i} options: vert={opts.vert_density}, horiz={opts.horiz_density}")
        
    except Exception as e:
        if DEBUG:
            print(f"Error reading MMM Track Options: {e}")
    
    return res

def convert_track_options_to_control_strings(opts: MMMTrackOptionsObj) -> list:
    """Convert track options to MMM attribute control strings."""
    controls = []
    
    if opts.vert_density >= 0:
        controls.append(f"VERT_{opts.vert_density}")
    
    if opts.n_pitch_classes >= 0:
        controls.append(f"PITCH_CLASS_{opts.n_pitch_classes}")
    
    if opts.horiz_density >= 0:
        controls.append(f"HORIZ_{opts.horiz_density}")
    
    if opts.rhy_ins >= 0:
        controls.append(f"RHYTHM_{opts.rhy_ins}")
    
    if opts.step_bin >= 0:
        controls.append(f"STEP_{opts.step_bin}")
    
    if opts.leap_bin >= 0:
        controls.append(f"LEAP_{opts.leap_bin}")
    
    if opts.low_note_strict > -1:
        controls.append(f"LOW_NOTE_STRICT_{opts.low_note_strict}")
    
    if opts.high_note_strict > -1:
        controls.append(f"HIGH_NOTE_STRICT_{opts.high_note_strict}")
    
    if opts.low_note_loose > -1:
        controls.append(f"LOW_NOTE_LOOSE_{opts.low_note_loose}")
    
    if opts.high_note_loose > -1:
        controls.append(f"HIGH_NOTE_LOOSE_{opts.high_note_loose}")
    
    return controls


def call_nn_infill(S, masks, extra_ids_map, temperature=1.0, start_measure=None, end_measure=None):
    """
    Call the MMM server via XML-RPC
    Uses parameters passed to function, supplementing with global options for MMM-specific params
    """
    from xmlrpc.client import ServerProxy
    import xmlrpc.client
    
    print(f"\ncall_nn_infill called with temperature={temperature}")
    
    
    try:
        proxy = ServerProxy('http://127.0.0.1:3456')
        
        # Read global options for MMM-specific parameters not in CA signature
        options = get_global_options()

        # Read track-specific options
        track_options = get_mmm_track_options_by_track_idx()
        
        # Build options dict using passed parameters where available
        options_dict = {
            'temperature': temperature,  # Use passed parameter, not options.temperature
            'tracks_per_step': options.tracks_per_step,
            'bars_per_step': options.bars_per_step,
            'model_dim': options.model_dim,
            'percentage': options.percentage,
            'max_steps': options.max_steps,
            'batch_size': options.batch_size,
            'shuffle': options.shuffle,
            'sampling_seed': options.sampling_seed,
            'mask_top_k': options.mask_top_k,
            'polyphony_hard_limit': options.polyphony_hard_limit
        }
        
        print("S",json.dumps(pre.encode_midisongbymeasure_to_save_dict(S), indent=4))
        print(start_measure, end_measure)

        
        res = proxy.call_nn_infill(
            pre.encode_midisongbymeasure_to_save_dict(S), 
            masks,
            extra_ids_map,
            options_dict,
            start_measure, 
            end_measure
        )
        

        print("Returning generation")
        return res
        
        
    except xmlrpc.client.Fault as e:
        print('Exception raised by MMM server:')
        print(str(e))
        raise
    except Exception as e:
        print('MMM server connection failed. Make sure mmm_nn_server.py is running on port 3456.')
        print(f'Error: {e}')
        return
    