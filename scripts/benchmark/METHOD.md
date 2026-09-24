## Method

**Audio.** `scripts/benchmark/make-audio.py` takes the opening of *The Adventures of Sherlock Holmes* (Project Gutenberg #1661, public domain) and has macOS `say` read it one sentence at a time, three English voices taking turns by paragraph (Samantha, Reed and Shelley when installed). Sentences are joined with 0.35 s pauses (0.9 s between paragraphs). Because the audio is built sentence by sentence, the reference knows exactly what was said and when each sentence ends. The text has dialogue, questions and long sentences, which is what makes punctuation and segmentation measurable. Synthesized speech is cleaner than a real video, so absolute error rates are optimistic; the comparison between engines is what matters.

**Pipeline.** MacDub runs headless (`MacDub --benchmark-recognition <file> --engine <analyzer|legacy>`): the file is converted to what the capture engines deliver (mono float32, 48 kHz, 1024-frame buffers) and fed to the real `SpeechAndTranslationManager` **in real time**, so run rotation, silence cuts and segmentation behave exactly as while dubbing. Every emitted segment — the unit that gets translated and spoken — is recorded with the audio time it came out at. Translation and speech synthesis are not part of the measurement.

**Engines.**
- **SpeechAnalyzer** (macOS 26+): `SpeechTranscriber` with volatile results. MacDub segments its *finalized* results — whole, corrected sentences — and only shows the volatile ones live.
- **SpeechAnalyzer (volatile)** (`--analyzer-volatile`, optional): the older behaviour, segmenting volatile results as they arrive.
- **SFSpeechRecognizer**: on-device recognition with partial results. Runs are rotated at the first pause in the audio after 30 s (at 45 s at the latest) and on real silence; a rotated run finishes its audio instead of being cancelled.

**Metrics** (`scripts/benchmark/compare.py`), after aligning recognized words to the reference (case and punctuation ignored):
- *Word error rate*: (substitutions + deletions + insertions) / reference words.
- *Whole sentences*: share of reference sentences whose recognized words all came out in one segment. A sentence split over several segments is translated and spoken in pieces, and the voice sounds cut.
- *Punctuation*: precision and recall of sentence ends (`. ? !`) and commas after correctly recognized words, and how many questions end in `?`.
- *Latency*: from the end of a sentence in the audio to the emission of the segment holding its last recognized word.
- *Stability*: the same metrics per 10-minute window, repeated text, gaps.
- *Resources*: MacDub's CPU and memory (sampled in-process every 5 s) and the `localspeechrecognition` XPC service serving the run (`top` every 5 s). `top`'s energy column on Apple Silicon tracks CPU for these processes; Neural Engine energy is not measured (that needs `sudo powermetrics`).

**Run your own** on any Mac (Apple Silicon recommended; SpeechAnalyzer needs macOS 26):

```bash
make benchmark                          # 30 min of audio per engine, one engine at a time
scripts/benchmark/run.sh --minutes 10   # quicker
scripts/benchmark/run.sh --volatile     # also measure SpeechAnalyzer's volatile mode
```

The first run asks for Speech Recognition permission for MacDub. Keep the Mac awake and plugged in, and avoid heavy work while it runs. The report lands in `docs/benchmarks/<date>-<chip>.md` — pull requests with results from other chips are welcome.
