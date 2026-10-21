#!/bin/bash
# Double-click from Finder: quits the menubar app, builds ZVZoom, then runs each line of
# diag-args.txt as a ZVZoom invocation (default: "-v dump"). Output is echoed and saved to
# diag-dump.txt; the full build log goes to diag-build.txt.
cd "$(dirname "$0")"
pkill -x ZVZoom 2>/dev/null
touch Sources/ZVZoom/*.swift   # sources written through a mount can be missed by the build cache
OUT="diag-dump.txt"
{
  echo "=== $(date) ==="
  echo "=== swift build ==="
  swift build > diag-build.txt 2>&1
  bstatus=$?
  grep -E "error:|Build complete" diag-build.txt | head -20
  if [ $bstatus -ne 0 ]; then
    echo "=== BUILD FAILED, not running anything ==="
  elif [ -f diag-args.txt ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "=== ZVZoom $line ==="
      .build/debug/ZVZoom $line 2>&1
      echo "=== exit $? ==="
      sleep 2
    done < diag-args.txt
  else
    echo "=== ZVZoom -v dump ==="
    .build/debug/ZVZoom -v dump 2>&1
    echo "=== exit $? ==="
  fi
  echo "=== done ==="
} | tee "$OUT"
echo
echo "Output saved to $PWD/$OUT. You can close this window."
