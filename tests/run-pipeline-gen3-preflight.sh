#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

{
  printf 'set -u\n'
  awk '/check_cmd=.*cat <</ {copy=1} copy {print; if ($0 == "SH") {getline; print; exit}}' \
    "$repo_root/scripts/run-pipeline.sh"
  printf 'printf "%%s\\n" "$check_cmd"\n'
} > "$tmp/build-check.sh"

bash "$tmp/build-check.sh" > "$tmp/check-command"
grep -Fq '$available_kib' "$tmp/check-command"
printf 'GEN3 preflight command preserves inner shell variables under Bash 3.2.\n'
