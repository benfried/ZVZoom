#!/bin/bash
# Double-click from Finder: builds ZVZoom, then runs each line of diag-args.txt as a
# ZVZoom invocation (default: "-v dump"). Output is echoed and saved to diag-dump.txt.
cd "$(dirname "$0")"
OUT="diag-dump.txt"
{
  echo "=== $(date) ==="
  echo "=== swift build ==="
  swift build 2>&1 | grep -v '^\['
  if [ -f diag-args.txt ]; then
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
