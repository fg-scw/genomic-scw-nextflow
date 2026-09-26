#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk -v quote="'''" '
  index($0, "beforeScript = " quote) { inside=1; next }
  inside && index($0, quote) { exit }
  inside { print }
' "$repo_root/nextflow/nextflow.config" > "$tmp/guard.sh"
[[ -s "$tmp/guard.sh" ]]
mkdir "$tmp/scratch"
sed -e "s|/proc/mounts|${tmp}/mounts|" -e "s|/scratch|${tmp}/scratch|g" \
  "$tmp/guard.sh" > "$tmp/guard-test.sh"
bash -n "$tmp/guard-test.sh"

mkdir "$tmp/bin"
cat > "$tmp/bin/stat" <<'SH'
#!/bin/sh
case "$3" in
  "${SCRATCH_PATH:-/scratch}") printf '%s\n' "${SCRATCH_DEVICE:-10}" ;;
  /) printf '%s\n' "${ROOT_DEVICE:-1}" ;;
  *) exit 2 ;;
esac
SH
cat > "$tmp/bin/df" <<'SH'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/sdb 100000000 1 %s 1%% /scratch\n' "${SCRATCH_KIB:-70000000}"
SH
chmod +x "$tmp/bin/stat" "$tmp/bin/df"
printf '/dev/sdb %s ext4 rw 0 0\n' "$tmp/scratch" > "$tmp/mounts"

PATH="$tmp/bin:$PATH" SCRATCH_PATH="$tmp/scratch" bash "$tmp/guard-test.sh" > "$tmp/output"
grep -Fq 'Verified scratch mount: source=/dev/sdb filesystem=ext4' "$tmp/output"

if PATH="$tmp/bin:$PATH" SCRATCH_PATH="$tmp/scratch" SCRATCH_DEVICE=1 bash "$tmp/guard-test.sh" > "$tmp/output" 2>&1; then
  echo 'Scratch guard accepted /scratch on the root filesystem.' >&2
  exit 1
fi
grep -Fq 'not a separate scratch volume' "$tmp/output"

if PATH="$tmp/bin:$PATH" SCRATCH_PATH="$tmp/scratch" SCRATCH_KIB=62914559 bash "$tmp/guard-test.sh" > "$tmp/output" 2>&1; then
  echo 'Scratch guard accepted less than 60 GiB free.' >&2
  exit 1
fi
grep -Fq 'Expected at least 60 GiB free' "$tmp/output"

printf 'GEN3 task guard verifies scratch filesystem, device and free capacity.\n'
