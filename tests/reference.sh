#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$repo_root/kubernetes/base/reference.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_reference() {
  local ref="$1"
  mkdir -p "$ref"
  printf '>chr1\nACGT\n' > "$ref/genome.fa"
  printf 'chr1\ttest\tgene\t1\t4\t.\t+\t.\tgene_id "g1";\n' > "$ref/genes.gtf"
  printf 'test checksums\n' > "$ref/SHA256SUMS"
  cat > "$ref/reference.manifest" <<EOF
assembly=GRCh38
ensembl_release=110
fasta_size_bytes=$(wc -c < "$ref/genome.fa" | tr -d '[:space:]')
gtf_size_bytes=$(wc -c < "$ref/genes.gtf" | tr -d '[:space:]')
EOF
}

expect_check_failure() {
  local ref="$1" expected="$2"
  if output=$(sh "$checker" check "$ref" 2>&1); then
    printf 'Expected reference check to fail: %s\n' "$ref" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || {
    printf 'Expected diagnostic "%s", got: %s\n' "$expected" "$output" >&2
    exit 1
  }
}

mkdir "$tmp/bin"
cat > "$tmp/bin/curl" <<EOF
#!/bin/sh
touch '$tmp/curl.called'
exit 1
EOF
chmod +x "$tmp/bin/curl"

modern="$tmp/modern"
make_reference "$modern"
cp "$modern/reference.manifest" "$tmp/manifest.before"
PATH="$tmp/bin:$PATH" sh "$checker" check "$modern" >/dev/null
cmp "$tmp/manifest.before" "$modern/reference.manifest"
[[ ! -e "$tmp/curl.called" ]]

expect_check_failure "$tmp/missing" 'Reference directory is missing'

truncated="$tmp/truncated"
cp -R "$modern" "$truncated"
printf '>chr1\n' > "$truncated/genes.gtf"
expect_check_failure "$truncated" 'size mismatch'

duplicate="$tmp/duplicate"
cp -R "$modern" "$duplicate"
printf 'fasta_size_bytes=12\n' >> "$duplicate/reference.manifest"
expect_check_failure "$duplicate" 'exactly one FASTA size'

legacy="$tmp/legacy"
cp -R "$modern" "$legacy"
sed '/_size_bytes=/d' "$legacy/reference.manifest" > "$tmp/legacy.manifest"
mv "$tmp/legacy.manifest" "$legacy/reference.manifest"
cp "$legacy/reference.manifest" "$tmp/legacy.before"
expect_check_failure "$legacy" 'Legacy reference manifest has no file sizes'
cmp "$tmp/legacy.before" "$legacy/reference.manifest"

printf 'Reference check is read-only and rejects missing, truncated, duplicate-size, and legacy references.\n'
