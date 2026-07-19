#!/bin/bash
# Phase 0 capture helper for the 3rd-gen Siri Remote.
# HyperVibe logs every HID event and touch-begin to /tmp/hypervibe.log (via rmDebug).
set -euo pipefail
LOG=/tmp/hypervibe.log

case "${1:-help}" in
  analyze)
    echo "=== Buttons seen (unique page/usage -> name) ==="
    grep "HID event" "$LOG" 2>/dev/null \
      | sed -E 's/.*(page=[^ ]+ usage=[^ ]+).*-> (.*)/\1 -> \2/' | sort -u || echo "(none)"
    echo
    echo "=== Unmapped HID usages (candidate click-ring / mute keys) ==="
    grep "HID event" "$LOG" 2>/dev/null | grep "unmapped" \
      | sed -E 's/.*(page=[^ ]+ usage=[^ ]+).*/\1/' | sort -u || echo "(none)"
    echo
    echo "=== Touch data (clickpad) ==="
    if grep -q "touch begin" "$LOG" 2>/dev/null; then
      echo "YES — clickpad emits multitouch data. Samples:"
      grep "touch begin" "$LOG" | tail -5
    else
      echo "NO 'touch begin' lines found."
      echo "Check the app's stdout for '📱 Trackpad device connected'."
      echo "If that is also absent, the 3rd-gen clickpad likely does NOT register as a"
      echo "multitouch device — meaning touch gestures (Phase 2) are not feasible as-is."
    fi
    ;;
  *)
    cat <<'EOF'
Phase 0 capture — 3rd-gen Siri Remote

  1. Clear the log:        : > /tmp/hypervibe.log
  2. Run the app:          ./HyperVibe
     Grant Accessibility + Input Monitoring when macOS prompts.
  3. Exercise the remote:  press EVERY button, every click-ring direction,
     and drag / tap / swipe the clickpad.
  4. Quit (Ctrl-C), then:  ./capture-phase0.sh analyze

Fill the results into ../docs/superpowers/specs/phase0-findings.md
EOF
    ;;
esac
