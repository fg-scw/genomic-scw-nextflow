#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
for option in --input --outdir -profile --profile -c -C --config -params-file --params-file -w -work-dir --work-dir; do
  if output="$(bash "$repo_root/scripts/run-pipeline.sh" arg-guard-test -- "$option=blocked" 2>&1)"; then
    echo "Expected $option=value to be rejected" >&2
    exit 1
  fi
  [[ "$output" == *"overrides a runner-owned"* ]] || { printf '%s\n' "$output" >&2; exit 1; }
done
printf 'Runner-owned Nextflow option guard passed.\n'
