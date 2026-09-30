#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
real_cat="$(command -v cat)"
mkdir "$tmp/bin"
cat > "$tmp/bin/cat" <<'SH'
#!/bin/sh
if [ "$1" = /proc/sys/kernel/random/uuid ]; then
  printf 'a07a6146-8847-4fd3-a514-910a88e3955f\n'
else
  exec "$REAL_CAT" "$@"
fi
SH
cat > "$tmp/bin/nextflow" <<'SH'
#!/bin/sh
printf '%s\n' "${NXF_UUID:-}" > "$TEST_UUID_OUT"
printf '%s\n' "$@" > "$TEST_ARGS_OUT"
SH
chmod +x "$tmp/bin/cat" "$tmp/bin/nextflow"

run_entrypoint() {
  local run_id="$1" resume="$2" args_out="$3"
  shift 3
  env PATH="$tmp/bin:$PATH" REAL_CAT="$real_cat" NXF_HOME="$tmp/home" \
    RUN_ID="$run_id" RUN_RESUME="$resume" INPUT=s3://bucket/samplesheet.csv \
    OUTDIR=s3://bucket/results NF_PROFILE=scaleway_kapsule \
    TEST_UUID_OUT="$tmp/${args_out}.uuid" TEST_ARGS_OUT="$tmp/${args_out}.args" \
    sh "$repo_root/kubernetes/base/entrypoint.sh" "$@"
}

run_entrypoint demo 0 first run example
session_id="$(cat "$tmp/home/sessions/demo")"
[[ "$session_id" == a07a6146-8847-4fd3-a514-910a88e3955f ]]
[[ "$(cat "$tmp/first.uuid")" == "$session_id" ]]

if run_entrypoint demo 0 duplicate run example >"$tmp/duplicate.log" 2>&1; then
  echo 'A fresh run overwrote an existing session.' >&2
  exit 1
fi
grep -Fq 'already exists; set RUN_RESUME=1' "$tmp/duplicate.log"
[[ ! -e "$tmp/duplicate.args" ]]
[[ "$(cat "$tmp/home/sessions/demo")" == "$session_id" ]]

run_entrypoint demo 1 resume run example
grep -Fx -- '-resume' "$tmp/resume.args" >/dev/null
grep -Fx -- "$session_id" "$tmp/resume.args" >/dev/null
[[ "$(cat "$tmp/resume.uuid")" == "$session_id" ]]

if run_entrypoint 'Bad ID' 0 invalid-id run example 2>"$tmp/invalid-id.log"; then
  echo 'Invalid RUN_ID was accepted.' >&2
  exit 1
fi
if run_entrypoint missing 1 missing-session run example 2>"$tmp/missing-session.log"; then
  echo 'Resume without a saved session was accepted.' >&2
  exit 1
fi
grep -Fq 'No saved Nextflow session' "$tmp/missing-session.log"

if env PATH="$tmp/bin:$PATH" REAL_CAT="$real_cat" NXF_HOME="$tmp/home" \
  RUN_ID=bad-uri RUN_RESUME=0 INPUT=https://bucket/samplesheet.csv \
  OUTDIR=s3://bucket/results NF_PROFILE=scaleway_kapsule \
  sh "$repo_root/kubernetes/base/entrypoint.sh" run example 2>"$tmp/invalid-uri.log"; then
  echo 'Non-S3 input was accepted.' >&2
  exit 1
fi
grep -Fq 'INPUT must be an S3 URI' "$tmp/invalid-uri.log"

printf 'Nextflow sessions validate inputs, refuse fresh-run overwrite, and resume the saved UUID.\n'
