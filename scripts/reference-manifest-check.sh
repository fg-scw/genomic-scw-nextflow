#!/bin/sh
set -eu

ref=${1:?Usage: reference-manifest-check.sh <reference-directory>}
manifest="${ref}/reference.manifest"
fasta="${ref}/genome.fa"
gtf="${ref}/genes.gtf"
checksums="${ref}/SHA256SUMS"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

[ -d "$ref" ] || fail "Reference directory is missing: ${ref}"
[ -s "$manifest" ] || fail "Reference manifest is missing or empty: ${manifest}"
[ -s "$fasta" ] || fail "Reference FASTA is missing or empty: ${fasta}"
[ -s "$gtf" ] || fail "Reference GTF is missing or empty: ${gtf}"
[ -s "$checksums" ] || fail "Reference checksums are missing or empty: ${checksums}"
grep -Fx 'assembly=GRCh38' "$manifest" >/dev/null || fail 'Reference manifest assembly is not GRCh38.'
grep -Fx 'ensembl_release=110' "$manifest" >/dev/null || fail 'Reference manifest release is not Ensembl 110.'

fasta_size_entries=$(grep -c '^fasta_size_bytes=' "$manifest" || true)
gtf_size_entries=$(grep -c '^gtf_size_bytes=' "$manifest" || true)
actual_fasta_size=$(file_size "$fasta")
actual_gtf_size=$(file_size "$gtf")

case "${fasta_size_entries}:${gtf_size_entries}" in
  1:1)
    expected_fasta_size=$(sed -n 's/^fasta_size_bytes=//p' "$manifest")
    expected_gtf_size=$(sed -n 's/^gtf_size_bytes=//p' "$manifest")
    case "${expected_fasta_size}:${expected_gtf_size}" in
      *[!0-9:]*|:*|*:) fail 'Reference manifest contains invalid file sizes.' ;;
    esac
    [ "$actual_fasta_size" = "$expected_fasta_size" ] \
      || fail "Reference FASTA size mismatch: expected ${expected_fasta_size}, got ${actual_fasta_size}."
    [ "$actual_gtf_size" = "$expected_gtf_size" ] \
      || fail "Reference GTF size mismatch: expected ${expected_gtf_size}, got ${actual_gtf_size}."
    ;;
  0:0)
    # One full checksum pass upgrades manifests written before size tracking.
    (cd "$ref" && sha256sum -c SHA256SUMS) || fail 'Legacy reference checksum verification failed.'
    tmp_manifest="${manifest}.tmp.$$"
    cat "$manifest" > "$tmp_manifest"
    printf 'fasta_size_bytes=%s\ngtf_size_bytes=%s\n' \
      "$actual_fasta_size" "$actual_gtf_size" >> "$tmp_manifest"
    chmod 0644 "$tmp_manifest"
    mv "$tmp_manifest" "$manifest"
    printf 'Migrated reference manifest with verified file sizes.\n'
    ;;
  *)
    fail 'Reference manifest contains only one file size; refusing an incomplete size check.'
    ;;
esac

printf 'Verified GRCh38 Ensembl 110 reference sizes: FASTA=%s bytes, GTF=%s bytes.\n' \
  "$actual_fasta_size" "$actual_gtf_size"
