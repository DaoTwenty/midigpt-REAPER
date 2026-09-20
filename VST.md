# README — Recommended Instrument Setup (REAPER)

> **Most of this is automated.** `install.sh` can download Arachno directly into this repo's own `soundfonts/` folder (and opens Sforzando's download page for you, since that one's a real app installer it can't run on your behalf) — see the main [README](README.md#installation). Once both are in place, **Setup Tracks** in the dashboard needs no further manual setup: no importing the `.sf2` by hand, no per-instrument presets. The steps below are for doing it by hand instead (e.g. a custom soundfont), or just to understand what Setup Tracks is doing for you.

---

## Required Components

### 1. Sforzando (SFZ Player)

Download:
[https://www.plogue.com/products/sforzando.html](https://www.plogue.com/products/sforzando.html)

* Free SFZ sampler plugin (VST/AU)
* Used to load and play the General MIDI soundfont

---

### 2. Arachno SoundFont (GM Bank)

Download:
[https://www.arachnosoft.com/main/download.php?id=soundfont-sf2](https://www.arachnosoft.com/main/download.php?id=soundfont-sf2)

* Complete **General MIDI soundfont**
* Covers all **128 GM instruments (programs 0–127)** + drum kits
* Provides the mapping required by this project

---

### 3. MT Power Drum Kit 2 (Drums)

Download:
[https://www.powerdrumkit.com/download76187.php](https://www.powerdrumkit.com/download76187.php)

* High-quality acoustic drum plugin (VST/AU)
* Used instead of GM drums for better realism

---

## Installation

### Step 1 — Install Plugins

1. Install **Sforzando**
2. Install **MT Power Drum Kit 2**
3. Place the **Arachno `.sf2` file** in this repo's `soundfonts/` folder (that's where Setup Tracks looks — see the note above) — or anywhere else, if you're only doing the rest of this by hand and don't need Setup Tracks to find it.

---

### Step 2 — Rescan Plugins in REAPER

After installation:

1. Open REAPER
2. Go to:
   `Options → Preferences → Plug-ins → VST`
3. Click:

   * **“Re-scan”** 

This ensures REAPER detects newly installed VST instruments.

---

## Usage

### Using VST Instruments in REAPER

1. Create a new track
2. Click the **FX** button on the track
3. Search for the plugin (e.g., *Sforzando*, *MT Power Drum Kit*)
4. Double-click to load it

* Go to `Options → Preferences → Plug-ins → VST`
* Click **Re-scan** or **Clear cache / re-scan**

### Load General MIDI Instruments (Sforzando + Arachno)

1. Create a new track
2. Add **Sforzando** as an FX instrument
3. Inside Sforzando:

    * Click on `Instrument → import` then select the **Arachno `.sf2` file**
    * Select an instrument by clicking on `Instrument → converted → sf2 → ...`

* Each program number corresponds to a GM instrument
* This mapping is required for correct playback of generated MIDI

---

### Load Drums (MT Power Drum Kit)

1. Create a separate track
2. Add **MT Power Drum Kit 2**
3. Route drum MIDI (typically channel 10) to this track

---

## Recommended Track Layout

* Track 1: **Sforzando (GM instruments)**
* Track 2: **MT Power Drum Kit (drums)**

---