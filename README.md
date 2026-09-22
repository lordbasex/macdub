# MacDub

**Real-time, fully offline dubbing for macOS.**

MacDub captures the audio of any app (Zoom, Teams, VLC, Safari, Chrome, Music — or the whole system), transcribes it, translates it and reads the translation aloud with a system voice, keeping the original quietly in the background like a documentary. Everything runs on your Mac with Apple's own frameworks. No cloud, no API keys, no virtual audio drivers, and the microphone is never touched.

```
 App / system audio ──▶ Speech (on-device) ──▶ Translation (on-device) ──▶ AVSpeechSynthesizer
   Core Audio tap /       original text           translated text            system voice
   ScreenCaptureKit
```

- macOS **15 Sequoia or later** (developed and tested on 15.7.3); ready for macOS 26.
- Universal binary — Intel and Apple Silicon.
- Builds **without Xcode**: the Command Line Tools are enough.
- Interface in English, Spanish and Portuguese (Brazil); easy to add more.
- MIT licensed. Repository: **https://github.com/lordbasex/macdub**

---

## Features

| Area | Feature | Details |
|---|---|---|
| **Capture** | One app or the entire system | Per-app capture follows helper processes (Chrome/Electron helpers, WebKit for Safari); "🔊 Entire system" captures everything except MacDub's own voice. Zoom, Teams, VLC, browsers, Music… The microphone is never captured. |
| | Original audio in the background | Core Audio *process tap* engine: the original is removed from the output and re-played at the level you choose (default 25 %), or lowered only while the translated voice speaks — documentary style. |
| | ScreenCaptureKit fallback | Used automatically when the app has no audio process yet (no background mix in that mode). |
| | Audio buffer for snippets | The last 60 s (configurable, 0 = off) stay in memory so an assistant can request a WAV excerpt through MCP; never written to disk unless asked. |
| **Recognition** | On-device speech recognition | `SFSpeechRecognizer` with on-device models (macOS 15+). |
| | `SpeechAnalyzer` on macOS 26 | Chosen automatically when the OS offers it; live fallback to `SFSpeechRecognizer` if it fails; compiled out on older toolchains. |
| | Smart sentence segmentation | Cuts on punctuation, clause marks, length, pending time and silence; re-anchors when the recognizer rewrites earlier words. Unit-tested. |
| **Translation** | On-device translation | Apple's `Translation` framework, 21 languages, models downloaded once. |
| **Voice** | System voices with quality badges | 🟢 Premium · 🟡 Enhanced · ⚪ Compact · ⚫ novelty; per-voice rate and volume; one-click reload after downloading voices. (Siri voices are not available to third-party apps.) |
| | Latency management | Gentle speed-up when behind (configurable or off), stale sentences skipped past *Max delay*, backlog dropped with one click. Measured: translation ≈ 0.4 s, sentence end → voice ≈ 0.8 s with an empty queue, ≈ 2 s mean. |
| | Karaoke highlighting | The word being spoken is highlighted in the panel, the floating bar and the menu bar panel. |
| **Subtitles** | Transcript panel | Original + translation, per-sentence latency, auto-scroll toggle, subtitles-only mode (voice off). |
| | Floating subtitle bar (⌘B) | Always-on-top pill: 1–6 lines, adjustable width and text size, drag handle, Stop/Start, quick settings, hide. |
| **Menu bar** | Status icon | Green dot while dubbing, amber while starting; click for a panel with the last lines, Start/Stop and quick controls; right-click for a menu. |
| | Menu-bar-only mode | Hide the Dock icon; open at login. |
| | Automation | Auto-start when the selected app starts playing audio; silence watchdog (notice or automatic stop). |
| **Shortcuts** | Global | ⌃⌥D start/stop · ⌃⌥S subtitle bar (no Accessibility permission needed). |
| | In-app | ⌘R start/stop · ⌘B subtitle bar · ⌘K skip backlog · ⌘L clear · ⌘E export .srt · ⇧⌘E export .md · ⌘Y history. |
| **Transcripts** | Export | `.srt` (translation / original / both), `.md` with a session header (made for LLMs), `.txt`. |
| | Session history (⌘Y) | Every session archived when it stops; reopen, export or delete. |
| **AI** | Summaries | Claude Code and Codex CLIs, Ollama and LM Studio (choose the model), Apple Intelligence on macOS 26, or paste into Claude Desktop / ChatGPT — in the dubbing target language. |
| | MCP server | 16 tools, live resources with push notifications, saved sessions as resources, 3 prompts; stdio and Streamable HTTP transports; server-side summaries with local models; one-click registration for Claude Code, Claude Desktop and Codex that survives moving the app. |
| **Platform** | Requirements | macOS 15 Sequoia or later (tested on 15.7.3), Intel and Apple Silicon (universal binary). |
| | Build | No Xcode needed — Command Line Tools with Swift 6; `make setup` installs them if missing. No third-party dependencies. |
| | Languages | Interface in English, Spanish and Portuguese (Brazil); adding one is copying a folder. |
| | Quality | Unit tests (Swift Testing), CI on GitHub Actions, release script with notarization and Homebrew cask. |
| | License | MIT. |

---

## Install

### Homebrew (once the first release is published)

```bash
brew tap lordbasex/macdub https://github.com/lordbasex/macdub
brew install --cask macdub
```

### Download

Grab `MacDub-<version>.zip` from the [Releases](https://github.com/lordbasex/macdub/releases) page, unzip and move `MacDub.app` to `/Applications`. Until releases are notarized, right-click › Open the first time.

### Build from source (no Xcode needed)

```bash
git clone https://github.com/lordbasex/macdub.git
cd macdub
make setup      # checks macOS 15+, Command Line Tools with Swift 6, SDK frameworks; creates the dev signing cert
make run        # native-arch build → build/MacDub.app, then launches it
make            # universal (x86_64 + arm64) build
make zip        # universal zip to try on another Mac
make test       # unit tests
```

There are **no third-party dependencies** — nothing is downloaded. The only requirement is macOS 15+ with the Command Line Tools (Swift ≥ 6.0). On a fresh Mac, `make setup` (or the first `make run`) launches `xcode-select --install` for you, waits for Apple's installer to finish, verifies the SDK and creates the dev signing certificate.

**Signing for development.** The build script signs with a self-signed "MacDub Dev" certificate if it exists (created by `make setup` / `scripts/make-dev-cert.sh`), otherwise ad-hoc. Ad-hoc identities change on every build and macOS then drops the Screen Recording grant, so the certificate is worth having.

## First run

1. **Screen & System Audio Recording** — macOS asks on first launch. Enable MacDub in *System Settings › Privacy & Security* and **relaunch the app** (macOS only applies this grant after a relaunch).
2. **Speech Recognition** — requested when you first press Start.
3. **Spoken language** — pick one marked as on-device. If it says *needs download*, add the language under *System Settings › Keyboard › Dictation* so macOS fetches the model.
4. **Translate to** — press *Prepare translation* once per language pair to download the model (needs internet that one time).
5. **Voice** — choose a voice and press *Test voice*. For better voices: *Manage voices…* → *Accessibility › Spoken Content › System Voice › Manage Voices*, download **Enhanced/Premium** voices, then ↻.
6. Pick **what to capture** (an app or 🔊 Entire system), play something and press **Start dubbing** (⌘R).

> With the tap engine the app must already be producing audio when you press Start; otherwise MacDub tells you and falls back to ScreenCaptureKit (no background mix).

## MCP server

| Kind | Name | What it does |
|---|---|---|
| tool | `get_status` | phase, app, languages, engines, latency, silence, available apps |
| tool | `get_transcript` | current session as `md` (default), `txt`, `srt` or `json`; `content` original/translated/both; ranges: `last` N, `sinceIndex` (incremental reads — json returns `nextIndex`), `fromSeconds`/`toSeconds` |
| tool | `summarize_transcript` | summary produced **by a local model on the Mac** (Apple Intelligence on macOS 26, Ollama, LM Studio) so the transcript never enters the client's context; same range options, `sessionId` for saved sessions |
| tool | `list_local_models` | which local summarisation providers/models exist |
| tool | `search_transcript` | find sentences containing a phrase, with timestamps |
| tool | `list_sessions` / `get_session` | saved sessions and their transcripts |
| tool | `export_session` | write the live or a saved session to a file (srt/md/txt, `path`, `overwrite`) and return its path |
| tool | `get_audio_snippet` | the last N seconds of captured audio as a 16 kHz mono WAV (file path, or embedded audio content with `inline`) — to double-check a sentence with an audio-capable model; MacDub keeps 60 s in memory by default (Settings › Keep audio for snippets) |
| tool | `start_dubbing` / `stop_dubbing` / `clear_transcript` | control the app (`bundleIdentifier` or `system`; apps launched after MacDub are picked up, and the start is confirmed with the engines in use) |
| tool | `set_languages`, `set_voice`, `set_speak`, `set_original_volume` | change languages (while idle), voice, mute the dub, background level — live |
| resource | `macdub://transcript`, `macdub://status` | attachable live context; **subscribable** — the server pushes `notifications/resources/updated` as sentences arrive |
| resource | `macdub://sessions/<id>` (+ `/md|txt|srt|json`) | every saved session is listed as a resource (and offered as templates) so it can be attached as context; `list_changed` fires when sessions are added or deleted |
| prompt | `summarize`, `action_items`, `check_translation` | ready-made instructions over the live transcript |

Register from the app (*AI assistants & MCP › Add to Claude Code / Claude Desktop / Codex*) or by hand:

```bash
# stdio (recommended: Claude Code starts the server on demand). The launcher below is written by
# MacDub on launch and follows the app if you move it; the bundle path works too.
claude mcp add --scope user macdub "$HOME/Library/Application Support/MacDub/bin/macdub-mcp"
# HTTP (when the app serves it: AI assistants & MCP › Also serve over HTTP)
claude mcp add --transport http --scope user macdub-http http://127.0.0.1:8765/mcp
```

```json
{ "mcpServers": { "macdub": { "command": "/Users/<you>/Library/Application Support/MacDub/bin/macdub-mcp" } } }
```

How it works: the app writes `~/Library/Application Support/MacDub/live.json` a few times per second and archives sessions in `sessions/`; the server reads those files and sends commands back through `DistributedNotificationCenter`. MacDub must be running for live data.

**Transports.** stdio by default. `macdub-mcp --http 8765 [--token SECRET]` serves the MCP *Streamable HTTP* transport at `http://127.0.0.1:8765/mcp` (POST for requests and batches, GET with `Accept: text/event-stream` for server notifications, optional bearer token, non-localhost `Origin` rejected). It binds to loopback only; for a remote assistant put it behind a tunnel or reverse proxy with TLS. The app can run it for you: *AI assistants & MCP › Also serve over HTTP on port*.

## Architecture

```
Sources/MacDubCore/            Pure logic, no UI frameworks, unit-tested:
                               Segment, TranscriptSegmenter, TranscriptExporter (srt/md/txt),
                               SpeechRate, LiveState, SessionStore
Sources/MacDubMCP/main.swift   MCP server (JSON-RPC over stdio) → Contents/Helpers/macdub-mcp
Sources/MacDub/
  App/                         MacDubApp (scenes, menus), AppState (pipeline coordinator),
                               AppDelegate, StatusBarController (menu bar)
  Audio/                       ProcessTapCaptureManager (Core Audio tap, default),
                               AudioCaptureManager (ScreenCaptureKit fallback)
  Speech/                      SpeechAndTranslationManager, RecognitionEngine (+ SFSpeechEngine),
                               SpeechAnalyzerEngine (macOS 26), TranslationBridge
  Voice/                       VoiceSynthesisManager (AVSpeechSynthesizer + backlog policy)
  UI/                          ControlPanelView, SubtitlesView, FloatingSubtitlesView (pill),
                               MenuBarPanelView, HistoryView, AIIntegrationView, SpokenText
  Support/                     Settings, Localization, AIIntegration (summaries, MCP install),
                               AppleIntelligenceSummarizer, GlobalHotKey, LaunchAtLogin, errors
  Resources/<lang>.lproj/      Localizable.strings
Tests/Runner/                  Swift Testing suites + executable runner
Packaging/                     Info.plist template, entitlements, AppIcon.icns
scripts/                       build-app.sh, run.sh, make-dev-cert.sh, make-icon.swift,
                               sign-and-notarize.sh, release.sh, reset-permissions.sh
Casks/macdub.rb                Homebrew cask (updated by release.sh)
.github/workflows/ci.yml       Build, test, universal artifact, draft release on tags
```

**Capture.** *Tap engine:* `CATapDescription(stereoMixdownOfProcesses:)` over the app's audio processes (its pid, child processes, bundle-id prefixes, WebKit for Safari) or `stereoGlobalTapButExcludeProcesses` for the whole system, with `muteBehavior = .mutedWhenTapped`; the tap sits in a private aggregate device with the default output, and the IO callback copies input → output scaled by the chosen gain and produces a mono copy for recognition. *ScreenCaptureKit engine:* an audio-only `SCStream` with `SCContentFilter(display:including:)` / `excludingApplications:`, `excludesCurrentProcessAudio = true`.

**Recognition & segmentation.** A `RecognitionEngine` streams a continuously revised transcript. `TranscriptSegmenter` cuts it as soon as a sentence terminator appears, at a clause mark past 90 characters, at the last space before 160, after 4.5 s of pending text without a pause, or on silence; it re-anchors on the tail of already-emitted text when the recognizer rewrites earlier words. `SFSpeechRecognizer` runs are rotated (silence, error, 45 s) because they degrade over time.

**Translation.** `TranslationSession` only exists inside SwiftUI's `.translationTask`; an invisible `TranslationHostView` keeps that closure alive as a job loop.

**Voice.** `AVSpeechSynthesizer` serializes utterances; MacDub adds a catch-up policy (rate boost per queued sentence, capped), stale-sentence skipping and backlog dropping, plus per-word highlighting through `willSpeakRangeOfSpeechString`.

## Tests

```bash
make test
```

Swift Testing suites over `MacDubCore` (segmentation rules, catch-up policy, exporters). They run as an executable because `swift test` needs Xcode's `xctest` loader, which the Command Line Tools don't ship; `Package.swift` adds the CLT `Testing.framework` paths only when Xcode is absent.

## Translations

The UI follows the system language (or *Interface › Language*). To add a language: copy `Sources/MacDub/Resources/en.lproj` to `<code>.lproj`, translate the values in `Localizable.strings` (keys are the English text), add a case to `InterfaceLanguage` in `Support/Localization.swift`, run `plutil -lint` and `make run`. Dynamic strings go through `L("…")` / `LF("…", args)`; SwiftUI literals localize on their own.

## Releasing

```bash
VERSION=0.2.0 CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=MacDub-Notary make release
```

Builds the universal app, signs and notarizes (when the identity and notary profile are set), zips it, writes the SHA-256, updates `Casks/macdub.rb` and creates the GitHub release with `gh`. The CI workflow builds and tests on every push and attaches an unsigned universal zip as a draft release on tags.

## Known limitations

- Latency of roughly 1–3 s is inherent to sentence-by-sentence dubbing.
- On-device speech languages are limited to those with a downloaded Dictation model (usually the system language plus en-US).
- `SFSpeechRecognizer` punctuates poorly for fast talkers; `SpeechAnalyzer` (macOS 26) should improve this.
- Safari plays audio through shared WebKit XPC processes; tapping Safari can affect other WebKit apps.
- No speaker diarization: everyone gets the same voice (the data model has a `speaker` field ready for it).
- Siri voices cannot be used by third-party apps.

## Roadmap

- [ ] Validate `SpeechAnalyzerEngine` and the Apple Intelligence summarizer on macOS 26 hardware (both are compiled and auto-detected; untested until a macOS 26 machine is available).
- [ ] Run and profile the arm64 slice on Apple Silicon.
- [ ] Notarized releases and the Homebrew tap once the Developer ID is available.
- [ ] Speaker diarization (voice per speaker) when Apple exposes it or a lightweight on-device model fits.
- [ ] More UI languages from the community.

## Debugging

```bash
/usr/bin/log stream --predicate 'subsystem == "com.lordbasex.MacDub"' --level info
```

(`log` is also a zsh builtin — the full path matters.) Categories: app, capture, speech, translation, voice.

## License

[MIT](LICENSE) © 2026 lordbasex.
