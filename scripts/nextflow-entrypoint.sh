#!/bin/sh
set -eu

session_dir="${NXF_HOME:-/data/workdir/.nextflow}/sessions"
session_file="${session_dir}/${RUN_ID}"
if [ "$RUN_RESUME" = 1 ]; then
  [ -s "$session_file" ] || { echo "No saved Nextflow session for ${RUN_ID}; migrate the old run session before resuming." >&2; exit 1; }
  session_id="$(cat "$session_file")"
  printf '%s\n' "$session_id" | grep -Eq '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' \
    || { echo "Invalid saved Nextflow session UUID for ${RUN_ID}." >&2; exit 1; }
  exec nextflow "$@" -resume "$session_id"
fi

mkdir -p "$session_dir"
session_id="$(cat /proc/sys/kernel/random/uuid)"
printf '%s\n' "$session_id" > "${session_file}.$$"
mv "${session_file}.$$" "$session_file"
export NXF_UUID="$session_id"
exec nextflow "$@"
