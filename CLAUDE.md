# SesEQ

System-wide equalizer for macOS, originally tuned for the **Moondrop Chu II IEM on the
MacBook Air M4 3.5mm headphone jack** (but usable with any headphones). Auto-selects a
genre-appropriate EQ preset from what's playing. Author: Göktürk Göcen. Open source —
MIT for the app's own code; the bundled ML model is CC BY-NC-SA 4.0 (see LICENSE / THIRD-PARTY.md).

## Build / run

```bash
./build.sh            # builds build/SesEQ.app (signs with Apple Development if present, else ad-hoc)
./build.sh install    # also copies to /Applications and is the normal deploy step
```
- Plain `swiftc`, no Xcode project. All `Sources/*.swift` compiled together.
- Signs with a stable **Apple Development** identity if one exists (keeps TCC permissions
  across rebuilds), otherwise falls back to ad-hoc signing so anyone can build without an
  Apple Developer account (override via `SIGN_ID=... ./build.sh`). Requires **macOS 26.0+**
  (build target `arm64-apple-macos26.0`, `LSMinimumSystemVersion` 26.0), Apple Silicon (arm64).
  NB: the `@available(macOS 14.2, *)` annotations in source are stale minima; the real
  floor is 26.0 per the build target / Info.plist.
- Menu-bar only (`LSUIElement`). No dock icon.

## What it does

- Captures system audio via **Core Audio process tap** (`muteBehavior = .muted`) + a private
  **aggregate device**, runs it through **AVAudioUnitEQ**, plays back through the real output
  device. No virtual driver / kernel extension (works with just a free Apple ID).
- **EQ is active ONLY on the built-in 3.5mm headphone jack** (`hdpn` data source). Built-in
  speakers, AirPods, any Bluetooth, USB DACs → auto-bypass (Apple's own DSP is left alone).
  Logic in `CoreAudioHelpers.outputIsBuiltinHeadphoneJack` + `AudioEngine.shouldProcessForCurrentDevice`.
- **Muted-tap teardown INVARIANT (do not break):** the tap is a *global* `muteBehavior = .muted`
  tap — while it exists it silences the whole system except SesEQ. So teardown must be bulletproof:
  `teardownAudioResources()` is idempotent and NEVER guarded by `isRunning`; `startCore()` is
  exception-safe (a `defer` tears everything down on any partial-start throw); `stopCore()` always
  tears down (no `guard isRunning` early return). Past bug: a start that failed mid-way during a
  device hot-plug left an **orphaned muted tap** (`isRunning=false` but tap alive → every later
  `stopCore` no-op'd) → the whole Mac stayed muted until SesEQ quit. Also: on Apple Silicon the
  built-in speakers and 3.5mm jack share ONE device ID, so a headphone unplug flips
  `kAudioDevicePropertyDataSource` (ispk↔hdpn) WITHOUT a default-device change —
  `AudioEngine.updateDataSourceListener` watches that so `reconcile()` runs on plug/unplug too.

## EQ presets (`EQPreset.swift`)

- **Chu II baseline** (every music preset): measurement-derived correction → Harman in-ear
  2019v2. 7 filters, the CONSENSUS of 3 independent AutoEQ fits (HypetheSonics/Kazi/Super Review,
  all 711/GRAS-RA0045 + Harman IE 2019v2). This is the important part. Replaced an earlier hand-set
  baseline that mixed a 5128(4620) measurement with the GRAS-Harman target (incompatible) — it had
  no ~6 kHz presence lift and *boosted* the 10 kHz shelf when the Chu 2 actually needs it CUT
  (excess upper treble / ~14 kHz overshoot per ASR). A PEQ is only valid for the coupler+target it
  was fit on — keep measurement and target on the same rig. `maxBands=12` (7 baseline + up to 3 delta).
- Per-genre presets = baseline + small genre delta (hip-hop/trap/edm/.../voice). Deltas are
  engineering judgment, not measured — kept small (≤±4 dB). Voice preset is separate (not Harman).
- `globalGain = preampOffsetDB` (negative, prevents clipping). No makeup gain (user prefers
  clean dynamics over loudness; volume drop is expected, compensate at system volume).

## Auto preset selection (`AutoPresetSelector.swift`)

Per track, resolves a preset in this order:
1. **Pre-fetch cache** — Spotify/YT Music queue lookahead resolved the next track already → instant.
2. **Catalog** (`resolveGenre`) — best source first:
   - **MusicBrainz** (`MusicBrainzService`, primary): community genre votes WITH counts,
     count-weighted into a family via `mapWeightedGenresToPreset` + `genreKeywordRules`. Free,
     no API key (descriptive User-Agent + ≤1 req/s throttle), cached per artist. Accurate at the
     artist level where iTunes mislabels (Buckethead→"Electronic", Dire Straits→"Pop" are both
     fixed → metal / rock). Detection tag carries a `♪` marker (shown as source "MusicBrainz").
   - **iTunes** Search API genre (fallback), WITH `artistNamesRoughlyMatch` verification to reject
     confident wrong matches. Detection tag has no marker → source "katalog".
   - **NOT Spotify**: Spotify removed `genres`/followers/popularity from its Web API in 2024
     (`GET /v1/artists/{id}` returns only name/images/uri — verified live), so it's useless for
     genre. SpotifyAPI is kept only for now-playing + queue pre-fetch.
   On miss, both sources are retried once by splitting an `"Artist - Title"` embedded in the title
   (`splitArtistTitle`) — YouTube channels often put the uploader in the artist slot ("NEA ZIXNH")
   with the real artist in the title ("Gary Moore - Parisienne Walkways"); verified against the
   parsed artist. The popover shows the resolved SOURCE next to the genre dot
   (`EQViewModel.deriveSource`: MusicBrainz / katalog / analiz / ön-yükleme).
3. **Audio-content classifier** (catalog miss) — deferred ~4.5s so the analysis ring fills with
   the current track, then Discogs-EffNet CoreML classifies from the audio itself. Catalog-independent.
4. Default → pop.

Now-playing sources: Spotify Web API (OAuth, has queue pre-fetch), YouTube Music (browser DOM
via AppleScript `execute javascript`, has queue pre-fetch), Apple Music / browsers (AppleScript).
Genre string → preset via `mapGenreToPreset`; Discogs styles → preset via `PresetFamily`.

**Transport controls** (`PlaybackController.swift`): the popover's ⏮ ⏯ ⏭ row routes to whatever
player is currently producing audio (resolved via `AudioSourceMonitor.currentSourceBundleID()` at
press time — no per-frame cost; silent no-op on an unsupported source). Per-source channel:
Spotify & Apple Music via AppleScript transport verbs (`previous track` / `playpause` / `next track`);
YouTube Music via JS click in `ytmusic-player-bar` (`YouTubeMusicService.sendControl`). Spotify uses
AppleScript **not** the Web API, so no extra OAuth scope / re-auth / Premium dependency. YT Music
control selectors were verified against the live DOM: current YTM uses `yt-icon-button` with
`#play-pause-button` / `.next-button` / `.previous-button` (old `tp-yt-paper-icon-button` kept as
fallback). `buildAppleScript(for:runningJS:)` is the shared injector for both read and control JS.

## Audio-content classifier (the big piece)

- **Model**: Discogs-EffNet (MTG-UPF), ONNX → CoreML. Input `[1,128,96]` mel, output 400 styles.
- **Mel** (`MelSpectrogram.swift`, vDSP): symmetric raw Hann → |rfft|² power → 96×257 unit_tri
  slaneyMel filterbank → log10(10000·x+1). **Verified bit-exact vs Essentia TensorflowInputMusiCNN**
  (max diff 0.0 in Python; Swift port self-tests to ~5e-6 on every load).
- **Pipeline & regeneration**: `ml-pipeline/README.md`. Bundled resources: `Resources/DiscogsEffNet.mlmodelc`,
  `mel_filterbank_96x257.f32`, `discogs_styles.txt`, `selftest_*.f32`.
- Audio path: `AudioEngine` IOProc downmixes tapped pre-EQ audio to mono into `AnalysisRingBuffer`
  (6s); `GenreClassifier` snapshots 4s, resamples to 16k (AVAudioConverter), runs inference off
  the main actor, aggregates 400 styles → `PresetFamily` by summed probability.
- **Voice grab-bag guard** (`GenreClassifier.classify`): 16 styles (13 `Non-Music---*` + 3
  `Children's---*`) all map to `.voice`. Summed-probability aggregation lets a sparse/slowed/
  downtempo *music* track leak small probability into many of them and win `.voice` even when no
  single spoken-word style is on top (e.g. slowed tracks like "Indica (Slowed)" → "Podcast").
  Fix: `.voice` may only win if the **single top style** is itself a voice style; otherwise fall
  back to the best non-voice (music) family. Genuine voice still reachable via comm-app bundle
  mapping and catalog genre hints. Don't widen `.voice` membership without re-checking this.
- **Title cleaning** (`cleanMusicTitle`, NowPlayingProviders.swift) strips tempo/edit variant tags
  (`slowed`, `sped up`, `nightcore`, `reverb`, `8d`, `bass boosted`, remaster/remix/live/…) inside
  ( )/[ ] before catalog lookup, so variant titles match the original recording's genre.

## Permissions the user must grant (one-time)

- **Audio Recording** (system audio capture) — first EQ enable.
- **Automation** → Spotify / Music / Chrome / Safari (for now-playing). Entitlement
  `com.apple.security.automation.apple-events` is set; menu has "Otomasyon izinlerini test et".
- **Chrome**: View → Developer → "Allow JavaScript from Apple Events" (for YT Music DOM read).
- **Spotify pre-fetch**: menu "Spotify ile Bağlan" → paste Client ID from developer.spotify.com
  dashboard (redirect URI `http://127.0.0.1:38123/cb`). Premium account. Tokens in Keychain.

## UI (SwiftUI popover)

Menu-bar icon opens an `NSPopover` hosting `PopoverView` (SwiftUI via `NSHostingController`).
`StatusBarController` (NSObject) owns the model and pushes state into `EQViewModel` (ObservableObject).
- **Genre-dynamic accent**: the whole popover's accent color follows the active preset's family
  (`PresetFamily.accent` in `Theme.swift`) — rock=red, edm/techno=blue, country=brown, metal=chrome,
  etc. Animates on genre change.
- **EQ curve**: `FrequencyResponse.swift` computes the preset's combined RBJ-biquad magnitude response;
  drawn as a glowing accent curve with gradient fill in a `Canvas`.
- **Live spectrum analyzer**: `SpectrumAnalyzer.swift` (2048-pt vDSP FFT, 40 log bands, attack/decay)
  fed by a 30fps timer in the controller from `AudioEngine.snapshotAnalysisAudio`. Only animates while
  the popover is open AND EQ is running (headphone jack); decays to flat otherwise.
- Now-playing card, auto-preset toggle, preset chips, and an expandable settings panel
  (Spotify connect, automation/YT tests, login-at-start, quit) — NOT a SwiftUI `Menu` (renders
  unreliably in popovers); a `gearshape` toggle reveals an inline button panel.
- **Only ONE preset chip is shown — `EQPreset.natural` (Chu II — Doğal/Harman).** The other 20
  presets still exist and are used by the auto engine, but the manual chip grid was intentionally
  removed (user found it cluttered/ugly): the active preset — including whatever auto picks per
  track — is already shown under the track title, so a full chip grid was redundant. History: a
  horizontal `ScrollView` of all chips didn't scroll inside `NSPopover` (swipe gesture not
  delivered) → tried a wrapping `FlowLayout` → user asked for just the single natural chip.
  Chip "active" highlight = `preset.name == vm.presetName && (!vm.autoOn || vm.autoHasSource)`
  (`vm.autoHasSource` set in `syncVM`): auto + no source → not highlighted; auto + source →
  follows auto's live pick; manual → the pinned choice.
- Build adds `-framework SwiftUI`. Offline UI verification: `ImageRenderer` collapses `ScrollView`
  content, so use real AppKit `NSHostingView.cacheDisplay` to snapshot the popover faithfully.

## Status

Functionally complete incl. genre-themed SwiftUI UI with live spectrum + EQ curve. All components
validated. Open future ideas (not started): album-art in now-playing card, per-device profiles for
non-Chu-II headphones, user master bass/mid/treble trim.
