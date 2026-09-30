#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

awk -v quote="'''" '
  index($0, "beforeScript = " quote) { inside=1; next }
  inside && index($0, quote) { exit }
  inside { print }
' "$repo_root/kubernetes/base/nextflow.config" > "$tmp/guard.sh"
[[ -s "$tmp/guard.sh" ]]
mkdir "$tmp/scratch"
sed -e "s|/proc/mounts|${tmp}/mounts|" -e "s|/scratch|${tmp}/scratch|g" \
  "$tmp/guard.sh" > "$tmp/guard-test.sh"
bash -n "$tmp/guard-test.sh"

mkdir "$tmp/bin"
cat > "$tmp/bin/df" <<'SH'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/sdb 100000000 1 %s 1%% /scratch\n' "${SCRATCH_KIB:-70000000}"
SH
chmod +x "$tmp/bin/df"
printf '/dev/root / ext4 ro 0 0\n/dev/sdb %s ext4 rw 0 0\n' "$tmp/scratch" > "$tmp/mounts"

PATH="$tmp/bin:$PATH" bash "$tmp/guard-test.sh" > "$tmp/output"
grep -Fq 'Verified scratch mount: source=/dev/sdb filesystem=ext4 root-source=/dev/root' "$tmp/output"

printf '/dev/sdb / ext4 ro 0 0\n/dev/sdb %s ext4 rw 0 0\n' "$tmp/scratch" > "$tmp/mounts"
if PATH="$tmp/bin:$PATH" bash "$tmp/guard-test.sh" > "$tmp/output" 2>&1; then
  echo 'Scratch guard accepted /scratch with the root mount source.' >&2
  exit 1
fi
grep -Fq 'shares its filesystem source with root' "$tmp/output"

printf '/dev/root / ext4 ro 0 0\n/dev/sdb %s ext4 rw 0 0\n' "$tmp/scratch" > "$tmp/mounts"
if PATH="$tmp/bin:$PATH" SCRATCH_KIB=62914559 bash "$tmp/guard-test.sh" > "$tmp/output" 2>&1; then
  echo 'Scratch guard accepted less than 60 GiB free.' >&2
  exit 1
fi
grep -Fq 'Expected at least 60 GiB free' "$tmp/output"

printf 'GEN3 task guard verifies scratch filesystem, device and free capacity.\n'
