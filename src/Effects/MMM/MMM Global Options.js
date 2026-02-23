desc:MMM Global Options

slider1:jsfx_id=54964318<54964318,54964318,1>-jsfx_id

slider2:temperature=1.0<0.5,2.0,0.1>Temperature
slider3:model_dim=4<2,8,1>Model Dimension
slider4:bars_per_step=1<1,8,1>Bars Per Step
slider5:tracks_per_step=1<1,8,1>Tracks Per Step
slider6:sampling_seed=-1<-1,9999,1>Sampling Seed (-1 = random)
slider7:mask_top_k=0<0,50,1>Top K (0 = disabled)
slider8:mask_top_p=0<0,0.99,0.01>Top P (0 = disabled)
slider9:max_density=-1<-1,32,1>Max Density (-1 = disabled)
slider10:max_polyphony=-1<-1,16,1>Max Polyphony (-1 = disabled)

in_pin:none
out_pin:none

@init

@slider
model_dim < bars_per_step ? model_dim = bars_per_step;
temperature < 0.5 ? temperature = 0.5;
temperature > 2.0 ? temperature = 2.0;