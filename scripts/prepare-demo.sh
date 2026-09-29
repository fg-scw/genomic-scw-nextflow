#!/usr/bin/env bash
# Upload a deterministic 50,000-pair human RNA-seq subset and samplesheet.
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/prepare-demo.sh <run-id> [sample-count]

Downloads SRR1039508 (human airway smooth-muscle RNA-seq), keeps the first
50,000 paired reads from each FASTQ, and uploads immutable run-scoped inputs.
With sample-count > 1, repeats the reads under distinct sample names to create
a scheduling/load test; this is not synthetic biological data.
USAGE
}

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
RUN_ID="$1"
SAMPLE_COUNT="${2:-1}"
validate_run_id "$RUN_ID"
[[ "$SAMPLE_COUNT" =~ ^[1-9][0-9]*$ ]] && (( SAMPLE_COUNT <= 100 )) \
  || fail "Sample count must be an integer between 1 and 100."
require_commands curl gzip awk wc aws terraform
load_bucket_outputs
load_pipeline_s3_credentials

INPUT_PREFIX="validation/${RUN_ID}"
INPUT_URI="s3://${INPUT_BUCKET}/${INPUT_PREFIX}/samplesheet.csv"
existing="$(aws_pipeline s3api list-objects-v2 --bucket "$INPUT_BUCKET" --prefix "${INPUT_PREFIX}/" --max-keys 1 --query 'KeyCount' --output text)"
[[ "$existing" == "0" || "$existing" == "None" ]] || fail "Input prefix already contains objects; use a new run ID to keep inputs immutable."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FASTQ_BASE="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/008/SRR1039508"
READ_LINES=200000

printf 'Preparing human demo data SRR1039508 (GRCh38-compatible), run %s.\n' "$RUN_ID"
for mate in 1 2; do
  source_file="SRR1039508_${mate}.fastq.gz"
  subset_file="${TMP_DIR}/${source_file}"
  curl_log="${TMP_DIR}/curl-mate-${mate}.log"
  gzip_log="${TMP_DIR}/gzip-mate-${mate}.log"
  fastq_log="${TMP_DIR}/fastq-mate-${mate}.log"
  printf 'Streaming mate %s and keeping the first 50,000 FASTQ records...\n' "$mate"

  # The AWK validator stops as soon as it has consumed exactly 50,000 complete
  # records. That intentionally closes the HTTP/decompression pipes; collect
  # each status so only curl's resulting write error and gzip's SIGPIPE (or
  # explicit Broken pipe diagnostic) are allowed after the full subset validates.
  set +e
  curl --fail --location --retry 5 --silent --show-error --output - \
    "${FASTQ_BASE}/${source_file}" 2>"$curl_log" \
    | gzip -dc 2>"$gzip_log" \
    | awk -v target_lines="$READ_LINES" '
        NR % 4 == 1 && substr($0, 1, 1) != "@" {
          printf "Invalid FASTQ header at line %d.\n", NR > "/dev/stderr"
          exit 1
        }
        NR % 4 == 2 {
          sequence_length = length($0)
          if (sequence_length == 0) {
            printf "Empty FASTQ sequence at line %d.\n", NR > "/dev/stderr"
            exit 1
          }
        }
        NR % 4 == 3 && substr($0, 1, 1) != "+" {
          printf "Invalid FASTQ separator at line %d.\n", NR > "/dev/stderr"
          exit 1
        }
        NR % 4 == 0 && length($0) != sequence_length {
          printf "Sequence/quality length mismatch at record %d.\n", NR / 4 > "/dev/stderr"
          exit 1
        }
        {
          print
          if (NR == target_lines) exit
        }
        END {
          if (NR != target_lines) {
            printf "Expected %d FASTQ lines; received %d.\n", target_lines, NR > "/dev/stderr"
            exit 1
          }
        }
      ' 2>"$fastq_log" \
    | gzip -n > "$subset_file"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  curl_status="${pipeline_status[0]}"
  source_gzip_status="${pipeline_status[1]}"
  fastq_status="${pipeline_status[2]}"
  output_gzip_status="${pipeline_status[3]}"

  if (( fastq_status != 0 || output_gzip_status != 0 )); then
    cat "$fastq_log" "$gzip_log" "$curl_log" >&2
    fail "Could not create a valid 50,000-record FASTQ subset for mate ${mate}."
  fi
  if (( curl_status != 0 && curl_status != 23 )); then
    cat "$curl_log" >&2
    fail "FASTQ source transfer failed for mate ${mate} (curl exit ${curl_status})."
  fi
  if (( source_gzip_status != 0 && source_gzip_status != 141 )); then
    gzip_diagnostic="$(cat "$gzip_log")"
    case "$gzip_diagnostic" in
      *"Broken pipe"*|*"broken pipe"*) ;;
      *)
        cat "$gzip_log" >&2
        fail "FASTQ source decompression failed for mate ${mate} (gzip exit ${source_gzip_status})."
        ;;
    esac
  fi

  lines="$(gzip -dc "$subset_file" | wc -l | tr -d '[:space:]')"
  [[ "$lines" -eq "$READ_LINES" ]] || fail "Expected 50,000 complete FASTQ records in mate ${mate}; got $((lines / 4))."
  gzip -t "$subset_file"
done

sample_sheet="${TMP_DIR}/samplesheet.csv"
cat > "$sample_sheet" <<EOF_SAMPLES
sample,fastq_1,fastq_2,strandedness
EOF_SAMPLES
for ((sample=1; sample<=SAMPLE_COUNT; sample++)); do
  if (( sample == 1 )); then
    sample_name="SRR1039508"
  else
    printf -v sample_name 'load_%03d' "$sample"
  fi
  printf '%s,s3://%s/%s/SRR1039508_1.fastq.gz,s3://%s/%s/SRR1039508_2.fastq.gz,unstranded\n' \
    "$sample_name" "$INPUT_BUCKET" "$INPUT_PREFIX" "$INPUT_BUCKET" "$INPUT_PREFIX" >> "$sample_sheet"
done

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
samples=$SAMPLE_COUNT
sample_data=SRR1039508 reused for each sample (load test only)
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
