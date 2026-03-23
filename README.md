# MIDI-GPT for REAPER

AI-powered multi-track MIDI generation plugin for [REAPER](https://www.reaper.fm/). Select bars, run the action, and the model fills in musically coherent MIDI — respecting your arrangement, instruments, and per-track controls.

Built on [MIDI-GPT](https://github.com/DaoTwenty/MIDI-GPT) (GPT-2 Transformer for symbolic music) with a custom C++ backend for fast inference.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Quick Install (Release Package)](#quick-install-release-package)
  - [Install from Source](#install-from-source)
  - [Manual Installation](#manual-installation)
- [REAPER Setup](#reaper-setup)
- [Usage Tutorial](#usage-tutorial)
  - [Starting the Server](#1-start-the-server)
  - [Setting Up Your Session](#2-set-up-your-reaper-session)
  - [Context and Selection](#3-context-and-selection)
  - [Running Generation](#4-run-the-generation)
  - [Autoregressive Mode](#5-autoregressive-mode)
- [Controls Reference](#controls-reference)
  - [Global Options](#global-options-monitor-fx)
  - [Track Options](#track-options-per-track-fx)
- [Instruments](#instruments)
- [Troubleshooting](#troubleshooting)
- [Debug Dumps](#debug-dumps)
- [Running Tests](#running-tests)
- [Building a Release Package](#building-a-release-package)
- [Project Structure](#project-structure)
- [Credits](#credits)

---

## How It Works

MIDI-GPT for REAPER has three components:

1. **Inference Server** (`MMM_server.py`) — Loads the model checkpoint and listens for generation jobs on `127.0.0.1:3456`.
2. **REAPER Script** (`REAPER_mmm_infill.py`) — Reads your REAPER session (MIDI, instruments, control values), sends a job to the server, and writes the result back into your project.
3. **JSFX Controls** — Lightweight REAPER effects that give you knobs for temperature, density, polyphony, note duration, and other generation parameters.

The model sees your existing MIDI as context and generates new notes for the bars you select, producing results that fit musically with the surrounding material.

---

## Requirements

- **REAPER** 64-bit (v6 or later) — [Download REAPER](https://www.reaper.fm/download.php) (make sure to select the **64-bit** version for your OS)
- **Python** 3.10 – 3.12 (3.12 recommended) — [Download Python](https://www.python.org/downloads/)
- **OS:** macOS, Linux, or Windows

> **Important:** Download the **64-bit** version of REAPER. The 32-bit version is not compatible with MIDI-GPT.

---

## Installation

### Quick Install (Release Package)

Download the release zip, extract it, and double-click the installer for your OS:

| OS | Installer | What to double-click |
|----|-----------|---------------------|
| macOS | Included | `Install - Mac.command` |
| Linux | Included | `Install - Linux.sh` |
| Windows | Included | `Install - Windows.bat` |

The installer handles everything automatically:

1. **System dependencies** — cmake, protobuf, python (via Homebrew on macOS, winget/choco on Windows)
2. **Python virtual environment** — Creates `.venv/` with PyTorch
3. **C++ backend** — Builds `mmm_refactored` from the bundled minimal source archive
4. **REAPER symlinks** — Links Scripts and Effects into your REAPER config folder
5. **REAPER configuration** — Edits `reaper.ini` to enable ReaScript and set the Python library path (quit REAPER first)
6. **Model checkpoint** — Copies the bundled `model.pt` into place and validates it
7. **Desktop shortcut** — Places a "Start MIDI-GPT Server" launcher on your Desktop

> **Note:** REAPER must be closed during installation. REAPER overwrites `reaper.ini` when it quits, so any changes made while it's running will be lost.

### Install from Source

If you cloned this repo and have the `mmm_refactored` zip separately:

```bash
# macOS / Linux
./install.sh --mmm-zip=/path/to/mmm_refactored.zip

# Windows (PowerShell)
.\install.ps1 -MmmZip C:\path\to\mmm_refactored.zip
```

**Installer flags:**

| macOS/Linux | Windows | Description |
|-------------|---------|-------------|
| `--mmm-zip=PATH` | `-MmmZip PATH` | Path to a local mmm_refactored zip |
| `--skip-deps` | `-SkipDeps` | Skip system dependency check |
| `--skip-reaper-config` | `-SkipReaperConfig` | Don't modify `reaper.ini` |

### Manual Installation

<details>
<summary>Step-by-step manual install (click to expand)</summary>

#### 1. Install system dependencies

You need **Python**, **CMake**, **Protocol Buffers (protobuf)**, and **Git**. Below are instructions for each OS.

**macOS (Homebrew):**

If you don't have Homebrew, install it first: https://brew.sh

```bash
brew install python@3.12 cmake protobuf@21 git
```

> **protobuf@21** is keg-only on Homebrew, meaning it won't be linked to your PATH automatically. The installer handles this, but if building manually you may need to tell CMake where to find it:
> ```bash
> # Apple Silicon (M1/M2/M3/M4):
> export CMAKE_PREFIX_PATH=/opt/homebrew/opt/protobuf@21
> # Intel Mac:
> export CMAKE_PREFIX_PATH=/usr/local/opt/protobuf@21
> ```

**Windows:**

Install [Python 3.12](https://www.python.org/downloads/release/python-3120/) from python.org (check "Add to PATH" during install), then:

```powershell
# Using winget (built into Windows 10/11):
winget install Kitware.CMake --accept-package-agreements
winget install Git.Git --accept-package-agreements

# Or using Chocolatey (https://chocolatey.org/install):
choco install cmake git -y
```

For protobuf on Windows, the installer builds it from source automatically. If you need it separately, install via [vcpkg](https://github.com/microsoft/vcpkg) or download from the [protobuf releases page](https://github.com/protocolbuffers/protobuf/releases/tag/v21.12).

**Ubuntu/Debian:**
```bash
sudo apt update && sudo apt install -y cmake protobuf-compiler libprotobuf-dev python3 python3-venv git
```

**Fedora:**
```bash
sudo dnf install -y cmake protobuf-compiler protobuf-devel python3 git
```

**Arch Linux:**
```bash
sudo pacman -S cmake protobuf python git
```

#### 2. Create a virtual environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip setuptools wheel
```

#### 3. Install PyTorch

```bash
pip install torch>=2.0
```

#### 4. Build the C++ backend

```bash
pip install scikit-build-core pybind11
unzip mmm_refactored.zip -d /tmp/mmm-build
cd /tmp/mmm-build/mmm_refactored

# macOS with Homebrew protobuf@21:
PYBIND11_DIR=$(python -c 'import pybind11; print(pybind11.get_cmake_dir())')
CMAKE_ARGS="-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/protobuf@21 -Dpybind11_DIR=$PYBIND11_DIR" \
  pip install . --no-build-isolation

# Verify
python -c "import mmm_refactored; print('OK')"

# Cleanup
rm -rf /tmp/mmm-build
```

#### 5. Install this package

```bash
pip install -e .
pip install symusic
```

#### 6. Set up REAPER symlinks

```bash
python scripts/setup.py
```

#### 7. Configure REAPER for Python

1. Open REAPER > **Options > Preferences > Plug-Ins > ReaScript**
2. Check **"Enable Python for use with ReaScript"**
3. Set the Python library path. Find it with:

```bash
python -c "
import sysconfig, pathlib, sys
libdir = pathlib.Path(sysconfig.get_config_var('LIBDIR'))
ver = f'{sys.version_info.major}.{sys.version_info.minor}'
for ext in ['.dylib', '.so']:
    for p in sorted(libdir.glob(f'libpython{ver}*{ext}')):
        print(p)
"
```

</details>

---

## REAPER Setup

After installation, you need to load the script and effects into REAPER. This is a one-time setup.

### Step 1: Load the ReaScript Action

1. In REAPER, go to **Actions > Show Action List**
2. Click **Load ReaScript...**
3. Navigate to your REAPER Scripts folder and select **`MMM/REAPER_mmm_infill.py`**
4. (Recommended) Assign a keyboard shortcut — e.g., `Ctrl+G` or `Cmd+G` — so you can trigger generation quickly

### Step 2: Add Global Options to Monitor FX

The Global Options effect controls model-wide settings like temperature and context size.

1. Go to **View > Monitoring Effects** (or click the Monitor FX button on the master track)
2. Click **Add** and search for **`MMM Global Options`**
3. Add it to the Monitor FX chain

This only needs to be done once — Monitor FX persist across all projects.

### Step 3: Add Track Options to Your Tracks

Each track you want to control needs a Track Options effect. This gives you per-track knobs for density, polyphony, note duration, and temperature.

1. Select a track
2. Open its **FX chain** (click the FX button)
3. Add **`MMM Track Options (Density-Polyphony)`**

Repeat for every track where you want generation controls. Tracks without the FX will still be generated but with default parameters.

---

## Usage Tutorial

### 1. Start the Server

Before generating anything, the inference server must be running.

**Easiest way:** Double-click **"Start MIDI-GPT Server"** on your Desktop (created by the installer).

**From terminal:**
```bash
cd /path/to/MIDI-GPT-for-REAPER
source .venv/bin/activate
python src/Scripts/MMM/MMM_server.py --config src/Scripts/MMM/models/config.json
```

The server will print a banner and listen on `127.0.0.1:3456`. Keep this window open while using MIDI-GPT in REAPER.

### 2. Set Up Your REAPER Session

1. **Name your tracks** using General MIDI instrument names (e.g., "Piano", "Bass", "Drums", "Strings"). The model uses instrument identity when generating — a bass track will get bass-appropriate notes.

2. **Set MIDI programs** on each track so the model knows the instrument. For drums, use MIDI channel 10.

3. **Add Track Options FX** to any track where you want generation controls. Tracks without the FX will still be generated but with default parameters.

4. **Write some MIDI** on the tracks that should serve as context. The model works best when it has surrounding material to reference.

### 3. Context and Selection

Understanding how context and selection work is key to getting good results.

#### What is "context"?

Context is the MIDI the model can see when generating. It uses existing notes in your project to produce musically coherent output.

- **Without loop:** The entire REAPER project is the context. The model sees all MIDI on all tracks.
- **With loop enabled:** Only the bars within the loop region are used as context. This is useful for focusing the model on a specific section.

#### What is "selection"?

Selection tells the model which bars to fill in. These are the MIDI items you select (highlight) in the arrange view.

**To select bars for generation:**

1. Create empty MIDI items on the bars and tracks you want to generate
2. Select those items (click, or Ctrl/Cmd+click to select multiple)
3. Run the MIDI-GPT action

The model will replace the contents of selected items with newly generated MIDI, while using everything else as context.

#### Example workflows:

**Fill in a 4-bar gap:**
- You have MIDI on bars 1-8 and 13-16
- Create empty MIDI items on bars 9-12 on the tracks you want
- Select those items
- Run generation — the model fills bars 9-12 using bars 1-8 and 13-16 as context

**Generate a new part over an existing section:**
- You have drums and bass on bars 1-16
- Create empty MIDI items for piano on bars 1-16
- Select the piano items
- Run generation — the model writes piano that fits with your drums and bass

**Regenerate specific bars:**
- You generated 8 bars but don't like bars 5-6
- Select just the items on bars 5-6
- Run generation again — the model re-generates only those bars using everything else (including bars you liked) as context

### 4. Run the Generation

1. Make sure the server is running
2. Select the MIDI items you want to fill
3. Adjust Global Options and Track Options as desired
4. Run the **REAPER_mmm_infill** action (via Actions menu or your keyboard shortcut)

A progress bar will appear in the REAPER console. When done, the generated MIDI appears in your selected items. The action creates an undo point, so you can **Ctrl+Z / Cmd+Z** to undo and try again with different settings.

### 5. Autoregressive Mode

By default, the model generates all selected bars simultaneously (infill mode). **Autoregressive mode** generates bars one at a time, left to right, using each newly generated bar as context for the next.

**When to use autoregressive:**
- When you want to generate an entire track from scratch within the context
- When you want the output to have stronger continuity from bar to bar
- When generating long passages (8+ bars)

**How to enable:**
1. Select all the bars you want to generate on a track
2. In that track's **Track Options** FX, set **Autoregressive** to **On**
3. Run the action

The model generates bar 1, then uses bar 1 as context to generate bar 2, and so on. This produces more coherent long-form output but takes longer since each bar requires a separate inference pass.

> **Tip:** Autoregressive works best when you select all bars within the context on that track. If you're using loop mode, enable the loop, create items for the full loop range on the track, select them all, and toggle autoregressive on.

---

## Controls Reference

### Global Options (Monitor FX)

These settings apply to all tracks and control the model's behavior.

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| **Temperature** | 0.5 – 1.9 | 1.0 | Controls randomness. Lower values (0.5–0.8) produce safer, more predictable output. Higher values (1.2–1.9) produce more varied and surprising results. |
| **Model Dimension** | 2 – 8 | 4 | How many bars of context the model sees at once. Higher = more context but slower. |
| **Bars Per Step** | 1 – 8 | 1 | How many bars to generate in one inference pass. Cannot exceed Model Dimension. |
| **Tracks Per Step** | 1 – 8 | 1 | How many tracks to generate in parallel per step. |
| **Mask Top K** | 0 – 1.0 | 0 | Token masking probability. 0 = disabled. Higher values enable top-k sampling for more diversity. |
| **Polyphony Hard Limit** | 0 – 16 | 0 | Global cap on simultaneous notes per track. 0 = no limit. Useful for keeping output clean. |

**Constraints:**
- **Bars Per Step** is automatically clamped to never exceed **Model Dimension** (you can't generate more bars than the model can see).
- **Temperature** is clamped to the 0.5–1.9 range.

**Temperature tips:**
- **0.7–0.9** — Good starting point. Musically coherent with some variation.
- **1.0** — Default. Balanced between predictability and creativity.
- **1.2–1.5** — More adventurous. Good for brainstorming or generating multiple options.
- **> 1.5** — Increasingly chaotic. Can produce interesting ideas but may be less musically coherent.

### Track Options (Per-Track FX)

These settings apply to individual tracks. Add **MMM Track Options (Density-Polyphony)** to any track's FX chain. Only non-default values are sent to the model.

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| **Density** | 0 – 10 | 0 (any) | Note density, primarily affects drums. 0 = let the model decide. 1 = sparse, 10 = dense. |
| **Polyphony Min** | 0 – 6 | 0 (any) | Minimum simultaneous notes (chords). 0 = no constraint. |
| **Polyphony Max** | 0 – 6 | 0 (any) | Maximum simultaneous notes. 0 = no constraint. |
| **Note Duration Min** | 0 – 6 | 0 (any) | Minimum note length: Any / 32nd / 16th / 8th / Quarter / Half / Whole |
| **Note Duration Max** | 0 – 6 | 0 (any) | Maximum note length (same scale as above). |
| **Polyphony Hard Limit** | 0 – 16 | 0 | Per-track hard cap on simultaneous notes. 0 = use global setting. |
| **Temperature** | 0.5 – 1.9 | 1.0 | Per-track temperature override. |
| **Autoregressive** | Off / On | Off | Generate bars sequentially instead of all at once. |
| **Ignore** | Off / On | Off | Exclude this track from generation entirely. Use as context only. |

**Constraints:**
- **Polyphony Min** cannot exceed **Polyphony Max** (when Max > 0, Min is clamped down to match).
- **Note Duration Min** cannot exceed **Note Duration Max** (same clamping behavior).
- **Temperature** is clamped to 0.5–1.9.

### Ignore vs. Autoregressive

- **Ignore = On**: The track is used purely as context. The model sees its notes but won't generate anything on it. Use this for tracks that are already complete and shouldn't be touched.
- **Autoregressive = On**: The model generates this track bar by bar, each time using the previous output as context. Best for generating long passages from scratch.
- Both off (default): The model generates all selected bars on this track simultaneously (infill mode).

---

## Instruments

The model uses General MIDI program numbers to identify instruments. Set the correct MIDI program on each track so the model knows what it's generating for. **Piano, guitar, bass, strings, and drums** are the most represented in the training data and produce the best results.

Drum tracks are detected automatically when the track's MIDI channel is set to **channel 10**.

<details>
<summary>Full General MIDI Instrument List (click to expand)</summary>

### Piano (0-7)

| Program | Internal Name |
|---------|--------------|
| 0 | `acoustic_grand_piano` |
| 1 | `bright_acoustic_piano` |
| 2 | `electric_grand_piano` |
| 3 | `honky_tonk_piano` |
| 4 | `electric_piano_1` |
| 5 | `electric_piano_2` |
| 6 | `harpsichord` |
| 7 | `clavi` |

### Chromatic Percussion (8-15)

| Program | Internal Name |
|---------|--------------|
| 8 | `celesta` |
| 9 | `glockenspiel` |
| 10 | `music_box` |
| 11 | `vibraphone` |
| 12 | `marimba` |
| 13 | `xylophone` |
| 14 | `tubular_bells` |
| 15 | `dulcimer` |

### Organ (16-23)

| Program | Internal Name |
|---------|--------------|
| 16 | `drawbar_organ` |
| 17 | `percussive_organ` |
| 18 | `rock_organ` |
| 19 | `church_organ` |
| 20 | `reed_organ` |
| 21 | `accordion` |
| 22 | `harmonica` |
| 23 | `tango_accordion` |

### Guitar (24-31)

| Program | Internal Name |
|---------|--------------|
| 24 | `acoustic_guitar_nylon` |
| 25 | `acoustic_guitar_steel` |
| 26 | `electric_guitar_jazz` |
| 27 | `electric_guitar_clean` |
| 28 | `electric_guitar_muted` |
| 29 | `overdriven_guitar` |
| 30 | `distortion_guitar` |
| 31 | `guitar_harmonics` |

### Bass (32-39)

| Program | Internal Name |
|---------|--------------|
| 32 | `acoustic_bass` |
| 33 | `electric_bass_finger` |
| 34 | `electric_bass_pick` |
| 35 | `fretless_bass` |
| 36 | `slap_bass_1` |
| 37 | `slap_bass_2` |
| 38 | `synth_bass_1` |
| 39 | `synth_bass_2` |

### Strings (40-47)

| Program | Internal Name |
|---------|--------------|
| 40 | `violin` |
| 41 | `viola` |
| 42 | `cello` |
| 43 | `contrabass` |
| 44 | `tremolo_strings` |
| 45 | `pizzicato_strings` |
| 46 | `orchestral_harp` |
| 47 | `timpani` |

### Ensemble (48-55)

| Program | Internal Name |
|---------|--------------|
| 48 | `string_ensemble_1` |
| 49 | `string_ensemble_2` |
| 50 | `synth_strings_1` |
| 51 | `synth_strings_2` |
| 52 | `choir_aahs` |
| 53 | `voice_oohs` |
| 54 | `synth_voice` |
| 55 | `orchestra_hit` |

### Brass (56-63)

| Program | Internal Name |
|---------|--------------|
| 56 | `trumpet` |
| 57 | `trombone` |
| 58 | `tuba` |
| 59 | `muted_trumpet` |
| 60 | `french_horn` |
| 61 | `brass_section` |
| 62 | `synth_brass_1` |
| 63 | `synth_brass_2` |

### Reed (64-71)

| Program | Internal Name |
|---------|--------------|
| 64 | `soprano_sax` |
| 65 | `alto_sax` |
| 66 | `tenor_sax` |
| 67 | `baritone_sax` |
| 68 | `oboe` |
| 69 | `english_horn` |
| 70 | `bassoon` |
| 71 | `clarinet` |

### Pipe (72-79)

| Program | Internal Name |
|---------|--------------|
| 72 | `piccolo` |
| 73 | `flute` |
| 74 | `recorder` |
| 75 | `pan_flute` |
| 76 | `blown_bottle` |
| 77 | `shakuhachi` |
| 78 | `whistle` |
| 79 | `ocarina` |

### Synth Lead (80-87)

| Program | Internal Name |
|---------|--------------|
| 80 | `lead_1_square` |
| 81 | `lead_2_sawtooth` |
| 82 | `lead_3_calliope` |
| 83 | `lead_4_chiff` |
| 84 | `lead_5_charang` |
| 85 | `lead_6_voice` |
| 86 | `lead_7_fifths` |
| 87 | `lead_8_bass__lead` |

### Synth Pad (88-95)

| Program | Internal Name |
|---------|--------------|
| 88 | `pad_1_new_age` |
| 89 | `pad_2_warm` |
| 90 | `pad_3_polysynth` |
| 91 | `pad_4_choir` |
| 92 | `pad_5_bowed` |
| 93 | `pad_6_metallic` |
| 94 | `pad_7_halo` |
| 95 | `pad_8_sweep` |

### Synth Effects (96-103)

| Program | Internal Name |
|---------|--------------|
| 96 | `fx_1_rain` |
| 97 | `fx_2_soundtrack` |
| 98 | `fx_3_crystal` |
| 99 | `fx_4_atmosphere` |
| 100 | `fx_5_brightness` |
| 101 | `fx_6_goblins` |
| 102 | `fx_7_echoes` |
| 103 | `fx_8_sci_fi` |

### Ethnic (104-111)

| Program | Internal Name |
|---------|--------------|
| 104 | `sitar` |
| 105 | `banjo` |
| 106 | `shamisen` |
| 107 | `koto` |
| 108 | `kalimba` |
| 109 | `bag_pipe` |
| 110 | `fiddle` |
| 111 | `shanai` |

### Percussive (112-119)

| Program | Internal Name |
|---------|--------------|
| 112 | `tinkle_bell` |
| 113 | `agogo` |
| 114 | `steel_drums` |
| 115 | `woodblock` |
| 116 | `taiko_drum` |
| 117 | `melodic_tom` |
| 118 | `synth_drum` |
| 119 | `reverse_cymbal` |

### Sound Effects (120-127)

| Program | Internal Name |
|---------|--------------|
| 120 | `guitar_fret_noise` |
| 121 | `breath_noise` |
| 122 | `seashore` |
| 123 | `bird_tweet` |
| 124 | `telephone_ring` |
| 125 | `helicopter` |
| 126 | `applause` |
| 127 | `gunshot` |

</details>

**Tips:**
- If you're using a synth or non-GM instrument, pick the closest GM program number for best generation quality.
- You don't need to name your tracks — the MIDI program number is what matters. Track names are for your own reference.

---

## Troubleshooting

### Server won't start

- Make sure the virtual environment is activated: `source .venv/bin/activate`
- Check that `model.pt` exists at the path specified in `src/Scripts/MMM/models/config.json`
- Verify PyTorch is installed: `python -c "import torch; print(torch.__version__)"`

### REAPER says "Python not configured"

The installer configures this automatically, but if you need to do it manually:
1. **Options > Preferences > Plug-Ins > ReaScript**
2. Enable Python and set the dynamic library path
3. The path must point to the **system Python library** (`.dylib` on macOS, `.so` on Linux, `.dll` on Windows), not a file inside the venv

### `protoc` not found during build

On macOS, `protobuf@21` is keg-only. Tell CMake where to find it:
```bash
# Intel Mac
CMAKE_ARGS="-DCMAKE_PREFIX_PATH=/usr/local/opt/protobuf@21" pip install .

# Apple Silicon Mac
CMAKE_ARGS="-DCMAKE_PREFIX_PATH=/opt/homebrew/opt/protobuf@21" pip install .
```

### `import mmm_refactored` fails

Ensure you're in the correct venv:
```bash
source .venv/bin/activate
python -c "import mmm_refactored"
```

If you see torch library errors, reinstall: `pip install torch>=2.0`

### REAPER can't connect to the server

- Verify the server is running and shows "listening on 127.0.0.1:3456"
- Test connectivity: `curl http://127.0.0.1:3456`
- Check that no firewall is blocking localhost port 3456

### Model checkpoint not found

Edit `src/Scripts/MMM/models/config.json` — the `"ckpt"` field should be:
- A relative path (resolved against the config file's directory), e.g. `"model.pt"`
- Or an absolute path to your `.pt` checkpoint file

### Generation produces no output or errors

- Check the server terminal for error messages
- Look at debug dumps in `src/Scripts/MMM/debug_dumps/` for diagnostics
- Make sure you have MIDI items selected (not just time selection)
- Verify the Track Options variant matches your model (check server startup log)

---

## Debug Dumps

Debug dumps are disabled by default. To enable them, set `DEBUG_DUMP_DIR` in `MMM_server.py` to a directory path (e.g., `os.path.join(os.path.dirname(__file__), "debug_dumps")`). Each job then saves diagnostic files:

| File | Contents |
|------|----------|
| `{id}_1_input.mid` | MIDI extracted from REAPER |
| `{id}_2_piece.json` | Encoder's internal representation |
| `{id}_3_status.json` | Track masks and attribute controls |
| `{id}_4_param.json` | Generation hyperparameters |
| `{id}_5_result_piece.json` | Model output (internal format) |
| `{id}_6_result.mid` | Model output as MIDI |
| `{id}_7_result_dict.json` | Final notes sent back to REAPER |

Set `DEBUG_DUMP_DIR = None` to disable again.

---

## Running Tests

```bash
source .venv/bin/activate
python -m pytest tests/ -v
```

---

## Building a Release Package

To create a distributable zip for end users:

```bash
./build_release.sh
```

This bundles:
- midigpt-REAPER source code
- Minimal `mmm_refactored` C++ build archive (~540KB)
- Model checkpoint (`model.pt`)
- Platform-specific double-click installers and server launchers

Options: `--mmm-src=PATH`, `--model=PATH`, `--output=PATH`

---

## Project Structure

```
MIDI-GPT-for-REAPER/
  Install - Mac.command            # macOS double-click installer
  Install - Linux.sh               # Linux double-click installer
  Install - Windows.bat            # Windows double-click installer
  install.sh                       # Core installer (macOS/Linux)
  install.ps1                      # Core installer (Windows/PowerShell)
  Start Server - Mac.command       # macOS server launcher
  Start Server - Windows.bat       # Windows server launcher
  start_mmm_server.sh              # Server launcher (macOS/Linux terminal)
  build_release.sh                 # Release package builder
  src/
    Effects/MMM/
      MMM Global Options.js                    # Monitor FX — global generation controls
      MMM Track Options (Density-Polyphony).js # Per-track FX — density, polyphony, duration
    Scripts/MMM/
      MMM_server.py                # Inference server (XMLRPC on port 3456)
      REAPER_mmm_infill.py         # REAPER client script
      midi_extraction.py           # MIDI extraction from REAPER sessions
      models/
        config.json                # Model config (checkpoint path, AC schema)
        model.pt                   # Model checkpoint (not in git)
  scripts/
    setup.py                       # Creates REAPER symlinks
  tests/
    conftest.py                    # Test stubs for REAPER/C++ deps
    test_midi_extraction.py        # Data structure and extraction tests
    test_server_logic.py           # Server logic and API compliance tests
```

---

## Credits

Based on [MIDI-GPT](https://github.com/DaoTwenty/MIDI-GPT) and originally forked from [Composer's Assistant](https://github.com/m-malandro/composers-assistant-REAPER) by Martin Malandro.
