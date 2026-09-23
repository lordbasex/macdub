#!/usr/bin/env python3
"""Writes a benchmark report (Markdown) from compare.py results.

    scripts/benchmark/report.py results.json env.json out.md [notes.md]

env.json: {"date", "chip", "cores", "memory", "macos", "sdk", "swift", "macdub", "commit", "minutes", "voices", "mode"}
"""
import json, re, sys

NAMES = {"analyzer": "SpeechAnalyzer", "analyzer-volatile": "SpeechAnalyzer (volatile)", "legacy": "SFSpeechRecognizer"}


def f(v, digits=1, unit=""):
    if isinstance(v, (int, float)):
        if v != v:  # NaN
            return "—"
        return f"{v:.{digits}f}{unit}" if isinstance(v, float) else f"{v}{unit}"
    return str(v)


def main():
    results = json.load(open(sys.argv[1]))
    env = json.load(open(sys.argv[2]))
    notes = open(sys.argv[4]).read().strip() if len(sys.argv) > 4 else ""
    cols = [NAMES.get(r["engine"], r["engine"]) for r in results]

    def row(label, key, digits=1, unit="", src=None):
        vals = [f((r if src is None else r[src]).get(key, float("nan")), digits, unit) for r in results]
        return f"| {label} | " + " | ".join(vals) + " |"

    head = "| | " + " | ".join(cols) + " |\n|---|" + "---|" * len(cols)
    out = [f"# Speech recognition benchmark — {env['chip']} — {env['date']}", ""]
    out += ["MacDub's two recognition engines on the same audio, fed through the real dubbing pipeline "
            "(engine → segmentation → what gets translated and spoken). Run with "
            "[`scripts/benchmark/run.sh`](../../scripts/benchmark/run.sh); how it works is in "
            "[the method](#method) below.", ""]
    out += ["## Machine", "", "| | |", "|---|---|",
            f"| Chip | {env['chip']} ({env['cores']}) |", f"| Memory | {env['memory']} |",
            f"| macOS | {env['macos']} |", f"| SDK / Swift | {env['sdk']} · {env['swift']} |",
            f"| MacDub | {env['macdub']} (`{env['commit']}`) |",
            f"| Audio | {env['minutes']} min, voices: {re.sub(r' [(][^,]*[)]', '', env['voices'])} |",
            f"| Runs | {env['mode']} |", ""]
    out += ["## Results", "", head,
            row("Segments emitted", "segments", 0),
            row("**Whole sentences** (one segment per sentence)", "whole_sentences", 1, " %"),
            row("Pieces per sentence", "pieces_per_sentence", 2),
            row("**Word error rate**", "wer", 1, " %"),
            row("· substitutions", "sub", 1, " %"), row("· deletions (words lost)", "del", 1, " %"),
            row("· insertions", "ins", 1, " %"),
            row("Sentence ends: precision", "end_precision", 1, " %"), row("Sentence ends: recall", "end_recall", 1, " %"),
            row("Commas: precision", "comma_precision", 1, " %"), row("Commas: recall", "comma_recall", 1, " %"),
            "| Questions ending in `?` | " + " | ".join(r["questions"] for r in results) + " |",
            row("Latency, median", "latency_median", 2, " s"), row("Latency, p90", "latency_p90", 2, " s"),
            row("Latency, max", "latency_max", 2, " s"),
            row("Longest gap between segments", "max_gap_s", 1, " s"),
            row("Repeated words", "repeated_words", 0),
            row("MacDub CPU (avg)", "macdub_cpu_avg", 1, " %", "resources"),
            row("Speech service CPU (avg)", "xpc_cpu_avg", 1, " %", "resources"),
            row("Speech service CPU (p95)", "xpc_cpu_p95", 1, " %", "resources"),
            "| MacDub memory (start → end) | " + " | ".join(
                f"{f(r['resources'].get('macdub_mem_start', float('nan')))} → "
                f"{f(r['resources'].get('macdub_mem_end', float('nan')))} MB" for r in results) + " |",
            row("Speech service memory (max)", "xpc_mem_max", 0, " MB", "resources"),
            ""]
    out += ["### Over time (stability)", "", "Word error rate and median latency per 10-minute window.", "",
            "| Minutes | " + " | ".join(cols) + " |", "|---|" + "---|" * len(cols)]
    for i in range(max(len(r["windows"]) for r in results)):
        cells = []
        for r in results:
            w = r["windows"][i] if i < len(r["windows"]) else None
            cells.append(f"{f(w['wer'])} % · {f(w['latency_median'], 2)} s" if w else "—")
        w0 = next(r["windows"][i] for r in results if i < len(r["windows"]))
        out.append(f"| {w0['from_min']}–{w0['to_min']:.0f} | " + " | ".join(cells) + " |")
    out += [""]
    if notes:
        out += ["## Notes", "", notes, ""]
    out += [open(__file__.replace("report.py", "METHOD.md")).read().strip(), ""]
    open(sys.argv[3], "w").write("\n".join(out))
    print("wrote", sys.argv[3])


if __name__ == "__main__":
    main()
