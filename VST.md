# Instrument Setup (REAPER)

## Automatic Setup (Recommended)

This is the default, and what most people should just use.

**Setup:** the installer (`install.sh`/`install.ps1`) downloads the Arachno GM SoundFont directly into this repo's own `soundfonts/` folder, and opens Sforzando's download page for you (it's a real application installer, not a data file, so it can't be installed on your behalf the way Arachno can). See the main [README](README.md#installation). Once both are in place, no further manual setup is needed — no importing the `.sf2` by hand, no building an FX chain, no per-instrument presets.

When Sforzando's installer asks which plugin formats to install, pick **VST or VST3** — Setup Tracks builds REAPER's FX chunk for one of those two. **AU and CLAP are not supported**, by design, not just untested: Setup Tracks has no FX chunk format for either, so an AU- or CLAP-only install leaves it reporting Sforzando isn't in REAPER's plugin list even though it's installed.

**Using it:** from the dashboard (`MIDI-GPT.py`),
- **Setup Tracks** — detects each track's GM instrument from its MIDI content (channel 10 → drums, otherwise its first Program Change event) and adds a fresh Sforzando+Arachno instance with the correct GM program already selected, for any track that doesn't have an instrument yet. Safe to re-run: it never touches a track's instrument unless it added it in the first place.
- **Setup Selected Tracks** — same thing, scoped to the current selection instead of the whole project.
- **`MIDI-GPT Replace Instruments.py`** — force-replaces whatever instrument is on *selected* tracks with a freshly generated one, for when you want to redo a track by hand (e.g. you set the wrong instrument, or want to reset it). Scoped to selection only, since it overwrites.

Drums also go through this same path — there's no separate drum plugin involved, Arachno ships its own GM drum kit (bank 128) that Setup Tracks/Replace Instruments select automatically for any track detected as drums.

Track naming drives all of this — see [INSTRUMENTS.md](INSTRUMENTS.md) for the full name/keyword reference.

---

## Manual Setup

For doing it by hand instead — a custom soundfont other than Arachno, a dedicated drum plugin instead of GM drums, or just to understand what the automation above is actually doing for you.

### Components

* **[Sforzando](https://www.plogue.com/products/sforzando.html)** — free SFZ sampler plugin (VST/AU), used to load and play a GM soundfont.
* **A General MIDI soundfont.** [Arachno](https://www.arachnosoft.com/main/download.php?id=soundfont-sf2) (what the automated path uses) covers all 128 GM instruments + drum kits, and is what `install.sh`/`install.ps1` already download into `soundfonts/` — point Sforzando at that file directly if you're setting it up by hand too, rather than downloading a second copy.
* *(Optional)* **A dedicated drum plugin**, if you'd rather use one instead of Arachno's own GM drum kit — e.g. [MT Power Drum Kit 2](https://www.powerdrumkit.com/download76187.php) (free). Not part of the automated path at all; entirely your own FX chain to build if you want it.

### Setup

1. Install Sforzando (and a dedicated drum plugin, if using one).
2. Place your soundfont's `.sf2` file in this repo's `soundfonts/` folder if you still want Setup Tracks to be able to find it for other tracks, or anywhere else if you're doing everything by hand.
3. In REAPER: **Options → Preferences → Plug-ins → VST → Re-scan**, so REAPER picks up the newly installed plugin(s).

### Loading instruments by hand

1. Create a track, click **FX**, add **Sforzando**.
2. Inside Sforzando: **Instrument → Import**, select your `.sf2` file, then **Instrument → Converted → sf2 →** pick the GM program you want. Each program number corresponds to a GM instrument — this mapping is what generated MIDI expects for correct playback (see [INSTRUMENTS.md](INSTRUMENTS.md)).
3. For drums, either select Arachno's own GM drum kit the same way, or add your dedicated drum plugin on its own track instead and route drum MIDI (typically channel 10) to it.

If you re-scan and a newly installed plugin still isn't showing up, try **Preferences → Plug-ins → VST → Clear cache / re-scan**.
