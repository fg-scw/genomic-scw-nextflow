#!/usr/bin/env bash
# Check that the human validation run produced usable RNA-seq outputs.
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  printf 'Usage: scripts/validate-run.sh <run-id>\n' >&2
}

[[ $# -eq 1 ]] || { usage; exit 2; }
RUN_ID="$1"
validate_run_id "$RUN_ID"
require_commands aws terraform kubectl jq awk grep wc tr
load_bucket_outputs
load_pipeline_s3_credentials
require_kubernetes_platform

JOB="nextflow-${RUN_ID}"
if job="$(kubectl get job "$JOB" -n "$NS" -o json 2>/dev/null)"; then
  succeeded="$(jq -r '.status.succeeded // 0' <<<"$job")"
  complete="$(jq -r '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length' <<<"$job")"
  [[ "$succeeded" == "1" || "$complete" == "1" ]] || fail "Nextflow Job ${JOB} has not completed successfully."
else
  printf 'Job %s is no longer retained; validating persisted S3 outputs.\n' "$JOB"
fi

PREFIX="runs/${RUN_ID}"
OUTDIR="$(s3_output_uri "$RUN_ID")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
keys="$(aws_pipeline s3api list-objects-v2 --bucket "$RESULTS_BUCKET" --prefix "${PREFIX}/" --query 'Contents[].Key' --output text)"
[[ -n "$keys" && "$keys" != "None" ]] || fail "No result objects found under ${OUTDIR}."

multiqc_key="${PREFIX}/multiqc/star_salmon/multiqc_report.html"
aws_pipeline s3api head-object --bucket "$RESULTS_BUCKET" --key "$multiqc_key" >/dev/null \
  || fail "MultiQC report is missing: s3://${RESULTS_BUCKET}/${multiqc_key}"
aws_pipeline s3 cp "s3://${RESULTS_BUCKET}/${multiqc_key}" "${TMP_DIR}/multiqc_report.html" --only-show-errors
[[ -s "${TMP_DIR}/multiqc_report.html" ]] || fail "MultiQC report is empty."
grep -Fq 'SRR1039508' "${TMP_DIR}/multiqc_report.html" || fail "MultiQC report does not contain expected sample SRR1039508."

star_log_key="$(tr '\t' '\n' <<<"$keys" | awk '/\/star_salmon\/log\/SRR1039508.*Log\.final\.out$/ {print; exit}')"
[[ -n "$star_log_key" ]] || fail "STAR final alignment log is missing for the demo sample."
aws_pipeline s3 cp "s3://${RESULTS_BUCKET}/${star_log_key}" "${TMP_DIR}/Log.final.out" --only-show-errors
input_reads="$(awk -F '|' '/Number of input reads/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "${TMP_DIR}/Log.final.out")"
mapped_pct="$(awk -F '|' '/Uniquely mapped reads %/ {gsub(/[[:space:]%]/, "", $2); print $2; exit}' "${TMP_DIR}/Log.final.out")"
[[ "${input_reads:-0}" =~ ^[0-9]+$ ]] && (( input_reads >= 45000 )) \
  || fail "STAR reported fewer than 45,000 input reads after trimming; expected at least 90% retention from the 50,000-pair demo subset."
awk -v pct="${mapped_pct:-0}" 'BEGIN {exit !(pct + 0 >= 5)}' \
  || fail "STAR unique mapping rate is below 5%; expected human GRCh38 reads."

bam_key="$(tr '\t' '\n' <<<"$keys" | awk -F/ '$NF ~ /SRR1039508.*[.]bam$/ && $(NF-1) == "star_salmon" {print; exit}')"
[[ -n "$bam_key" ]] || fail "No saved STAR BAM found; the validation run must include --save_align_intermeds true."
bam_size="$(aws_pipeline s3api head-object --bucket "$RESULTS_BUCKET" --key "$bam_key" --query ContentLength --output text)"
[[ "$bam_size" =~ ^[0-9]+$ ]] && (( bam_size > 0 )) || fail "The STAR BAM is empty."

quant_key="${PREFIX}/star_salmon/SRR1039508/quant.sf"
aws_pipeline s3 cp "s3://${RESULTS_BUCKET}/${quant_key}" "${TMP_DIR}/quant.sf" --only-show-errors \
  || fail "Salmon quantification is missing: s3://${RESULTS_BUCKET}/${quant_key}"
quant_rows="$(awk 'NR > 1 && $5 > 0 {n++} END {print n+0}' "${TMP_DIR}/quant.sf")"
(( quant_rows > 0 )) || fail "Salmon quant.sf contains no quantified transcript rows."

counts_key="$(tr '\t' '\n' <<<"$keys" | awk '/\/star_salmon\/featurecounts\/SRR1039508.*featureCounts\.txt$/ {print; exit}')"
[[ -n "$counts_key" ]] || fail "featureCounts output is missing for the demo sample."
aws_pipeline s3 cp "s3://${RESULTS_BUCKET}/${counts_key}" "${TMP_DIR}/featureCounts.txt" --only-show-errors
count_rows="$(awk 'NR > 2 && $NF ~ /^[0-9]+$/ && $NF > 0 {n++} END {print n+0}' "${TMP_DIR}/featureCounts.txt")"
(( count_rows > 0 )) || fail "featureCounts output has no non-zero gene counts."

printf 'Validated run %s at %s\n' "$RUN_ID" "$OUTDIR"
printf '  Nextflow Job: complete\n  Sample: SRR1039508 (50,000 raw read pairs)\n  STAR input reads after trimming: %s\n  STAR uniquely mapped: %s%%\n  Non-empty BAM: %s bytes\n  Quantified transcripts: %s\n  Non-zero gene counts: %s\n  MultiQC report: s3://%s/%s\n' \
  "$input_reads" "$mapped_pct" "$bam_size" "$quant_rows" "$count_rows" "$RESULTS_BUCKET" "$multiqc_key"
