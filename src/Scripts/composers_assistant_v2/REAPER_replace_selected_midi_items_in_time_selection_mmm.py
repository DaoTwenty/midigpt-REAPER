import rpr_ca_functions as fn
import rpr_mmm_functions as mmm_fn  # Changed from rpr_midigpt_functions
from reaper_python import *
import sys

fn.DEBUG = True

def patch_stdout_stderr_open():
    global open, original_open, reaper_console

    class ReaperConsole:
        def write(self, output):
            RPR_ShowConsoleMsg(output)

        def flush(self):
            pass

        def close(self):
            pass

    reaper_console = ReaperConsole()

    sys.stdout = reaper_console
    sys.stderr = reaper_console

    original_open = open
    open = lambda *args, **kwargs: reaper_console


patch_stdout_stderr_open()


def go():
    options = mmm_fn.get_global_options()  # Changed from midigpt_fn
    
    if fn.DEBUG or options.disp_tr_to_midi_inst:  # Changed from display_track_to_MIDI_inst
        RPR_ClearConsole()
    
    mmm_input, nn_input = fn.get_nn_input_from_project(mask_empty_midi_items=True, mask_selected_midi_items=True,
                                            do_rhythmic_conditioning=options.rhy_cond > 0,  # Updated attribute name
                                            rhythmic_conditioning_type=options.rhy_cond,  # Updated attribute name
                                            do_note_range_conditioning_by_measure=options.do_note_range_cond > 0,  # Updated attribute name
                                            note_range_conditioning_type=options.do_note_range_cond,  # Updated attribute name
                                            display_track_to_MIDI_inst=options.disp_tr_to_midi_inst,  # Updated attribute name
                                            display_warnings=options.display_warnings)
    

    if mmm_input.continue_:
        if fn.DEBUG:
            print('Selection: measures {} to {}'.format(mmm_input.start_measure, mmm_input.end_measure))
            print('nn_input string', nn_input.nn_input_string)
        
        use_sampling = "None" if not fn.ALWAYS_TOP_P else True
               
        # Use MMM-specific wrapper function
        
        nn_output = mmm_fn.call_nn_infill(S=mmm_input.S,
                                          masks=mmm_input.masks,
                                          extra_ids_map=mmm_input.extra_ids_map,
                                          temperature=options.temperature,
                                          start_measure=mmm_input.start_measure,
                                          end_measure=mmm_input.end_measure)
        
        if fn.DEBUG:
            print('got nn output: ', nn_output)
        
        fn.write_nn_output_to_project(nn_output=nn_output, nn_input_obj=nn_input,
                                      notes_are_selected=options.gen_notes_are_selected,  # Updated attribute name
                                      use_vels_from_tr_measures=options.rhy_cond > 0)  # Updated attribute name
        
        
if __name__ == '__main__':
    go()

RPR_Undo_OnStateChange('mmm_Infill')  