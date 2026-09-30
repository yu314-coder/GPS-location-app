#!/usr/bin/env bash
#
# The Apple Watch runs the iPhone's speed engine: the learned store (the algorithm), the bundled
# network and its weights. The watch target cannot compile the iPhone's folder, so it carries
# copies - and a copy that drifts is a different engine. This fails if any copy differs from the
# iPhone's file. To update the watch after changing the iPhone's engine:
#
#     scripts/check_watch_engine.sh --sync
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  "Services/LearnedSpeedEstimator.swift"
  "Services/SpeedNetwork.swift"
  "Resources/speed_network.json"
)
status=0
for f in "${FILES[@]}"; do
  phone="$ROOT/GPS location app/$f"
  watch="$ROOT/GPS location app Watch App/$f"
  if [[ "${1:-}" == "--sync" ]]; then
    cp "$phone" "$watch"
    echo "synced $f"
  elif ! cmp -s "$phone" "$watch"; then
    echo "watch engine differs from the iPhone's: $f (run scripts/check_watch_engine.sh --sync)" >&2
    status=1
  fi
done
exit $status
