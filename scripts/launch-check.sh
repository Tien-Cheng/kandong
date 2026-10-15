#!/usr/bin/env bash
# Launches a built Kandong.app and checks it starts on this Mac, e.g. one older than the SDK it was
# built with: dyld kills the app before main if it needs a symbol this macOS lacks.
#   scripts/launch-check.sh [path/to/Kandong.app]
# Passes if Kandong is still running after a few seconds, or quit cleanly (it relaunches itself once
# Accessibility is granted). Doesn't touch an installed copy: it runs the given bundle's binary.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Kandong.app}"
SECONDS_TO_RUN=15
log="$(mktemp)"

echo "macOS $(sw_vers -productVersion); Kandong needs $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")+"
"$APP/Contents/MacOS/Kandong" >"$log" 2>&1 &
pid=$!
for ((i = 0; i < SECONDS_TO_RUN; i++)); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done

if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  echo "Kandong launched and was still running after ${SECONDS_TO_RUN}s."
  exit 0
fi
status=0
wait "$pid" || status=$?
if [[ $status -eq 0 ]]; then
  echo "Kandong launched and quit cleanly."
  exit 0
fi
echo "Kandong exited with status $status:"
cat "$log"
exit 1
