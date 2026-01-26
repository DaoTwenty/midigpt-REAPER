import sys
import os
import tempfile
import re
import json
from xmlrpc.server import SimpleXMLRPCServer
import mido

from collections import defaultdict

from transformers import (
    AutoModelForCausalLM,
    GenerationConfig
)
from miditok import MMM
from miditok.utils import get_bars_ticks
from symusic import Score, TimeSignature

DEBUG = True
PORT = 3456

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../../src/Scripts/composers_assistant_v2'))
import preprocessing_functions as pre

MMM_AVAILABLE = False
MODEL = None
TOKENIZER = None

try:
    #from mmm import Model, Tokenizer, PromptConfig, SamplingEngine, GenerationConfig, Score, generate, ModelConfig
    from mmm import generate, InferenceConfig
    MMM_AVAILABLE = True
    print("MMM library loaded successfully")
except ImportError as e:
    print(f"MMM library not available: {e}")


def initialize_mmm():
    global MODEL, TOKENIZER
    
    if not MMM_AVAILABLE:
        return False
    
    check_num = 172000
    #check_num = 137000
    model_type="large"
    #model_type="medium"

    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        tokenizer_path = os.path.join(script_dir, f'models/gpt2_{model_type}_v1/checkpoint-{check_num}/MMM_gpt2_{model_type}_tokenizer.json')
        model_path = os.path.join(script_dir, f'models/gpt2_{model_type}_v1/checkpoint-{check_num}')
        
        if DEBUG:
            print("\n=== INITIALIZING MMM ===")
            print(f"  Tokenizer: {tokenizer_path}")
            print(f"  Model: {model_path}")
        
        #TOKENIZER = Tokenizer(tokenizer_path)
        #model_cfg = ModelConfig(model=model_path, cached=False, vocab_size=16000)
        #MODEL = Model(model_cfg)
        TOKENIZER = MMM(params=tokenizer_path)
        MODEL = AutoModelForCausalLM.from_pretrained(model_path)
        
        if DEBUG:
            print("  MMM initialized successfully")
        
        return True
        
    except Exception as e:
        if DEBUG:
            print(f"  MMM initialization failed: {e}")
            import traceback
            traceback.print_exc()
        return False


def bars_to_ranges(pairs):
    tracks = defaultdict(list)
    
    # group bars by track
    for track, bar in pairs:
        tracks[track].append(bar)
    
    result = {}
    
    for track, bars in tracks.items():
        bars = sorted(bars)
        ranges = []
        
        start = prev = bars[0]
        
        for b in bars[1:]:
            if b == prev + 1:
                prev = b
            else:
                ranges.append((start, prev + 1, []))
                start = prev = b
        
        # last range
        ranges.append((start, prev + 1, []))
        result[track] = ranges
    
    return result

def selected_measures(ranges_by_track):
    selected = set()
    
    for ranges in ranges_by_track.values():
        for start, end, _ in ranges:
            selected.update(range(start, end))
    
    return sorted(selected)

def parse_measures_with_extra_ids(s, start_measure, end_measure, debug=False):
    """
    Parse CA string to find measures and tracks with extra_ids.
    
    Returns:
        marked_measures: set of measure indices
        extra_id_to_measure: dict mapping extra_id -> measure
        extra_id_to_track: dict mapping extra_id -> track_idx
    """
    if debug:
        print('  CA string preview:', s[:200] if len(s) > 200 else s)
    
    marked_measures = set()
    extra_id_to_measure = {}
    extra_id_to_track = {}
    
    measure_starts = []
    for match in re.finditer(r';M:\d+', s):
        measure_starts.append(match.start())
    
    if not measure_starts:
        if debug:
            print("  No measure markers found in CA string")
        return marked_measures, extra_id_to_measure, extra_id_to_track
    
    if debug:
        print(f"  Found {len(measure_starts)} measure markers in CA string")
    
    # Process each section
    for i in range(len(measure_starts)):
        section_start = measure_starts[i]
        section_end = measure_starts[i + 1] if i + 1 < len(measure_starts) else len(s)
        section_text = s[section_start:section_end]
        
        # Check if this section has an extra_id
        extra_id_match = re.search(r'<extra_id_(\d+)>', section_text)
        if not extra_id_match:
            continue
        
        extra_id = int(extra_id_match.group(1))
        
        # Extract track index from I: marker
        track_match = re.search(r';I:(\d+)', section_text)
        track_idx = int(track_match.group(1)) if track_match else 0
        
        project_measure = start_measure + i
        
        if project_measure > end_measure:
            break
        
        marked_measures.add(project_measure)
        extra_id_to_measure[extra_id] = project_measure
        extra_id_to_track[extra_id] = track_idx
        
        if debug:
            print(f"    Measure {project_measure}, Track {track_idx}: extra_id_{extra_id}")
    
    return marked_measures, extra_id_to_measure, extra_id_to_track

def convert_midi_to_ca_format_with_timing(midi_path, project_measures, bars_to_generate, 
                                          extra_ids_map, input_ticks_per_beat=None, 
                                          input_time_signature=None):
    if DEBUG:
        print(f"\n=== CA FORMAT CONVERSION ===")
        print(f"  MIDI: {midi_path}")
        print(f"  Project measures: {project_measures}")
        print(f"  Measures to generate: {bars_to_generate}")
        print(f"  Extra_id mapping: {extra_ids_map}")
    
    midi_file = mido.MidiFile(midi_path)
    output_ticks_per_beat = midi_file.ticks_per_beat
    
    output_time_sig_num = 4
    output_time_sig_denom = 4
    for track in midi_file.tracks:
        for msg in track:
            if msg.type == 'time_signature':
                output_time_sig_num = msg.numerator
                output_time_sig_denom = msg.denominator
                break
        if output_time_sig_num != 4:
            break
    
    if input_ticks_per_beat and input_time_signature:
        ticks_per_beat = input_ticks_per_beat
        time_sig_num, time_sig_denom = input_time_signature
    else:
        ticks_per_beat = output_ticks_per_beat
        time_sig_num = output_time_sig_num
        time_sig_denom = output_time_sig_denom
    
    timing_ratio = 1.0
    if input_ticks_per_beat and output_ticks_per_beat != input_ticks_per_beat:
        timing_ratio = input_ticks_per_beat / output_ticks_per_beat
        if DEBUG:
            print(f"  Timing conversion: {output_ticks_per_beat} → {input_ticks_per_beat} (ratio {timing_ratio})")
    
    beats_per_measure = time_sig_num * (4.0 / time_sig_denom)
    measure_length = int(ticks_per_beat * beats_per_measure)
    
    if DEBUG:
        print(f"  Timing: {ticks_per_beat} ticks/beat, {time_sig_num}/{time_sig_denom}")
        print(f"  Measure length: {measure_length} ticks")
    
    all_notes = []
    num_tracks = len(midi_file.tracks)
    for track_idx, track in enumerate(midi_file.tracks):
        current_time = 0
        active_notes = {}

        #all_notes[str(track_idx)] = []
        
        for msg in track:
            current_time += msg.time
            
            if msg.type == 'note_on' and msg.velocity > 0:
                active_notes[msg.note] = {'start': current_time, 'velocity': msg.velocity}
            elif msg.type == 'note_off' or (msg.type == 'note_on' and msg.velocity == 0):
                if msg.note in active_notes:
                    note_start = active_notes[msg.note]['start']
                    note_duration = current_time - note_start
                    
                    converted_start = int(note_start * timing_ratio)
                    converted_duration = int(note_duration * timing_ratio)
                    
                    all_notes.append({
                        'pitch': msg.note,
                        'start': converted_start,
                        'duration': converted_duration,
                        'velocity': active_notes[msg.note]['velocity'],
                        'instrument': track_idx
                    })
                    del active_notes[msg.note]
    
    if DEBUG:
        print(f"  Extracted {len(all_notes)} notes from MIDI")

    measures_to_generate = selected_measures(bars_to_generate)
    
    notes_by_measure = {str(track_idx): {str(m): [] for m in measures_to_generate} for track_idx in range(num_tracks)}
    
    for note in all_notes:
        measure_idx = note['start'] // measure_length
        
        if measure_idx in measures_to_generate:
            position_in_measure = note['start'] - (measure_idx * measure_length)
            notes_by_measure[str(note['instrument'])][str(measure_idx)].append({
                'pitch': note['pitch'],
                'position': position_in_measure,
                'duration': note['duration'],
                'velocity': note['velocity']
            })
    
    #measure_to_extra_id = {str(m): int(eid) for eid, (t,m) in extra_ids_map.items()}
    tm_to_extra = {}

    for extra_id, (track_idx, measure_idx) in extra_ids_map.items():
        tm_to_extra.setdefault(str(track_idx), {})[str(measure_idx)] = extra_id
    
    print("tm_to_extra",tm_to_extra)

    sections = []
    #for measure in sorted(measures_to_generate):
    for track_idx, bars_in_track in bars_to_generate.items():
        for range_to_gen in bars_in_track:
            for measure in range(range_to_gen[0], range_to_gen[1]):
                notes = notes_by_measure[str(track_idx)][str(measure)]
                
                if str(track_idx) not in tm_to_extra:
                    if DEBUG:
                        print(f"  Warning: track {track_idx} has no extra_id mapping, skipping")
                    continue

                if str(measure) not in tm_to_extra[str(track_idx)]:
                    if DEBUG:
                        print(f"  Warning: measure {measure} in track {track_idx} has no extra_id mapping, skipping")
                    continue
                
                extra_id = tm_to_extra[str(track_idx)][str(measure)]
                notes.sort(key=lambda n: (n['position'], n['pitch']))
                
                note_tokens = []
                last_position_in_measure = 0
                
                for note in notes:
                    position_in_measure = note['position']
                    wait = position_in_measure - last_position_in_measure
                    if wait > 0:
                        note_tokens.append(f"w:{int(wait)}")
                    
                    note_tokens.append(f"N:{note['pitch']}")
                    note_tokens.append(f"d:{int(note['duration'])}")
                    note_tokens.append(f"v:{note['velocity']}")
                    #note_tokens.append(f"I:{note["instrument"]}")
                    
                    last_position_in_measure = position_in_measure
                
                section = f"<extra_id_{extra_id}>;" + ';'.join(note_tokens)
                sections.append(section)
    
    result = ';' + ';'.join(sections)
    
    if DEBUG:
        print(f"  Generated CA format: {len(result)} chars")
        print(f"  Sections: {len(sections)} (one per measure)")
        note_count = sum(len(notes) for notes in notes_by_measure.values())
        print(f"  Total notes: {note_count}")
    
    return result


def call_nn_infill(S, masks, extra_ids_map, options_dict=None, start_measure=None, end_measure=None):
    
    if options_dict is None:
        options_dict = {}
    
    temperature = options_dict.get('temperature', 1.0)
    model_dim = options_dict.get('model_dim', 4)
    max_steps = options_dict.get('max_steps', 200)
    shuffle = options_dict.get('shuffle', False)
    sampling_seed = options_dict.get('sampling_seed', -1)
    
    if temperature < 0.5:
        temperature = 0.5
    elif temperature > 2.0:
        temperature = 2.0
    
    if DEBUG:
        print(f"\n{'='*60}")
        print('MMM CALL_NN_INFILL')
        print(f"  Temperature: {temperature}")
        print(f"  Model dim: {model_dim}")
        print(f"  Max steps: {max_steps}")
        print(f"  Shuffle: {shuffle}")
    
    try:
        if not MMM_AVAILABLE or MODEL is None or TOKENIZER is None:
            if DEBUG:
                print("  MMM not available, returning fallback")
            return ";M:0;B:5;L:96;<extra_id_0>N:60;d:240;w:240"
                
        #extra_ids = [int(m) for m in re.findall(r'<extra_id_(\d+)>', s)]
        extra_ids = [int(k) for k in  extra_ids_map.keys()]
        actual_extra_id = extra_ids[0] if extra_ids else 0
        
        if isinstance(S, dict):
            S = pre.midisongbymeasure_from_save_dict(S)
        
        project_measures = list(range(S.get_n_measures()))
        
        if DEBUG:
            print(f"  Extra IDs: {extra_ids}")
            print(f"  Project: {len(project_measures)} measures, {len(S.tracks)} tracks")
        
        #measures_to_generate, extra_id_to_measure, extra_id_to_track = detect_measures_to_generate(
        #    S, s, start_measure, end_measure, bool(extra_ids), debug=DEBUG
        #)
        
        if not masks:
            if DEBUG:
                print("  No measures to generate")
            return f";<extra_id_{actual_extra_id}>"
        
        with tempfile.NamedTemporaryFile(suffix='.mid', delete=False) as tmp:
            temp_midi_path = tmp.name
        temp_midi_path = '/Users/paultriana/creative_labs/midigpt-REAPER/tests/mmm_test.mid'
        S.dump(filename=temp_midi_path)
        
        if DEBUG:
            print(f"  Created full project MIDI with {S.get_n_measures()} measures")
        
        input_midi = mido.MidiFile(temp_midi_path)
        input_ticks_per_beat = input_midi.ticks_per_beat
        input_time_sig = (4, 4)
        for track in input_midi.tracks:
            for msg in track:
                if msg.type == 'time_signature':
                    input_time_sig = (msg.numerator, msg.denominator)
                    break
        
        score_obj = Score(temp_midi_path)

        # Remove time signatures and tempos occurring after the start of the last note
        max_note_time = 0
        for track in score_obj.tracks:
            if len(track.notes) > 0:
                max_note_time = max(max_note_time, track.notes[-1].time)
        for ti in reversed(range(len(score_obj.time_signatures))):
            #if score_obj.time_signatures[ti].time > max_note_time:
            del score_obj.time_signatures[ti]
            #else:
            #    break
        for ti in reversed(range(len(score_obj.tempos))):
            #if score_obj.tempos[ti].time > max_note_time:
            del score_obj.tempos[ti]
            #else:
            #    break
        
        clip_time = (end_measure + 1) * score_obj.tpq * 4
        
        score_obj = score_obj.clip(
            0,
            clip_time,
            clip_end = True, # If True, also clip notes ending after 'end'
            inplace = False
        )

        score_obj.dump_midi(temp_midi_path)
        score_obj = Score(temp_midi_path)

        context_length = model_dim

        if DEBUG:
            print(f"\n=== BUILDING PROMPT CONFIG ===")
            print(f"  REAPER selection: measures {start_measure}-{end_measure}")
            print(f"  Total measures in score: {len(project_measures)}")
            print(f"  Context length: {context_length} bars (on each side of target)")
            print(f"  Measures to infill: {masks}")
            print(f"  Extra IDs to measure: {extra_ids_map}")
        
        # Build track-specific bar mode
        bar_mode = {}
        bar_mode["bars"] = bars_to_ranges(masks)
        
        if not bar_mode["bars"]:
            if DEBUG:
                print("  No tracks need infilling, using empty config")
            #prompt_cfg = PromptConfig({}, context_length=context_length)
            prompt_cfg = InferenceConfig(
                context_length=context_length,
                bars_to_generate = {},
                new_tracks = []
            )
        else:
            if DEBUG:
                print(f"  Total tracks in score: {len(S.tracks)}")
                print(f"  Tracks configured for infilling: {len(bar_mode['bars'])}")
                for track_idx, ranges in bar_mode["bars"].items():
                    print(f"    Track {track_idx}: {ranges}")
            
            #prompt_cfg = PromptConfig(bar_mode, context_length=context_length)
            prompt_cfg = InferenceConfig(
                context_length=context_length,
                bars_to_generate=bar_mode["bars"],
                new_tracks=[]
            )
        
        gen_cfg = GenerationConfig(
            do_sample=True,
            max_new_tokens=1024,
            repetition_penalty=1.2,
            temperature=temperature,
            num_beams=1,
            top_k=20,
            top_p=0.95,
            epsilon_cutoff=None,
            eta_cutoff=None
        )

        print(gen_cfg)
        
        #engine = SamplingEngine(gen_cfg, TOKENIZER, seed=sampling_seed, verbose=DEBUG)
        
        if DEBUG:
            print(f"\n=== MMM GENERATION ===")
            print(f"  Tracks: {len(S.tracks)}")
            print(f"  Generating measures: {masks}")
            print(f"  Context length: {prompt_cfg.context_length} bars")
            print(f"  Temperature: {gen_cfg.temperature}")
            print(f"  Max tokens: {gen_cfg.max_new_tokens}")
            print(f"  InferenceConfig:")
            print(f"    Mode: {'BarInfilling' if prompt_cfg.infilling else 'Other'}")
            if prompt_cfg.infilling:
                bars_dict = prompt_cfg.bars_to_generate
                print(f"    Tracks configured: {len(bars_dict)}")
                for track_idx, ranges in bars_dict.items():
                    print(f"      Track {track_idx}: {ranges}")
        
        try:
            result = generate(
                model=MODEL,
                tokenizer=TOKENIZER,
                inference_config=prompt_cfg,
                score_or_path=score_obj,
                generate_kwargs= {
                    "generation_config": gen_cfg
                },
                seq2seq=False
            )
            generated_score = result["score"]
            if DEBUG:
                print(f"\n=== TIME METRICS ===")
                print(result["time_metrics"])
        except Exception as gen_error:
            if DEBUG:
                print(f"\n=== GENERATION ERROR ===")
                print(f"  Error: {gen_error}")
                import traceback
                traceback.print_exc()
            raise
        
        with tempfile.NamedTemporaryFile(suffix='.mid', delete=False) as tmp:
            result_midi_path = tmp.name
        result_midi_path = '/Users/paultriana/creative_labs/midigpt-REAPER/tests/mmm_test_out.mid'
        #result_midi_path = '/Users/griffinpage/Documents/GitHub/midigpt-REAPER/test_out.mid'
        
        try:
            #generated_score.save(result_midi_path)
            if DEBUG:
                print(f"\nSaving result to {result_midi_path}")
            generated_score.dump_midi(result_midi_path)
        except Exception as save_error:
            if DEBUG:
                print(f"  Error saving score: {save_error}")
            raise
        
        if not os.path.exists(result_midi_path):
            if DEBUG:
                print(f"  ERROR: Generated MIDI file does not exist")
            raise FileNotFoundError("Generated MIDI file not created")
        
        file_size = os.path.getsize(result_midi_path)
        if file_size == 0:
            if DEBUG:
                print(f"  ERROR: Generated MIDI file is empty")
            raise ValueError("Generated MIDI file is empty")
        
        if DEBUG:
            print(f"  Generation complete, saved to {result_midi_path}")
            print(f"  File size: {file_size} bytes")
        
        ca_result = convert_midi_to_ca_format_with_timing(
            result_midi_path,
            project_measures,
            bar_mode["bars"],
            extra_ids_map,
            input_ticks_per_beat=input_ticks_per_beat,
            input_time_signature=input_time_sig
        )
        
        try:
            #os.unlink(temp_midi_path)
            #os.unlink(result_midi_path)
            pass
        except:
            pass
                
        if DEBUG:
            print(f"\n=== RESULT ===")
            print(f"  CA format: {len(ca_result)} chars")
            print(f"  Preview: {ca_result[:200]}...")
        
        return ca_result
        
    except Exception as e:
        if DEBUG:
            print(f'\nError: {e}')
            import traceback
            traceback.print_exc()
        
        fallback_extra_id = actual_extra_id if 'actual_extra_id' in locals() else 0
        return f";M:0;B:5;L:96;<extra_id_{fallback_extra_id}>N:60;d:240;w:240"

def test():
    print("Server running!")

def start_server():
    print("="*60)
    print("MMM Server")
    print("="*60)
    print(f"Port: {PORT}")
    print(f"MMM: {MMM_AVAILABLE}")
    print("="*60)
    
    server = SimpleXMLRPCServer(('127.0.0.1', PORT), logRequests=DEBUG, allow_none=True)
    server.register_function(call_nn_infill, 'call_nn_infill')
    server.register_function(test, 'test')
    
    print(f"\nServer ready on port {PORT}")
    print("\nPress Ctrl+C to stop\n")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped")


if __name__ == "__main__":
    if MMM_AVAILABLE:
        success = initialize_mmm()
        if not success:
            print("Warning: MMM initialization failed, server will use fallback responses")
    
    start_server()