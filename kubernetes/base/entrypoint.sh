#!/bin/sh
set -eu

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

RUN_ID=${RUN_ID:-}
INPUT=${INPUT:-}
OUTDIR=${OUTDIR:-}
RUN_RESUME=${RUN_RESUME:-}
NF_PROFILE=${NF_PROFILE:-}

case "$RUN_ID" in
  ''|*[!a-z0-9-]*|-*) fail 'RUN_ID must be 1-40 lowercase letters, digits or hyphens, starting with a letter or digit.' ;;
esac
[ "${#RUN_ID}" -le 40 ] || fail 'RUN_ID must be 1-40 lowercase letters, digits or hyphens, starting with a letter or digit.'

validate_s3_uri() {
  case "$1" in
    s3://?*/*) ;;
    *) fail "$2 must be an S3 URI with a bucket and key: $1" ;;
  esac
  path=${1#s3://}
  bucket=${path%%/*}
  key=${path#*/}
  [ -n "$bucket" ] && [ -n "$key" ] || fail "$2 must be an S3 URI with a bucket and key: $1"
}

validate_s3_uri "$INPUT" INPUT
validate_s3_uri "$OUTDIR" OUTDIR
case "$RUN_RESUME" in
  0|1) ;;
  *) fail 'RUN_RESUME must be 0 or 1.' ;;
esac
[ -n "$NF_PROFILE" ] || fail 'NF_PROFILE must not be empty.'

session_dir="${NXF_HOME:-/data/workdir/.nextflow}/sessions"
session_file="${session_dir}/${RUN_ID}"
if [ "$RUN_RESUME" = 1 ]; then
  [ -s "$session_file" ] || fail "No saved Nextflow session for ${RUN_ID}; use RUN_RESUME=0 for a new run."
  session_id=$(cat "$session_file")
  printf '%s\n' "$session_id" | grep -Eq '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' \
    || fail "Invalid saved Nextflow session UUID for ${RUN_ID}."
  export NXF_UUID="$session_id"
  exec nextflow "$@" -resume "$session_id"
fi

[ ! -e "$session_file" ] || fail "Nextflow session ${RUN_ID} already exists; set RUN_RESUME=1 to reuse it."
mkdir -p "$session_dir"
session_id=$(cat /proc/sys/kernel/random/uuid)
printf '%s\n' "$session_id" | grep -Eq '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' \
  || fail 'Could not generate a valid Nextflow session UUID.'
if ! (set -C; printf '%s\n' "$session_id" > "$session_file"); then
  fail "Nextflow session ${RUN_ID} already exists; set RUN_RESUME=1 to reuse it."
fi
export NXF_UUID="$session_id"
exec nextflow "$@"
