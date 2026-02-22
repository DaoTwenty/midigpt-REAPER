desc:MMM Global Options

// -------------------------------------------------------------------------
// Sentinel (never changes)
slider1:jsfx_id=54964318<54964318,54964318,1>-jsfx_id

// -------------------------------------------------------------------------
// Initialization state -- written by MMM_initialize.py via TrackFX_SetParam.
// 0 = not initialized (server not contacted yet)
// 1 = ready
// All other sliders are hidden until this is 1.
slider2:mmm_ready=0<0,1,1{Not Initialized,Ready}>Status

// -------------------------------------------------------------------------
// Initialize trigger -- user clicks this to contact the server.
// Acts as a momentary button: script detects 0->1 transition and resets it.
// Hidden once initialized (replaced by model dropdown).
slider3:do_init=0<0,1,1{-,Initialize}>Initialize

// -------------------------------------------------------------------------
// Model selector -- labels rewritten by MMM_initialize.py to real model names.
// Hidden until initialized.
slider4:model_index=0<0,7,1{Model 0,Model 1,Model 2,Model 3,Model 4,Model 5,Model 6,Model 7}>Model

// -------------------------------------------------------------------------
// Generation parameters -- hidden until initialized.
slider5:temperature=1.0<0.5,2.0,0.1>Temperature
slider6:model_dim=4<2,8,1>Model Dimension
slider7:bars_per_step=1<1,8,1>Bars Per Step
slider8:tracks_per_step=1<1,8,1>Tracks Per Step
slider9:sampling_seed=-1<-1,9999,1>Sampling Seed (-1 = random)
slider10:mask_top_k=0<0,50,1>Top K (0 = disabled)
slider11:mask_top_p=0<0,0.99,0.01>Top P (0 = disabled)

in_pin:none
out_pin:none

@init
_ready_prev = mmm_ready;

@slider

// --- Validate generation params (only matters when ready) ----------------
mmm_ready == 1 ? (
  model_dim < bars_per_step ? model_dim = bars_per_step;
  temperature < 0.5 ? temperature = 0.5;
  temperature > 2.0 ? temperature = 2.0;
);

// --- Show/hide sliders based on initialization state ---------------------
mmm_ready == 0 ? (
  // Not initialized: show only status + initialize button
  slider_show(slider2, 1);   // Status
  slider_show(slider3, 1);   // Initialize button
  slider_show(slider4, 0);   // Model  (hidden)
  slider_show(slider5, 0);   // Temperature
  slider_show(slider6, 0);   // Model Dimension
  slider_show(slider7, 0);   // Bars Per Step
  slider_show(slider8, 0);   // Tracks Per Step
  slider_show(slider9, 0);   // Sampling Seed
  slider_show(slider10, 0);  // Top K
  slider_show(slider11, 0);  // Top P
) : (
  // Initialized: hide the init button, show everything else
  slider_show(slider2, 1);   // Status (shows "Ready")
  slider_show(slider3, 0);   // Initialize button (hidden)
  slider_show(slider4, 1);   // Model dropdown
  slider_show(slider5, 1);   // Temperature
  slider_show(slider6, 1);   // Model Dimension
  slider_show(slider7, 1);   // Bars Per Step
  slider_show(slider8, 1);   // Tracks Per Step
  slider_show(slider9, 1);   // Sampling Seed
  slider_show(slider10, 1);  // Top K
  slider_show(slider11, 1);  // Top P
);

_ready_prev = mmm_ready;