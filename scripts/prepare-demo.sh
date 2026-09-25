#!/usr/bin/env bash
# Upload a deterministic 50,000-pair human RNA-seq subset and samplesheet.
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/prepare-demo.sh <run-id>

Downloads SRR1039508 (human airway smooth-muscle RNA-seq), keeps the first
50,000 paired reads from each FASTQ, and uploads immutable run-scoped inputs.
USAGE
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
RUN_ID="$1"
validate_run_id "$RUN_ID"
require_commands curl gzip awk wc aws terraform
load_bucket_outputs
load_pipeline_s3_credentials

INPUT_PREFIX="validation/${RUN_ID}"
INPUT_URI="s3://${INPUT_BUCKET}/${INPUT_PREFIX}/samplesheet.csv"
existing="$(aws_pipeline s3api list-objects-v2 --bucket "$INPUT_BUCKET" --prefix "${INPUT_PREFIX}/" --max-keys 1 --query 'length(Contents)' --output text)"
[[ "$existing" == "0" || "$existing" == "None" ]] || fail "Input prefix already contains objects; use a new run ID to keep inputs immutable."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FASTQ_BASE="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/008/SRR1039508"
READ_LINES=200000

printf 'Preparing human demo data SRR1039508 (GRCh38-compatible), run %s.\n' "$RUN_ID"
for mate in 1 2; do
  source_file="SRR1039508_${mate}.fastq.gz"
  subset_file="${TMP_DIR}/${source_file}"
  printf 'Downloading and checking mate %s...\n' "$mate"
  curl --fail --location --retry 5 --retry-all-errors --silent --show-error \
    --output "${TMP_DIR}/source-${source_file}" "${FASTQ_BASE}/${source_file}"
  gzip -t "${TMP_DIR}/source-${source_file}"
  # awk consumes the complete stream, so gzip does not receive SIGPIPE when the
  # fixed-size subset ends before the full public accession.
  gzip -dc "${TMP_DIR}/source-${source_file}" \
    | awk -v max_lines="$READ_LINES" 'NR <= max_lines { print }' \
    | gzip -n > "$subset_file"
  lines="$(gzip -dc "$subset_file" | wc -l | tr -d '[:space:]')"
  [[ "$lines" -eq "$READ_LINES" ]] || fail "Expected 50,000 complete FASTQ records in mate ${mate}; got $((lines / 4))."
  gzip -t "$subset_file"
  rm -f "${TMP_DIR}/source-${source_file}"
done

sample_sheet="${TMP_DIR}/samplesheet.csv"
cat > "$sample_sheet" <<EOF_SAMPLES
sample,fastq_1,fastq_2,strandedness
SRR1039508,s3://${INPUT_BUCKET}/${INPUT_PREFIX}/SRR1039508_1.fastq.gz,s3://${INPUT_BUCKET}/${INPUT_PREFIX}/SRR1039508_2.fastq.gz,unstranded
EOF_SAMPLES

if command -v sha256sum >/dev/null 2>&1; then
  FASTQ1_SHA="$(sha256sum "${TMP_DIR}/SRR1039508_1.fastq.gz" | awk '{print $1}')"
  FASTQ2_SHA="$(sha256sum "${TMP_DIR}/SRR1039508_2.fastq.gz" | awk '{print $1}')"
else
  require_commands shasum
  FASTQ1_SHA="$(shasum -a 256 "${TMP_DIR}/SRR1039508_1.fastq.gz" | awk '{print $1}')"
  FASTQ2_SHA="$(shasum -a 256 "${TMP_DIR}/SRR1039508_2.fastq.gz" | awk '{print $1}')"
fi
cat > "${TMP_DIR}/manifest.txt" <<EOF_MANIFEST
run_id=${RUN_ID}
sample=SRR1039508
source=https://www.ebi.ac.uk/ena/browser/view/SRR1039508
organism=Homo sapiens
reference=GRCh38, Ensembl release 110
paired_reads=50000
read_length_source=63bp (ENA run metadata)
fastq_1_sha256=${FASTQ1_SHA}
fastq_2_sha256=${FASTQ2_SHA}
EOF_MANIFEST

printf 'Uploading immutable inputs to s3://%s/%s/\n' "$INPUT_BUCKET" "$INPUT_PREFIX"
for mate in 1 2; do
  aws_pipeline s3 cp "${TMP_DIR}/SRR1039508_${mate}.fastq.gz" \
    "s3://${INPUT_BUCKET}/${INPUT_PREFIX}/SRR1039508_${mate}.fastq.gz" --only-show-errors
done
aws_pipeline s3 cp "$sample_sheet" "$INPUT_URI" --only-show-errors
aws_pipeline s3 cp "${TMP_DIR}/manifest.txt" \
  "s3://${INPUT_BUCKET}/${INPUT_PREFIX}/manifest.txt" --only-show-errors
printf 'Inputs ready: %s\n' "$INPUT_URI"
