#!/usr/bin/env bash
# Speech recognition benchmark: builds MacDub, generates the reference audio, runs each
# recognition engine on it in real time, scores the results and writes
# docs/benchmarks/<date>-<chip>.md. See scripts/benchmark/METHOD.md.
#
#   scripts/benchmark/run.sh [--minutes N] [--volatile] [--engines "analyzer legacy"] [--notes file.md]
#
# Engines run one at a time so CPU and memory are measured without interference; a full run
# takes about 2 × minutes. The first run asks for Speech Recognition permission for MacDub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/benchmark"
MINUTES=30
ENGINES=""
VOLATILE=0
NOTES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes) MINUTES="$2"; shift 2 ;;
    --engines) ENGINES="$2"; shift 2 ;;
    --volatile) VOLATILE=1; shift ;;
    --notes) NOTES="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ -z "$ENGINES" ]]; then
  ENGINES="legacy"
  [[ "$MACOS_MAJOR" -ge 26 ]] && ENGINES="analyzer legacy"
  [[ "$MACOS_MAJOR" -ge 26 && "$VOLATILE" == 1 ]] && ENGINES="analyzer analyzer-volatile legacy"
fi
[[ "$(uname -m)" == "arm64" ]] || echo "⚠ Not Apple Silicon: results are still written, but compare like with like."

WORK="$ROOT/build/benchmark"
mkdir -p "$WORK" "$ROOT/docs/benchmarks"

echo "▶ Reference audio ($MINUTES min)"
if [[ ! -f "$WORK/reference.json" || "$(cat "$WORK/.minutes" 2>/dev/null)" != "$MINUTES" ]]; then
  rm -rf "$WORK/clips" "$WORK/bench.wav" "$WORK/reference.json"
  python3 "$HERE/make-audio.py" "$WORK" "$MINUTES"
  echo "$MINUTES" > "$WORK/.minutes"
fi

echo "▶ Building MacDub (native architecture, release)"
ARCHS="$(uname -m)" CONFIG=release "$ROOT/scripts/build-app.sh" 2>&1 | grep -E '^(▶|✔)' || true
APP="$ROOT/build/MacDub.app"

# Keep the Mac awake for the whole run.
caffeinate -i -w $$ &

RUNS=()
TOPS=()
for name in $ENGINES; do
  engine="$name"; extra=()
  if [[ "$name" == "analyzer-volatile" ]]; then engine="analyzer"; extra=(--analyzer-volatile); fi
  out="$WORK/run-$name.json"; top="$WORK/top-$name.txt"
  rm -f "$out" "$top"
  echo "▶ $name: $MINUTES min in real time (started $(date '+%H:%M'))"
  before="$(pgrep -f localspeechrecognition | sort || true)"
  # ${extra[@]+…}: macOS's bash 3.2 treats an empty array as unset under `set -u`.
  open -n "$APP" --args --benchmark-recognition "$WORK/bench.wav" --engine "$engine" ${extra[@]+"${extra[@]}"} \
    --locale en-US --out "$out"
  sleep 10
  app="$(pgrep -f "Contents/MacOS/MacDub --benchmark-recognition.*$out" | head -1 || true)"
  xpc="$(comm -13 <(echo "$before") <(pgrep -f localspeechrecognition | sort) | head -1 || true)"
  while [[ -n "$app" ]] && kill -0 "$app" 2>/dev/null; do
    top -l 2 -s 4 -stats pid,command,cpu,mem,power \
      | awk -v t="$(date +%s)" '/^PID/{n++} n==2 && /MacDub|localspeechrec/ {print t, $0}' >> "$top"
  done
  if [[ ! -s "$out" ]] || python3 -c "import json,sys; sys.exit(0 if 'error' in json.load(open('$out')) else 1)"; then
    echo "✖ $name failed: $(python3 -c "import json; print(json.load(open('$out')).get('error'))" 2>/dev/null || echo 'no output')" >&2
    echo "  (Speech Recognition permission? System Settings › Privacy & Security › Speech Recognition)" >&2
    exit 1
  fi
  RUNS+=("$out"); TOPS+=("$top:${xpc}:${app}")
done

echo "▶ Scoring"
python3 "$HERE/compare.py" "$WORK/reference.json" "${RUNS[@]}" --top "${TOPS[@]}" > "$WORK/results.json"

CHIP="$(sysctl -n machdep.cpu.brand_string)"
P="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "?")"; E="$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo "?")"
source "$ROOT/scripts/swift-flags.sh" 2>/dev/null || true
SDK="$(basename "${SDKROOT:-$(xcrun --show-sdk-path)}" .sdk)"
DATE="$(date +%Y-%m-%d)"
SLUG="$(echo "$CHIP" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')"
python3 - "$WORK/env.json" <<PY
import json, re, subprocess, sys
voices = json.load(open("$WORK/reference.json")).get("voices", [])
env = {
    "date": "$DATE", "chip": "$CHIP",
    "cores": f"$(sysctl -n hw.ncpu) cores: $P performance + $E efficiency",
    "memory": f"{int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'])) // 2**30} GB",
    "macos": "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))",
    "sdk": "$SDK", "swift": "Swift " + (re.search(r"Swift version ([0-9.]+)", subprocess.check_output(["swift", "--version"], stderr=subprocess.STDOUT, text=True)) or re.search("(.*)", "?")).group(1),
    "macdub": subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", "$APP/Contents/Info.plist"], text=True).strip(),
    "commit": subprocess.check_output(["git", "-C", "$ROOT", "rev-parse", "--short", "HEAD"], text=True).strip(),
    "minutes": "$MINUTES", "voices": ", ".join(voices),
    "mode": "one engine at a time: $ENGINES",
}
json.dump(env, open(sys.argv[1], "w"), indent=1)
PY
REPORT="$ROOT/docs/benchmarks/$DATE-$SLUG.md"
python3 "$HERE/report.py" "$WORK/results.json" "$WORK/env.json" "$REPORT" ${NOTES:+"$NOTES"}
cp "$WORK/results.json" "${REPORT%.md}.json"
echo "✔ $REPORT"
