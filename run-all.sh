#!/bin/bash
# Run all validation spike scenarios one by one.
# Each scenario runs for ~10s then gets stopped.
#
# Usage: ./run-all.sh
# Or run individual: ./run-all.sh 1   (runs only scenario 1)

set -e

SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMEOUT=15

run_scenario() {
  local dir="$1"
  local name="$(basename "$dir")"
  echo ""
  echo "============================================"
  echo "  Running: $name"
  echo "============================================"
  echo ""

  cd "$dir"
  timeout "$TIMEOUT" camel run route.yaml 2>&1 || true
  echo ""
  echo "--- $name finished ---"
  echo ""
  cd "$SPIKE_DIR"
}

if [ -n "$1" ]; then
  scenario_dir="$SPIKE_DIR/scenario$1"*
  for d in $scenario_dir; do
    if [ -d "$d" ]; then
      run_scenario "$d"
    else
      echo "Scenario $1 not found"
      exit 1
    fi
  done
else
  for dir in "$SPIKE_DIR"/scenario*/; do
    run_scenario "$dir"
  done
fi

echo ""
echo "============================================"
echo "  All scenarios completed"
echo "============================================"
