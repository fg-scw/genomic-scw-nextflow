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

env PATH="$tmp/bin:$PATH" REAL_CAT="$real_cat" NXF_HOME="$tmp/home" RUN_ID=demo RUN_RESUME=0 \
  TEST_UUID_OUT="$tmp/first.uuid" TEST_ARGS_OUT="$tmp/first.args" \
  sh "$repo_root/scripts/nextflow-entrypoint.sh" run example
session_id="$(cat "$tmp/home/sessions/demo")"
[[ "$session_id" == a07a6146-8847-4fd3-a514-910a88e3955f && "$(cat "$tmp/first.uuid")" == "$session_id" ]]

env PATH="$tmp/bin:$PATH" REAL_CAT="$real_cat" NXF_HOME="$tmp/home" RUN_ID=demo RUN_RESUME=1 \
  TEST_UUID_OUT="$tmp/resume.uuid" TEST_ARGS_OUT="$tmp/resume.args" \
  sh "$repo_root/scripts/nextflow-entrypoint.sh" run example
grep -Fx -- '-resume' "$tmp/resume.args" >/dev/null
grep -Fx -- "$session_id" "$tmp/resume.args" >/dev/null
printf 'Nextflow session is persisted per run and reused explicitly.\n'
