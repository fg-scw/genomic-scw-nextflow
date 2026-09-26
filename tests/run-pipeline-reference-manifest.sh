#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

make_reference() {
  local ref="$1"
  mkdir -p "$ref"
  printf '>chr1\nACGT\n' > "$ref/genome.fa"
  printf 'chr1\ttest\tgene\t1\t4\t.\t+\t.\tgene_id "g1";\n' > "$ref/genes.gtf"
  (cd "$ref" && sha256sum genome.fa genes.gtf > SHA256SUMS)
}

write_manifest() {
  local ref="$1" with_sizes="$2"
  {
    printf 'assembly=GRCh38\nensembl_release=110\n'
    printf 'fasta_sha256=%s\ngtf_sha256=%s\n' \
      "$(awk '$2 == "genome.fa" {print $1}' "$ref/SHA256SUMS")" \
      "$(awk '$2 == "genes.gtf" {print $1}' "$ref/SHA256SUMS")"
    if [[ "$with_sizes" == true ]]; then
      printf 'fasta_size_bytes=%s\ngtf_size_bytes=%s\n' \
        "$(file_size "$ref/genome.fa")" \
        "$(file_size "$ref/genes.gtf")"
    fi
  } > "$ref/reference.manifest"
}

checker="$repo_root/scripts/reference-manifest-check.sh"
mkdir "$tmp/bin"
real_sha256sum="$(command -v sha256sum)"
cat > "$tmp/bin/sha256sum" <<EOF
#!/bin/sh
printf 'called\\n' >> '$tmp/sha256sum.calls'
exec '$real_sha256sum' "\$@"
EOF
chmod +x "$tmp/bin/sha256sum"

modern="$tmp/modern"
make_reference "$modern"
write_manifest "$modern" true
PATH="$tmp/bin:$PATH" sh "$checker" "$modern" >/dev/null
[[ ! -e "$tmp/sha256sum.calls" ]]

missing="$tmp/missing"
if sh "$checker" "$missing" >/dev/null 2>&1; then
  echo 'Expected a missing reference to fail.' >&2
  exit 1
fi

truncated="$tmp/truncated"
cp -R "$modern" "$truncated"
head -c 5 "$truncated/genes.gtf" > "$truncated/genes.gtf.tmp"
mv "$truncated/genes.gtf.tmp" "$truncated/genes.gtf"
if sh "$checker" "$truncated" >/dev/null 2>&1; then
  echo 'Expected a truncated reference to fail.' >&2
  exit 1
fi

legacy="$tmp/legacy"
make_reference "$legacy"
write_manifest "$legacy" false
PATH="$tmp/bin:$PATH" sh "$checker" "$legacy" >/dev/null
[[ "$(grep -c '^called$' "$tmp/sha256sum.calls")" == 1 ]]
grep -Fq 'fasta_size_bytes=' "$legacy/reference.manifest"
grep -Fq 'gtf_size_bytes=' "$legacy/reference.manifest"
PATH="$tmp/bin:$PATH" sh "$checker" "$legacy" >/dev/null
[[ "$(grep -c '^called$' "$tmp/sha256sum.calls")" == 1 ]]

printf 'Reference checks catch loss/truncation and migrate legacy manifests with one checksum pass.\n'
