# Instrument Names

MIDI-GPT uses General MIDI instrument names to identify tracks. **The track name is ground truth.** MIDI-GPT resolves it in two steps, in order:

1. **Exact match** against one of the 128 canonical internal names in the table below (case-insensitive; spaces and hyphens are treated the same as underscores — `"Baritone Sax"`, `"baritone-sax"`, and `"baritone_sax"` all resolve identically). This always wins when it matches.
2. Otherwise, a **substring keyword match** against the Keywords column below (case-insensitive, keyword anywhere in the name) — the lowest-numbered program whose keyword appears in the name wins. Most instruments have one or more short, informal keywords for this; some (marked *exact name only*) don't have an informal keyword at all and can only be selected by the exact canonical name from step 1.

If neither matches, generation falls back to the track's actual MIDI content: channel 10 → drums, otherwise piano. A resolved name always takes priority over MIDI content — once a track is named, that name (not whatever notes happen to be on it) is what determines its instrument.

**To set a track's instrument:**
- Rename it — with the exact canonical name (e.g. `acoustic_grand_piano`, or just `Baritone Sax` with spaces), or with a shorter keyword if it has one (e.g. `"my piano"`, `"PIANO chords"`, `"bass"` — matching is case-insensitive and just needs the keyword somewhere in the name).
- Or run **Setup Tracks** / **Setup Selected Tracks** from the dashboard to have it auto-detected and renamed for you — see below for exactly how that detection works, which is a separate mechanism from the two steps above.

The mapping below shows **MIDI Program Number** → **Internal Name** → **Keyword(s)** — the Internal Name is the canonical name space your track names get resolved into, and what a soundfont program in Sforzando needs to match for [VST.md](VST.md)'s auto-preset-selection to work.

## Setup Tracks' own detection

**Setup Tracks** / **Setup Selected Tracks** don't use the name-matching rules above at all — they read straight from a track's actual MIDI content, since a freshly-imported multi-track MIDI file usually gives every track the same name (the file name), so name matching alone can't tell them apart yet. For each track: channel 10 → drums; otherwise its first Program Change event, if it has one; otherwise there's nothing to go on, and Setup Tracks asks you to confirm/pick the instrument for that track individually. Whatever it resolves to, the track gets renamed to that instrument's canonical name (the Internal Name column below) — from that point on, the name-matching rules above are what drive generation.

## Drums

A track name containing any of `drum`, `kick`, `kik`, `sn`, `tom`, `hat`, `ride`, `crash`, `china`, or `tambo` resolves to drums (an exact match on `drums` also works, per the canonical-name rule above). If the name doesn't resolve, a track whose MIDI content is on channel 10 also resolves to drums.

| Program | Internal Name |
|---------|--------------|
| (any) | `drums` |

## Piano (0-7)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 0 | `acoustic_grand_piano` | `piano`, `key` |
| 1 | `bright_acoustic_piano` | `bright` |
| 2 | `electric_grand_piano` | *exact name only* |
| 3 | `honky_tonk_piano` | `honk` |
| 4 | `electric_piano_1` | `ep1` |
| 5 | `electric_piano_2` | `ep2` |
| 6 | `harpsichord` | `harpsi` |
| 7 | `clavi` | `clav` |

## Chromatic Percussion (8-15)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 8 | `celesta` | `celest` |
| 9 | `glockenspiel` | `glock` |
| 10 | `music_box` | `box` |
| 11 | `vibraphone` | `vibra` |
| 12 | `marimba` | `marimba` |
| 13 | `xylophone` | `xyl` |
| 14 | `tubular_bells` | `bell`, `tubu` |
| 15 | `dulcimer` | `dulcimer` |

## Organ (16-23)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 16 | `drawbar_organ` | `organ`, `dorg` |
| 17 | `percussive_organ` | `porg` |
| 18 | `rock_organ` | `rorg` |
| 19 | `church_organ` | `corg` |
| 20 | `reed_organ` | `reorg`, `reed` |
| 21 | `accordion` | `acc` |
| 22 | `harmonica` | `harmonica` |
| 23 | `tango_accordion` | `tango` |

## Guitar (24-31)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 24 | `acoustic_guitar_nylon` | `nyl` |
| 25 | `acoustic_guitar_steel` | `steel g`, `sgtr`, `agtr` |
| 26 | `electric_guitar_jazz` | `jazz`, `jgtr` |
| 27 | `electric_guitar_clean` | `cgtr` |
| 28 | `electric_guitar_muted` | `mute`, `mgtr` |
| 29 | `overdriven_guitar` | `ogtr`, `over` |
| 30 | `distortion_guitar` | `gtr`, `guit`, `dist` |
| 31 | `guitar_harmonics` | `harmon` |

Note: `gtr`/`guit` (program 30) will also match a track named e.g. `"acoustic_guitar_nylon"` unless the exact-name rule catches it first — the exact-name step above always runs first for exactly this reason, so naming a track precisely one of the canonical names in this table is always safe regardless of keyword overlap with other instruments.

## Bass (32-39)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 32 | `acoustic_bass` | `aco` |
| 33 | `electric_bass_finger` | `finger` |
| 34 | `electric_bass_pick` | `bass` |
| 35 | `fretless_bass` | `fretless` |
| 36 | `slap_bass_1` | *exact name only* |
| 37 | `slap_bass_2` | `slap` |
| 38 | `synth_bass_1` | `sbass1` |
| 39 | `synth_bass_2` | `sbass2` |

## Strings (40-47)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 40 | `violin` | `violin`, `vn1`, `vn2` |
| 41 | `viola` | `viola`, `vn3` |
| 42 | `cello` | `cell`, `vn4` |
| 43 | `contrabass` | `contra`, `vn5` |
| 44 | `tremolo_strings` | `trem` |
| 45 | `pizzicato_strings` | `pizz` |
| 46 | `orchestral_harp` | `harp` |
| 47 | `timpani` | `timp` |

## Ensemble (48-55)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 48 | `string_ensemble_1` | `str` |
| 49 | `string_ensemble_2` | *exact name only* |
| 50 | `synth_strings_1` | *exact name only* |
| 51 | `synth_strings_2` | *exact name only* |
| 52 | `choir_aahs` | `choir`, `aah` |
| 53 | `voice_oohs` | `ooh` |
| 54 | `synth_voice` | `voice` |
| 55 | `orchestra_hit` | `hit`, `orch` |

## Brass (56-63)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 56 | `trumpet` | `trumpet`, `tp` |
| 57 | `trombone` | `trom` |
| 58 | `tuba` | `tuba` |
| 59 | `muted_trumpet` | `muted` |
| 60 | `french_horn` | `french`, `horn`, `fh` |
| 61 | `brass_section` | `brass` |
| 62 | `synth_brass_1` | *exact name only* |
| 63 | `synth_brass_2` | *exact name only* |

## Reed (64-71)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 64 | `soprano_sax` | `sax` |
| 65 | `alto_sax` | *exact name only* |
| 66 | `tenor_sax` | *exact name only* |
| 67 | `baritone_sax` | *exact name only* |
| 68 | `oboe` | `oboe` |
| 69 | `english_horn` | `english horn`, `english` |
| 70 | `bassoon` | `bsn`, `baso` |
| 71 | `clarinet` | `clarinet` |

Note: `sax` (program 64) matches first for any track name containing "sax" — `alto_sax`/`tenor_sax`/`baritone_sax` have no informal keyword of their own, so use their exact canonical name to select them specifically instead of just "sax".

## Pipe (72-79)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 72 | `piccolo` | `picc` |
| 73 | `flute` | `flute`, `fl1`, `fl2` |
| 74 | `recorder` | `recorder` |
| 75 | `pan_flute` | `pan` |
| 76 | `blown_bottle` | `bottle` |
| 77 | `shakuhachi` | `shak` |
| 78 | `whistle` | `whistle` |
| 79 | `ocarina` | `ocarina` |

## Synth Lead (80-87)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 80 | `lead_1_square` | `square`, `lead1`, `ld1` |
| 81 | `lead_2_sawtooth` | `saw`, `lead2`, `ld2` |
| 82 | `lead_3_calliope` | `calli`, `lead3`, `ld3` |
| 83 | `lead_4_chiff` | `chiff`, `lead4`, `ld4` |
| 84 | `lead_5_charang` | `chara`, `lead5`, `ld5` |
| 85 | `lead_6_voice` | `lead 6`, `ld6` |
| 86 | `lead_7_fifths` | `fifth`, `lead7`, `ld7` |
| 87 | `lead_8_bass__lead` | `lead8`, `ld8` |

## Synth Pad (88-95)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 88 | `pad_1_new_age` | `pad1`, `new`, `age` |
| 89 | `pad_2_warm` | `pad2`, `warm` |
| 90 | `pad_3_polysynth` | `pad3`, `polys` |
| 91 | `pad_4_choir` | `pad4`, `cpad` |
| 92 | `pad_5_bowed` | `pad5`, `bowed` |
| 93 | `pad_6_metallic` | `pad6`, `metallic` |
| 94 | `pad_7_halo` | `pad7`, `halo` |
| 95 | `pad_8_sweep` | `pad8`, `sweep` |

## Synth Effects (96-103)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 96 | `fx_1_rain` | `fx1`, `rain` |
| 97 | `fx_2_soundtrack` | `fx2`, `soundtrack` |
| 98 | `fx_3_crystal` | `fx3`, `crystal` |
| 99 | `fx_4_atmosphere` | `fx4`, `atmos` |
| 100 | `fx_5_brightness` | `fx5` |
| 101 | `fx_6_goblins` | `fx6`, `goblin` |
| 102 | `fx_7_echoes` | `fx7`, `echoes` |
| 103 | `fx_8_sci_fi` | `fx8`, `sci` |

## Ethnic (104-111)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 104 | `sitar` | `sitar` |
| 105 | `banjo` | `banjo` |
| 106 | `shamisen` | `sham` |
| 107 | `koto` | `koto` |
| 108 | `kalimba` | `kali` |
| 109 | `bag_pipe` | `bag`, `pipe` |
| 110 | `fiddle` | `fiddle` |
| 111 | `shanai` | `shan` |

## Percussive (112-119)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 112 | `tinkle_bell` | `tink` |
| 113 | `agogo` | `agog` |
| 114 | `steel_drums` | `steel` |
| 115 | `woodblock` | `wood` |
| 116 | `taiko_drum` | `taiko` |
| 117 | `melodic_tom` | `mtom`, `melodic tom` |
| 118 | `synth_drum` | `synth drum`, `sdrum` |
| 119 | `reverse_cymbal` | `rev` |

## Sound Effects (120-127)

| Program | Internal Name | Keyword(s) |
|---------|--------------|------------|
| 120 | `guitar_fret_noise` | `fret` |
| 121 | `breath_noise` | `breath` |
| 122 | `seashore` | `seashore` |
| 123 | `bird_tweet` | `bird`, `tweet` |
| 124 | `telephone_ring` | `phone` |
| 125 | `helicopter` | `heli` |
| 126 | `applause` | `applause` |
| 127 | `gunshot` | `gunshot` |

## Tips

- The model was trained on General MIDI data, so it performs best with standard GM instruments.
- If you're using a synth or non-GM instrument, pick the closest GM instrument name for best generation quality.
- **Name your tracks explicitly.** A generic name like `"Track 1"` matches nothing above and falls back to MIDI-content detection (channel 10, else piano), so an unresolved name can silently generate the wrong instrument's content. Renaming to the exact canonical name always works regardless of keyword overlap with other instruments — run **Setup Tracks** to auto-detect and rename tracks from their MIDI content instead of doing it by hand.
