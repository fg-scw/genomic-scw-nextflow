#!/usr/bin/env bash
# Deploy reference data, run a deterministic human RNA-seq sample, and validate it.
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/smoke-test.sh <run-id> [--resume]
USAGE
}

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
RUN_ID="$1"
validate_run_id "$RUN_ID"
RESUME="${2:-}"
[[ -z "$RESUME" || "$RESUME" == --resume ]] || { usage >&2; exit 2; }

"${SCRIPT_DIR}/bootstrap-reference.sh"
if [[ "$RESUME" != --resume ]]; then
  "${SCRIPT_DIR}/prepare-demo.sh" "$RUN_ID"
fi
if [[ "$RESUME" == --resume ]]; then
  "${SCRIPT_DIR}/run-pipeline.sh" "$RUN_ID" --resume -- --save_align_intermeds true
else
  "${SCRIPT_DIR}/run-pipeline.sh" "$RUN_ID" -- --save_align_intermeds true
fi
"${SCRIPT_DIR}/validate-run.sh" "$RUN_ID"
