desc:MMM Track Options (Density-Polyphony)

slider1:jsfx_id=349583025<349583025,349583025,1>-jsfx_id

slider2:onset_density=-1<-1,18,1>Note Density (-1: No Preference)
slider3:onset_polyphony_min=-1<-1,6,1>Polyphony Min (-1: No Preference)
slider4:onset_polyphony_max=-1<-1,6,1>Polyphony Max (-1: No Preference)

// Fixed behavior flags — use high slot numbers to avoid AC schema collision
slider5:autoregressive=0<0,1,1{Off,On}>Autoregressive
slider6:ignore=0<0,1,1{Off,On}>Ignore Track

in_pin:none
out_pin:none

@init

@slider