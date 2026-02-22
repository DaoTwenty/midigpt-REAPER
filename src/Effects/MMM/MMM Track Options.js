desc:MMM Track Options

// Sentinel so the client can identify this plugin on any track.
// One plugin covers all model variants -- labels are rewritten live by the
// REAPER client via SetTrackStateChunk when the model changes.
slider1:jsfx_id=349583099<349583099,349583099,1>-jsfx_id

// AC parameter slots (up to 8).
// Labels, ranges, and defaults below are the startup defaults only.
// The client rewrites them to match the active model's AC schema.
// Convention: -1 always means "no preference".
slider2:param_0=-1<-1,64,1>AC Param 1
slider3:param_1=-1<-1,64,1>AC Param 2
slider4:param_2=-1<-1,64,1>AC Param 3
slider5:param_3=-1<-1,64,1>AC Param 4
slider6:param_4=-1<-1,64,1>AC Param 5
slider7:param_5=-1<-1,64,1>AC Param 6
slider8:param_6=-1<-1,64,1>AC Param 7
slider9:param_7=-1<-1,64,1>AC Param 8

in_pin:none
out_pin:none

@init

@slider