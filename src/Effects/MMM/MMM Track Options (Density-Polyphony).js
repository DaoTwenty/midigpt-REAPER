desc:MMM Track-Specific Generation Options

slider1:jsfx_id=349583025<349583025, 349583025, 1>-jsfx_id

// Controls
slider20:onset_density=-1<-1, 18, 1>Note density (-1 : No Preference)
slider21:onset_polyphony_min=-1<-1, 6, 1>Minimum Note Onset Polyphony (-1 : No Preference)
slider22:onset_polyphony_max=-1<-1, 6, 1>Maximum Note Onset Polyphony (-1 : No Preference)

in_pin:none
out_pin:none

@init
// Store previous values for change detection
od_prev = onset_density;
opmin_prev = onset_polyphony_min;
opmax_prev = onset_polyphony_max;

@slider

// Store current values
od_prev = onset_density;
opmin_prev = onset_polyphony_min;
opmax_prev = onset_polyphony_max;
