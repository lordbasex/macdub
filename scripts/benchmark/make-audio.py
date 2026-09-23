#!/usr/bin/env python3
"""Builds the recognition benchmark audio and its reference.

    scripts/benchmark/make-audio.py <out-dir> [minutes]

Downloads "The Adventures of Sherlock Holmes" (Project Gutenberg #1661, public domain), takes
the opening story until about `minutes` of speech (default 30), and reads it with macOS `say`
one sentence at a time — three voices taking turns by paragraph, so the recognizer faces more
than one speaker. Sentences are joined with short pauses (0.35 s, 0.9 s between paragraphs)
and every sentence's start and end in the audio is written to reference.json, which is what
makes accuracy, punctuation and latency measurable exactly.

Outputs: <out-dir>/bench.wav (mono 22.05 kHz, 16-bit) and <out-dir>/reference.json.
The text and the voices are the same on every Mac; the synthesized audio can differ slightly
between macOS versions, so reports record the macOS version they were made with.
"""
import json, os, re, subprocess, sys, urllib.request, wave
from concurrent.futures import ThreadPoolExecutor

TEXT_URL = "https://www.gutenberg.org/cache/epub/1661/pg1661.txt"
START = "To Sherlock Holmes she is always"
WORDS_PER_MINUTE = 150          # with the pauses: 4,980 words came out as 27.8 min at 165
PREFERRED = [["Samantha"], ["Reed (English (US))", "Reed (Inglés (EE. UU.))", "Reed"],
             ["Shelley (English (US))", "Shelley (Inglés (EE. UU.))", "Shelley"]]
FALLBACK = ["Samantha", "Alex", "Daniel", "Karen", "Moira", "Tessa"]


def installed_voices():
    # "Reed (English (US))  en_US    # Hello…": the name, then the locale after one or more spaces.
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    names = []
    for line in out.splitlines():
        m = re.match(r"^(.*?)\s+([a-z]{2,3}_[A-Z]{2})\s+#", line)
        if m and m.group(2).startswith("en_"):
            names.append(m.group(1).strip())
    return names


def pick_voices():
    have = installed_voices()
    chosen = []
    for options in PREFERRED:
        v = next((o for o in options if o in have), None)
        if v and v not in chosen:
            chosen.append(v)
    for v in FALLBACK:
        if len(chosen) >= 3:
            break
        if v in have and v not in chosen:
            chosen.append(v)
    if not chosen:
        sys.exit("No English voice installed (System Settings › Accessibility › Spoken Content).")
    return chosen


def main():
    out_dir = sys.argv[1]
    minutes = float(sys.argv[2]) if len(sys.argv) > 2 else 30
    os.makedirs(os.path.join(out_dir, "clips"), exist_ok=True)
    text_path = os.path.join(out_dir, "pg1661.txt")
    if not os.path.exists(text_path):
        urllib.request.urlretrieve(TEXT_URL, text_path)
    raw = open(text_path, encoding="utf-8").read()
    body = raw[raw.index(START):].replace("\r", "")
    paras = [re.sub(r"\s+", " ", p).strip() for p in body.split("\n\n")]
    paras = [p for p in paras if len(p.split()) > 3 and not re.fullmatch(r"[IVXL]+\.", p) and not p.isupper()]
    tr = str.maketrans({"“": '"', "”": '"', "‘": "'", "’": "'", "_": "", "—": ", "})
    voices = pick_voices()
    target_words = int(minutes * WORDS_PER_MINUTE)
    items, words = [], 0
    for pi, p in enumerate(paras):
        p = p.translate(tr).replace("  ", " ")
        for s in re.split(r'(?<=[.?!])"?\s+(?=["\'A-Z])', p):
            s = s.strip()
            if s:
                items.append({"para": pi, "voice": voices[pi % len(voices)], "text": s})
                words += len(s.split())
        if words >= target_words:
            break

    def synth(i):
        path = os.path.join(out_dir, "clips", f"{i:04d}.wav")
        if not os.path.exists(path):
            subprocess.run(["say", "-v", items[i]["voice"], "--file-format=WAVE",
                            "--data-format=LEI16@22050", "-o", path, items[i]["text"]], check=True)
        return path

    with ThreadPoolExecutor(6) as ex:
        files = list(ex.map(synth, range(len(items))))
    rate = 22050
    out = wave.open(os.path.join(out_dir, "bench.wav"), "wb")
    out.setnchannels(1); out.setsampwidth(2); out.setframerate(rate)
    t, prev = 0.0, None
    for it, f in zip(items, files):
        if prev is not None:
            gap = 0.9 if it["para"] != prev else 0.35
            out.writeframes(b"\0\0" * int(gap * rate)); t += gap
        w = wave.open(f); n = w.getnframes(); frames = w.readframes(n); w.close()
        it["start"] = round(t, 3); out.writeframes(frames); t += n / rate; it["end"] = round(t, 3)
        prev = it["para"]
    out.writeframes(b"\0\0" * int(3 * rate)); out.close()
    json.dump({"source": TEXT_URL, "voices": voices, "sentences": items, "duration": round(t + 3, 3)},
              open(os.path.join(out_dir, "reference.json"), "w"), indent=1)
    print(f"{len(items)} sentences, {words} words, {t / 60:.1f} min, voices: {', '.join(voices)}")


if __name__ == "__main__":
    main()
