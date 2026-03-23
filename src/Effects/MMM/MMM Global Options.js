desc:MMM Global Options

slider1:jsfx_id=54964318<54964318,54964318,1>-jsfx_id

slider2:temperature=1.0<0.5,1.9,0.1>Temperature
slider3:model_dim=4<2,8,1>Model Dimension
slider4:bars_per_step=1<1,8,1>Bars Per Step
slider5:tracks_per_step=1<1,8,1>Tracks Per Step
slider6:mask_top_k=0<0,1.0,0.01>Mask Top K Probability (0 = disabled)
slider7:polyphony_hard_limit=0<0,16,1>Polyphony Hard Limit (0 = disabled)

in_pin:none
out_pin:none

@init

@slider
model_dim < bars_per_step ? model_dim = bars_per_step;
temperature < 0.5 ? temperature = 0.5;
temperature > 1.9 ? temperature = 1.9;
