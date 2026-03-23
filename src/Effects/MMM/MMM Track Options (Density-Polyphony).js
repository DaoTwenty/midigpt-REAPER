desc:MMM Track Options (MIDI-GPT)

slider1:jsfx_id=349583025<349583025,349583025,1>-jsfx_id

slider2:density=0<0,10,1>Density - Drums Only (0: Any)
slider3:min_polyphony_q=0<0,6,1>Polyphony Min (0: Any)
slider4:max_polyphony_q=0<0,6,1>Polyphony Max (0: Any)
slider5:min_note_duration_q=0<0,6,1{Any,32nd,16th,8th,Quarter,Half,Whole}>Note Duration Min
slider6:max_note_duration_q=0<0,6,1{Any,32nd,16th,8th,Quarter,Half,Whole}>Note Duration Max
slider7:polyphony_hard_limit=0<0,16,1>Polyphony Hard Limit (0: None)
slider8:temperature=1.0<0.5,1.9,0.1>Track Temperature

// Behavior flags
slider9:autoregressive=0<0,1,1{Off,On}>Autoregressive
slider10:ignore=0<0,1,1{Off,On}>Ignore Track

in_pin:none
out_pin:none

@init

@slider
temperature < 0.5 ? temperature = 0.5;
temperature > 1.9 ? temperature = 1.9;
min_polyphony_q > max_polyphony_q && max_polyphony_q > 0 ? min_polyphony_q = max_polyphony_q;
min_note_duration_q > max_note_duration_q && max_note_duration_q > 0 ? min_note_duration_q = max_note_duration_q;
