# Plan: stop SFSpeechRecognizer from losing words

**Status:** not started · **Opened:** 2026-09-23, after MacDub 0.3.1 · **Roadmap:** *Next* #2

`SFSpeechRecognizer` is the only recognition engine on macOS 15 (and the fallback when
SpeechAnalyzer fails on macOS 26). It loses about 14 % of the words and speaks half of the
sentences in pieces. This file is everything needed to pick the work up cold: read it, run the
baseline, then work down the approaches in order.

## Where it stands

From the M1 benchmark ([report](../benchmarks/2026-09-23-apple-m1.md)), 28 minutes of speech:

| | SFSpeechRecognizer | SpeechAnalyzer (for reference) |
|---|---|---|
| Words lost (deletions) | **13.9 %** | 1.3 % |
| Word error rate | 31.6 % | 9.8 % |
| Sentences spoken whole | 49 % | 85 % |
| Sentence ends found | 25 % | 90 % |
| Latency median · p90 · max | 1.1 · 3.1 · 7.1 s | 2.3 · 4.1 · 12.4 s |
| Speech service CPU | 22.7 % | 5.4 % |

A 5-minute run with raw updates (`--log-updates`) reproduces it: **119 of 852 words lost
(14.0 %)**, 29 run rotations — 27 on "silence", 2 on the 45 s limit — one every ~6 s.

## Root cause (measured)

**70 % of the lost words (83 of 119) sit around a "silence" rotation**; the 45 s rotations
account for 2. Losses come in bursts of up to 9 consecutive words. A typical trace (audio time):

```
 128.9      Murder of his clearing up of the sander of the Atkinson brothers
 129.9 ROT  <rotate: silence>          ← "at Trincomalee and finally" is being said 129.3–130.3 s
 131.0      Of the                     ← new task: starts after the words it never received
```

1. **"Silence" is a pause in the *text*, not in the audio.** `TranscriptSegmenter.shouldFlushForSilence`
   fires when no partial result arrived for `silenceFlushInterval` (0.9 s). SFSpeechRecognizer
   stalls that long while people keep talking. (SpeechAnalyzer got an audio-level check in 0.3.0 —
   `silenceConfirmed` — but it is skipped for the legacy engine.)
2. **Rotation cancels the task.** `SFSpeechEngine.restart()` calls `task?.cancel()`: audio the old
   request already received but had not transcribed yet is thrown away, and the new request only
   gets audio from then on. Results of the old generation are ignored by the `generation` check.
3. So every mid-speech rotation drops ~0.5–1.5 s of speech, and short runs (median 6.2 s) also
   give the recognizer little context, which hurts accuracy and punctuation.

## Code map

| What | Where |
|---|---|
| Legacy engine: request/task per run, `restart()` cancels | `Sources/MacDub/Speech/RecognitionEngine.swift` — `SFSpeechEngine.restart()` (~line 164), `stop()` |
| Rotation decisions (silence, 45 s, final, errors) | `Sources/MacDub/Speech/SpeechAndTranslationManager.swift` — `tick()` (~304), `rotate(reason:)` (~250), `handleRunEnded` |
| Audio-level silence check (analyzer only today) | same file — `silenceConfirmed(now:)` (~205), `lastSoundAt` set in `append` |
| Text segmentation and its silence rule | `Sources/MacDubCore/TranscriptSegmenter.swift` — `shouldFlushForSilence`, `cutByTime`, `flush` |
| Trimming text already emitted from a later result (word alignment, tested) | `Sources/MacDubCore/ReportedText.swift` — `remainder(of:after:)` |
| Settings exposed to the user | `silenceFlushInterval` (Settings › Speech › "Silence cut-off"), `maxTaskDuration` = 45 s |

## Approaches, in order

Try them one at a time and benchmark each (see *Measure*); keep what moves the numbers.

1. **Audio-gated silence for the legacy engine too.** Make `silenceConfirmed` apply to every
   engine: rotate on silence only if the *audio* has been quiet (peak < −40 dBFS) for the
   interval, or the text stalled well past it (a few seconds). Smallest change; should remove most
   mid-speech rotations. Watch that real pauses still flush promptly (latency median).
2. **Finish runs instead of cancelling them.** In `SFSpeechEngine.restart()`: call
   `request.endAudio()` on the old request, keep accepting that generation's results until its
   `isFinal` (or ~2 s), and deliver them as the tail of the previous run; start the new request
   immediately so no audio is missed. The manager must emit the old run's final text (trimmed of
   what was already emitted — `ReportedText.remainder`) before the new run's text.
3. **Overlap/replay at the seam.** Keep the last ~1.5 s of audio (a small ring) and feed it to the
   new request first, then drop the duplicated words from its results with `ReportedText.remainder`.
   Recovers words even when the old task can't finish. Pairs with 2.
4. **Rotate less.** With 1–3 in place, revisit the 45 s `maxTaskDuration` and rotation on `isFinal`
   (does SFSpeechRecognizer on macOS 15/26 still degrade past 45 s? measure 60 and 90 s).
5. **Sentence-aware cuts.** `cutByTime` cuts at clause marks after 4.5 s pending; SFSpeechRecognizer
   punctuates little, so check how many of the "pieces" come from time cuts vs rotations
   (`--log-updates` shows both) before tuning.

## Measure

```bash
make benchmark                                   # full: both engines, ~1 h, writes docs/benchmarks/<date>-<chip>.md
scripts/benchmark/run.sh --engines legacy --minutes 10    # quicker, legacy only
```

`run.sh` names its report `docs/benchmarks/<date>-<chip>.md`: on the M1 it would overwrite
`2026-09-23-apple-m1.md` the same day — commit only the report you mean to keep. Changing
`--minutes` regenerates the audio (a different cut of the text), so compare runs of the same length.

For raw updates and rotation reasons on a slice (what this plan's numbers came from):

```bash
W=build/benchmark                               # bench.wav + reference.json from make-audio.py / run.sh
python3 -c "import wave;r=wave.open('$W/bench.wav');w=wave.open('$W/first300.wav','wb');w.setparams(r.getparams());w.writeframes(r.readframes(r.getframerate()*300));w.close()"
open -W -n build/MacDub.app --args --benchmark-recognition $W/first300.wav --engine legacy --log-updates --out $W/legacy-raw.json
python3 scripts/benchmark/compare.py $W/reference.json $W/legacy-raw.json   # clip the reference to 300 s first
```

`updates` in the JSON has every cumulative transcript plus `<rotate: reason>` markers; the
analysis that attributed lost words to rotations is easy to redo from it (align reference words
with `difflib`, spread each sentence's words over its start/end, find the nearest rotation).

## Done when

On the benchmark audio, legacy engine, one engine at a time:

- words lost **≤ 5 %** (from 13.9 %) and word error rate **≤ 25 %** (from 31.6 %);
- sentences spoken whole **≥ 60 %** (from 49 %);
- latency median **≤ 1.5 s** and max **≤ 10 s** (don't trade the loss for long waits);
- no repeated text (`repeated_words` = 0) — replay/overlap must not duplicate;
- SpeechAnalyzer numbers unchanged (it shares the manager);
- verified on real audio too (a video in Chrome), and on macOS 15 if a machine is available.

## Gotchas learned the hard way

- Use `open -n` to launch benchmark runs (TCC attributes permissions to the app, not the terminal);
  `open` without `-n` just activates an already running copy of the same bundle.
- `tccutil reset … com.lordbasex.MacDub` (or Settings › Permissions › Reset) revokes Speech
  Recognition for **every** running MacDub process, benchmark runs included.
- Waiting on runs: match the binary path (`pgrep -f 'Contents/MacOS/MacDub --benchmark-recognition'`);
  a bare `pgrep -f benchmark-recognition` matches the waiting shell itself.
- `scripts/swift-flags.sh` is bash: sourcing it from zsh skips the macOS 27 SDK fallback.
- Benchmark runs checkpoint every minute, so a killed run still leaves data.
- SFSpeechRecognizer results are nondeterministic run to run; compare changes on the same audio,
  and treat a couple of points as noise.
