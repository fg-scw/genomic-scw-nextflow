#!/bin/sh
set -eu

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
size() { wc -c < "$1" | tr -d '[:space:]'; }
value() {
  awk -F= -v key="$1" '$1 == key { n++; if (NF != 2) bad=1; v=$2 }
    END { if (n != 1 || bad) exit 1; print v }' "$2"
}

check_reference() {
  check_dir=$1
  check_manifest="$check_dir/reference.manifest"
  check_fasta="$check_dir/genome.fa"
  check_gtf="$check_dir/genes.gtf"
  check_hashes="$check_dir/SHA256SUMS"
  [ -d "$check_dir" ] || { fail "Reference directory is missing: $check_dir"; return 1; }
  [ -s "$check_manifest" ] || { fail "Reference manifest is missing or empty: $check_manifest"; return 1; }
  [ -s "$check_fasta" ] || { fail "Reference FASTA is missing or empty: $check_fasta"; return 1; }
  [ -s "$check_gtf" ] || { fail "Reference GTF is missing or empty: $check_gtf"; return 1; }
  [ -s "$check_hashes" ] || { fail "Reference checksums are missing or empty: $check_hashes"; return 1; }

  counts=$(awk -F= '$1=="fasta_size_bytes" { f++ } $1=="gtf_size_bytes" { g++ }
    END { printf "%d %d\n", f, g }' "$check_manifest")
  set -- $counts
  if [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; then
    fail 'Legacy reference manifest has no file sizes; automatic migration is disabled. Remove or migrate it explicitly before reinstalling.'
    return 1
  fi
  [ "$1" -eq 1 ] && [ "$2" -eq 1 ] || {
    fail 'Reference manifest must contain exactly one FASTA size and one GTF size.'
    return 1
  }
  check_assembly=$(value assembly "$check_manifest") || { fail 'Reference manifest assembly entry is missing or duplicated.'; return 1; }
  check_release=$(value ensembl_release "$check_manifest") || { fail 'Reference manifest release entry is missing or duplicated.'; return 1; }
  check_fasta_size=$(value fasta_size_bytes "$check_manifest") || { fail 'Reference manifest FASTA size is missing or duplicated.'; return 1; }
  check_gtf_size=$(value gtf_size_bytes "$check_manifest") || { fail 'Reference manifest GTF size is missing or duplicated.'; return 1; }
  [ "$check_assembly" = GRCh38 ] || { fail 'Reference manifest assembly is not GRCh38.'; return 1; }
  [ "$check_release" = 110 ] || { fail 'Reference manifest release is not Ensembl 110.'; return 1; }
  case "$check_fasta_size:$check_gtf_size" in *[!0-9:]*|:*|*:) fail 'Reference manifest contains invalid file sizes.'; return 1 ;; esac
  [ "$check_fasta_size" -gt 0 ] && [ "$check_gtf_size" -gt 0 ] || { fail 'Reference manifest file sizes must be positive.'; return 1; }
  actual_fasta_size=$(size "$check_fasta")
  actual_gtf_size=$(size "$check_gtf")
  [ "$check_fasta_size" = "$actual_fasta_size" ] || { fail "Reference FASTA size mismatch: expected $check_fasta_size, got $actual_fasta_size."; return 1; }
  [ "$check_gtf_size" = "$actual_gtf_size" ] || { fail "Reference GTF size mismatch: expected $check_gtf_size, got $actual_gtf_size."; return 1; }
  printf 'Verified GRCh38 Ensembl 110 reference sizes: FASTA=%s bytes, GTF=%s bytes.\n' "$actual_fasta_size" "$actual_gtf_size"
}

verify_sum() {
  sum_file=$1
  sum_list=$2
  sum_record=$(awk -v file="$sum_file" '$NF==file { n++; line=$0 }
    END { if (n != 1) exit 1; print line }' "$sum_list") || {
    fail "Expected exactly one BSD sum entry for $sum_file in $sum_list."
    return 1
  }
  set -- $sum_record
  [ "$#" -eq 3 ] || { fail "Invalid BSD sum entry for $sum_file."; return 1; }
  case "$1:$2" in *[!0-9:]*|:*|*:) fail "Invalid BSD sum entry for $sum_file."; return 1 ;; esac
  sum_expected="$1 $2"
  sum_actual=$(sum -r "$sum_file" | awk '{ print $1 " " $2 }')
  [ "$sum_expected" = "$sum_actual" ] || { fail "Ensembl BSD sum mismatch for $sum_file."; return 1; }
}

install_reference() {
  install_dir=$1
  if check_reference "$install_dir"; then
    printf 'Reference already installed and valid: %s\n' "$install_dir"
    return 0
  fi
  if [ -e "$install_dir" ] || [ -L "$install_dir" ]; then
    fail "Reference already exists but is invalid; refusing to replace it: $install_dir"
    return 1
  fi
  install_root=$(dirname "$install_dir")
  mkdir -p "$install_root"
  install_tmp=$(mktemp -d "$install_root/.reference-install.XXXXXX")
  cleanup() { rm -rf "$install_tmp"; }
  trap cleanup 0
  trap 'exit 1' HUP INT TERM

  fasta_name=Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz
  gtf_name=Homo_sapiens.GRCh38.110.gtf.gz
  fasta_base=https://ftp.ensembl.org/pub/release-110/fasta/homo_sapiens/dna
  gtf_base=https://ftp.ensembl.org/pub/release-110/gtf/homo_sapiens
  curl -fsSL --retry 5 --retry-all-errors -o "$install_tmp/fasta.CHECKSUMS" "$fasta_base/CHECKSUMS"
  curl -fsSL --retry 5 --retry-all-errors -o "$install_tmp/gtf.CHECKSUMS" "$gtf_base/CHECKSUMS"
  curl -fsSL --retry 5 --retry-all-errors -o "$install_tmp/$fasta_name" "$fasta_base/$fasta_name"
  curl -fsSL --retry 5 --retry-all-errors -o "$install_tmp/$gtf_name" "$gtf_base/$gtf_name"
  (
    cd "$install_tmp"
    verify_sum "$fasta_name" fasta.CHECKSUMS
    verify_sum "$gtf_name" gtf.CHECKSUMS
    gzip -t "$fasta_name" "$gtf_name"
    gzip -dc "$fasta_name" > genome.fa
    gzip -dc "$gtf_name" > genes.gtf
  )
  [ -s "$install_tmp/genome.fa" ] || { fail 'Downloaded FASTA is empty after decompression.'; return 1; }
  [ -s "$install_tmp/genes.gtf" ] || { fail 'Downloaded GTF is empty after decompression.'; return 1; }
  chmod 0644 "$install_tmp/genome.fa" "$install_tmp/genes.gtf"
  (cd "$install_tmp" && sha256sum genome.fa genes.gtf > SHA256SUMS)
  install_fasta_size=$(size "$install_tmp/genome.fa")
  install_gtf_size=$(size "$install_tmp/genes.gtf")
  install_fasta_hash=$(awk '$2=="genome.fa" {print $1; found=1; exit} END {if (!found) exit 1}' "$install_tmp/SHA256SUMS")
  install_gtf_hash=$(awk '$2=="genes.gtf" {print $1; found=1; exit} END {if (!found) exit 1}' "$install_tmp/SHA256SUMS")
  cat > "$install_tmp/reference.manifest" <<EOF
assembly=GRCh38
ensembl_release=110
fasta_source=$fasta_base/$fasta_name
gtf_source=$gtf_base/$gtf_name
fasta_sha256=$install_fasta_hash
gtf_sha256=$install_gtf_hash
fasta_size_bytes=$install_fasta_size
gtf_size_bytes=$install_gtf_size
EOF
  chmod 0644 "$install_tmp/SHA256SUMS" "$install_tmp/reference.manifest"
  check_reference "$install_tmp"
  mv -Tn "$install_tmp" "$install_dir"
  [ ! -e "$install_tmp" ] || {
    if check_reference "$install_dir" >/dev/null 2>&1; then
      printf 'Reference installed by another process and verified: %s\n' "$install_dir"
      return 0
    fi
    fail "Reference appeared during installation and is invalid; refusing to replace it: $install_dir"
    return 1
  }
  trap - 0 HUP INT TERM
  printf 'Installed verified GRCh38 Ensembl release 110 reference at %s.\n' "$install_dir"
}

mode=
[ "$#" -eq 0 ] || mode=$1
case "$mode" in install|check) ;; *) echo 'Usage: reference.sh install|check [reference-directory]' >&2; exit 2 ;; esac
shift
[ "$#" -le 1 ] || { echo 'Usage: reference.sh install|check [reference-directory]' >&2; exit 2; }
reference_dir=/data/reference/GRCh38/Ensembl-110
[ "$#" -eq 0 ] || reference_dir=$1
case "$mode" in check) check_reference "$reference_dir" ;; install) install_reference "$reference_dir" ;; esac
