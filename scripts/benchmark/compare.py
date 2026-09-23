#!/usr/bin/env python3
"""Scores recognition benchmark runs (MacDub --benchmark-recognition) against a reference.

    scripts/benchmark/compare.py reference.json run-analyzer.json run-legacy.json [--top top-analyzer.txt top-legacy.txt]

reference.json: {"sentences": [{"text", "start", "end"}...]} with audio times in seconds (the
benchmark audio is built sentence by sentence, so each sentence's end is known exactly).

Reports per run:
  accuracy     word error rate over the whole transcript and per 10-minute window
  punctuation  precision / recall of sentence ends (. ? !) and commas after correctly
               recognised words, and how many questions end in "?"
  latency      sentence end in the audio -> segment containing its last word emitted
  stability    engine events, repeated text, silent stretches, drift between first and last window
  resources    CPU / memory of MacDub (in-process samples) and, with --top, of the speech XPC service
"""
import difflib, json, re, statistics, sys

WINDOW = 600  # seconds


def words(text):
    """Tokens with the punctuation that follows them: [("word", "."), ...]."""
    out = []
    for m in re.finditer(r"[A-Za-z0-9']+(?:[-'][A-Za-z0-9']+)*([^\sA-Za-z0-9']*)", text):
        w = re.sub(r"[^a-z0-9']", "", m.group(0).lower()).strip("'")
        if not w:
            continue
        tail = m.group(1)
        p = "end" if re.search(r"[.?!]", tail) else "comma" if re.search(r"[,;:]", tail) else ""
        out.append((w, p, "?" in tail))
    return out


def pct(a, b):
    return 100.0 * a / b if b else float("nan")


def quantile(xs, q):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def score(ref, run, top=None):
    sentences = ref["sentences"]
    rw, r_sentence, r_endtime = [], [], []
    for i, s in enumerate(sentences):
        for tok in words(s["text"]):
            rw.append(tok); r_sentence.append(i)
    hw, h_time, h_seg = [], [], []
    for n, seg in enumerate(run["segments"]):
        for tok in words(seg["text"]):
            hw.append(tok); h_time.append(seg["t"]); h_seg.append(n)

    sm = difflib.SequenceMatcher(None, [w for w, _, _ in rw], [w for w, _, _ in hw], autojunk=False)
    ref_to_hyp = {}
    errors = [0] * len(sentences)  # word errors attributed to each reference sentence
    subs = dels = ins = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1):
                ref_to_hyp[i1 + k] = j1 + k
        elif tag == "replace":
            n, m = i2 - i1, j2 - j1
            subs += min(n, m); dels += max(0, n - m); ins += max(0, m - n)
            for k in range(i1, i2):
                errors[r_sentence[k]] += 1
            if m > n:
                errors[r_sentence[i1]] += m - n
        elif tag == "delete":
            dels += i2 - i1
            for k in range(i1, i2):
                errors[r_sentence[k]] += 1
        elif tag == "insert":
            ins += j2 - j1
            errors[r_sentence[min(i1, len(rw) - 1)]] += j2 - j1

    # Punctuation after words recognised correctly.
    punct = {}
    for kind in ("end", "comma"):
        tp = sum(1 for i, j in ref_to_hyp.items() if rw[i][1] == kind and hw[j][1] == kind)
        ref_n = sum(1 for i in ref_to_hyp if rw[i][1] == kind)
        hyp_n = sum(1 for j in ref_to_hyp.values() if hw[j][1] == kind)
        punct[kind] = (pct(tp, hyp_n), pct(tp, ref_n))
    questions = [i for i in ref_to_hyp if rw[i][2]]
    q_ok = sum(1 for i in questions if hw[ref_to_hyp[i]][2])

    # Latency: sentence end -> emission of the segment holding its last recognised word.
    latency = []
    last_word = {}
    for k, si in enumerate(r_sentence):
        last_word[si] = k
    per_sentence_latency = {}
    for si, k in last_word.items():
        # Walk back to the last word of the sentence that was recognised.
        while k >= 0 and r_sentence[k] == si and k not in ref_to_hyp:
            k -= 1
        if k >= 0 and r_sentence[k] == si:
            lat = h_time[ref_to_hyp[k]] - sentences[si]["end"]
            per_sentence_latency[si] = lat
            latency.append(lat)

    # Whole sentences: all recognised words of a reference sentence in one segment. A sentence
    # spread over several segments is translated and spoken in pieces (audible cuts in the voice).
    pieces = {}
    for i, j in ref_to_hyp.items():
        pieces.setdefault(r_sentence[i], set()).add(h_seg[j])
    split = [len(v) for v in pieces.values()]
    whole = sum(1 for n in split if n == 1)

    # Windows over audio time.
    windows = []
    duration = max(s["end"] for s in sentences)
    for w0 in range(0, int(duration) + 1, WINDOW):
        idx = [i for i, s in enumerate(sentences) if w0 <= s["start"] < w0 + WINDOW]
        if not idx:
            continue
        n_words = sum(1 for k in range(len(rw)) if r_sentence[k] in idx)
        lats = [per_sentence_latency[i] for i in idx if i in per_sentence_latency]
        windows.append({"from_min": w0 // 60, "to_min": min(w0 + WINDOW, duration) / 60,
                        "wer": pct(sum(errors[i] for i in idx), n_words),
                        "latency_median": statistics.median(lats) if lats else float("nan"),
                        "latency_p90": quantile(lats, 0.9)})

    # Stability signals.
    # Text emitted twice: the start of a segment repeating the end of the previous one. The
    # longest common run of >= 3 words between the tail of one and the head of the next, allowing
    # a word or two of slack at the edges ("… one particular" / "er, all … one particularly").
    seg_words = [[w for w, _, _ in words(seg["text"])] for seg in run["segments"]]
    repeats = repeated_words = 0
    for a, b in zip(seg_words, seg_words[1:]):
        tail, head = a[-15:], b[:17]
        m = difflib.SequenceMatcher(None, tail, head, autojunk=False).find_longest_match(0, len(tail), 0, len(head))
        if m.size >= 3 and m.a + m.size >= len(tail) - 2 and m.b <= 2:
            repeats += 1
            repeated_words += m.size
    gaps = [b["t"] - a["t"] for a, b in zip(run["segments"], run["segments"][1:])]
    samples = run.get("samples", [])
    res = {}
    if samples:
        cpu = [s["cpuPercent"] for s in samples[1:]] or [0]
        res["macdub_cpu_avg"] = statistics.mean(cpu)
        res["macdub_cpu_p95"] = quantile(cpu, 0.95)
        res["macdub_mem_start"] = samples[0]["footprintMB"]
        res["macdub_mem_end"] = samples[-1]["footprintMB"]
        res["macdub_mem_max"] = max(s["footprintMB"] for s in samples)
    if top:
        res.update(top_stats(top))

    n = len(rw)
    return {
        "engine": run["engine"] + ("-volatile" if run["engine"] == "analyzer" and run.get("analyzerFinalsOnly") is False else ""),
        "requested": run.get("requestedEngine"),
        "audio_min": run["audioSeconds"] / 60, "segments": len(run["segments"]),
        "wer": pct(subs + dels + ins, n), "sub": pct(subs, n), "del": pct(dels, n), "ins": pct(ins, n),
        "end_precision": punct["end"][0], "end_recall": punct["end"][1],
        "comma_precision": punct["comma"][0], "comma_recall": punct["comma"][1],
        "questions": f"{q_ok}/{len(questions)}",
        "whole_sentences": pct(whole, len(split)), "pieces_per_sentence": statistics.mean(split) if split else float("nan"),
        "latency_median": statistics.median(latency) if latency else float("nan"),
        "latency_p90": quantile(latency, 0.9), "latency_max": max(latency) if latency else float("nan"),
        "sentences_with_latency": f"{len(latency)}/{len(sentences)}",
        "repeated_segments": repeats, "repeated_words": repeated_words, "max_gap_s": max(gaps) if gaps else float("nan"),
        "events": [e["event"] for e in run.get("events", []) if e["event"] not in ("stopped",) and not e["event"].startswith("started")],
        "windows": windows, "resources": res,
    }


def top_stats(spec):
    """`top -stats pid,command,cpu,mem,power` lines: the speech service + MacDub benchmark.

    spec is a file, or "file:xpcPID:appPID" when several runs were sampled into one file.
    Without PIDs the busiest speech service and the longest-running MacDub are used."""
    path, *pids = spec.split(":")
    xpc_pid, app_pid = [p or None for p in (pids + [None, None])[:2]]
    rows = {}
    for line in open(path):
        parts = line.split()
        if len(parts) < 6:
            continue
        _, pid, cmd = parts[0], parts[1], parts[2]
        try:
            cpu, power = float(parts[-3]), float(parts[-1])
        except ValueError:
            continue
        mem = parts[-2]
        mb = float(re.sub(r"[^0-9.]", "", mem) or 0) * (1 / 1024 if mem.endswith("K") else 1024 if mem.endswith("G") else 1)
        rows.setdefault((pid, cmd), []).append((cpu, mb, power))
    out = {}
    speech = [v for (pid, cmd), v in rows.items() if cmd.startswith("localspeech") and (xpc_pid is None or pid == xpc_pid)]
    if speech:
        busiest = max(speech, key=lambda v: sum(c for c, _, _ in v))
        out["xpc_cpu_avg"] = statistics.mean(c for c, _, _ in busiest)
        out["xpc_cpu_p95"] = quantile([c for c, _, _ in busiest], 0.95)
        out["xpc_mem_max"] = max(m for _, m, _ in busiest)
        out["xpc_power_avg"] = statistics.mean(p for _, _, p in busiest)
    app = [v for (pid, cmd), v in rows.items() if cmd.startswith("MacDub") and (app_pid is None or pid == app_pid)]
    if app:
        best = max(app, key=len)
        out["macdub_power_avg"] = statistics.mean(p for _, _, p in best)
        out["macdub_cpu_top_avg"] = statistics.mean(c for c, _, _ in best)
    return out


def main():
    args = sys.argv[1:]
    tops = []
    if "--top" in args:
        i = args.index("--top")
        tops = args[i + 1:]
        args = args[:i]
    ref = json.load(open(args[0]))
    results = []
    for k, path in enumerate(args[1:]):
        run = json.load(open(path))
        results.append(score(ref, run, tops[k] if k < len(tops) else None))
    print(json.dumps(results, indent=1, default=lambda x: round(x, 2) if isinstance(x, float) else str(x)))


if __name__ == "__main__":
    main()
