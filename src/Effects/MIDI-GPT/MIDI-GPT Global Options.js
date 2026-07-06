desc:MIDI-GPT Global Options

slider1:jsfx_id=54964318<54964318,54964318,1>-jsfx_id
slider2:temperature=1.0<0.1,3.0,0.05>Temperature
slider3:model_dim=4<2,16,1>Context Size (Bars)
slider4:bars_per_step=1<1,16,1>Bars Per Step
slider5:tracks_per_step=1<1,16,1>Tracks Per Step
slider6:polyphony_hard_limit=0<0,32,1>Polyphony Hard Limit (0=Off)
slider7:density_hard_limit=0<0,64,1>Density Hard Limit (0=Off)
slider8:max_attempts=3<1,10,1>Max Attempts
slider9:temp_escalation=1.0<1.0,3.0,0.1>Temp Escalation (1.0=Off)
slider10:top_p=1.0<0.0,1.0,0.05>Top-p (1.0=Off)
slider11:top_k=0<0,500,1>Top-k (0=Off)
slider12:mask_p=0.0<0.0,0.95,0.05>Anti-nucleus mask_p (0.0=Off)
slider13:mask_k=0<0,100,1>Anti-nucleus mask_k (0=Off)
slider14:seed=-1<-1,999999,1>Random Seed (-1=Random)
slider15:checks=3<0,3,1{None,Novelty Only,Silence Only,Both}>Checks (Novelty/Silence)
slider16:shuffle=0<0,1,1{No,Yes}>Shuffle Steps

in_pin:none
out_pin:none

@init

@slider
model_dim < bars_per_step ? model_dim = bars_per_step;
