#!/usr/bin/env bash
# Submit one stable run-scoped Nextflow Job to Kapsule.
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/run-pipeline.sh <run-id> [--input s3://bucket/samplesheet.csv]
       [--outdir s3://bucket/prefix] [--resume] [-- nf-core args...]

Default input:  s3://<input bucket>/validation/<run-id>/samplesheet.csv
Default output: s3://<results bucket>/runs/<run-id>
Use --resume to reuse the same run's Nextflow cache after a failed/incomplete run.
USAGE
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
RUN_ID="$1"
shift
validate_run_id "$RUN_ID"

INPUT_URI=""
OUTPUT_URI=""
RESUME=0
declare -a EXTRA_ARGS=()
while (($#)); do
  case "$1" in
    --input|--samplesheet)
      (($# >= 2)) || fail "$1 requires an S3 URI."
      INPUT_URI="$2"
      shift 2
      ;;
    --outdir)
      (($# >= 2)) || fail "--outdir requires an S3 URI."
      OUTPUT_URI="$2"
      shift 2
      ;;
    --resume)
      RESUME=1
      shift
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1 (use -- before extra nf-core parameters)."
      ;;
  esac
done

for arg in "${EXTRA_ARGS[@]}"; do
  [[ "$arg" != --input && "$arg" != --outdir ]] || fail "Set input/output with this script's --input and --outdir options."
done
require_commands aws terraform kubectl jq
load_bucket_outputs
require_kubernetes_platform

INPUT_URI="${INPUT_URI:-$(s3_input_uri "$RUN_ID")}"
OUTPUT_URI="${OUTPUT_URI:-$(s3_output_uri "$RUN_ID")}"
[[ "$INPUT_URI" == s3://* ]] || fail "Input must be an S3 URI."
[[ "$OUTPUT_URI" == s3://* ]] || fail "Output must be an S3 URI."

if (( RESUME )); then
  load_pipeline_s3_credentials
  if [[ "$INPUT_URI" == "$(s3_input_uri "$RUN_ID")" ]]; then
    for object in samplesheet.csv SRR1039508_1.fastq.gz SRR1039508_2.fastq.gz; do
      aws_pipeline s3api head-object --bucket "$INPUT_BUCKET" \
        --key "validation/${RUN_ID}/${object}" >/dev/null 2>&1 \
        || fail "Cannot resume ${RUN_ID}: prepared input object ${object} is missing or inaccessible. Run make prepare-demo RUN_ID=${RUN_ID} first."
    done
  elif [[ "$INPUT_URI" =~ ^s3://([^/]+)/(.+)$ ]]; then
    input_bucket="${BASH_REMATCH[1]}"
    input_key="${BASH_REMATCH[2]}"
    aws_pipeline s3api head-object --bucket "$input_bucket" --key "$input_key" >/dev/null 2>&1 \
      || fail "Cannot resume ${RUN_ID}: input samplesheet is missing or inaccessible: ${INPUT_URI}."
  else
    fail "Resume input must be an S3 object URI with a bucket and key: ${INPUT_URI}."
  fi
fi

JOB_TIMEOUT_SECONDS="${NEXTFLOW_JOB_TIMEOUT_SECONDS:-86400}"
[[ "$JOB_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "NEXTFLOW_JOB_TIMEOUT_SECONDS must be a positive integer."
JOB="nextflow-${RUN_ID}"
CONFIGMAP="${JOB}-config"
PROFILES="scaleway_kapsule"

if kubectl get job "$JOB" -n "$NS" >/dev/null 2>&1; then
  old_job="$(kubectl get job "$JOB" -n "$NS" -o json)"
  active="$(jq -r '.status.active // 0' <<<"$old_job")"
  complete="$(jq -r '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length' <<<"$old_job")"
  failed="$(jq -r '[.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length' <<<"$old_job")"
  if (( active > 0 )); then
    fail "Job ${JOB} is already running. Follow it with: kubectl logs -n ${NS} -f job/${JOB}"
  elif (( complete == 0 && failed == 0 )); then
    fail "Job ${JOB} exists but is not terminal; inspect it before retrying."
  else
    kubectl delete job "$JOB" -n "$NS" --wait=true >/dev/null
  fi
fi

kubectl create configmap "$CONFIGMAP" -n "$NS" \
  --from-file=nextflow.config="${REPO_ROOT}/nextflow/nextflow.config" \
  --from-file=params.yaml="${REPO_ROOT}/nextflow/params.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

nf_args=(
  -c /config/nextflow.config
  run "$PIPELINE"
  -r "$NF_VERSION"
  -profile "$PROFILES"
  -params-file /config/params.yaml
  --input "$INPUT_URI"
  --outdir "$OUTPUT_URI"
  -with-report "/data/workdir/report-${RUN_ID}.html"
  -with-timeline "/data/workdir/timeline-${RUN_ID}.html"
  -with-trace "/data/workdir/trace-${RUN_ID}.txt"
)
if (( RESUME )); then
  nf_args+=(-resume)
fi
nf_args+=("${EXTRA_ARGS[@]}")
args_json="$(jq -cn --args '$ARGS.positional' -- "${nf_args[@]}")"

kubectl create job "$JOB" -n "$NS" --image="$NEXTFLOW_IMAGE" --dry-run=client -o json \
  | jq --argjson args "$args_json" --argjson timeout "$JOB_TIMEOUT_SECONDS" --arg configmap "$CONFIGMAP" --arg region "$S3_REGION" '
      .spec.backoffLimit = 0 |
      .spec.ttlSecondsAfterFinished = 86400 |
      .spec.activeDeadlineSeconds = $timeout |
      .spec.template.spec.serviceAccountName = "nextflow" |
      .spec.template.spec.automountServiceAccountToken = true |
      .spec.template.spec.nodeSelector = {"k8s.scaleway.com/pool-name": "star-compute"} |
      .spec.template.spec.containers[0].command = ["nextflow"] |
      .spec.template.spec.containers[0].args = $args |
      .spec.template.spec.containers[0].workingDir = "/data/workdir" |
      .spec.template.spec.containers[0].resources = {
        requests: {cpu: "500m", memory: "1Gi"},
        limits: {cpu: "2", memory: "4Gi"}
      } |
      .spec.template.spec.containers[0].env = [
        {name: "AWS_ACCESS_KEY_ID", valueFrom: {secretKeyRef: {name: "pipeline-s3-credentials", key: "access-key"}}},
        {name: "AWS_SECRET_ACCESS_KEY", valueFrom: {secretKeyRef: {name: "pipeline-s3-credentials", key: "secret-key"}}},
        {name: "AWS_ENDPOINT_URL_S3", valueFrom: {secretKeyRef: {name: "pipeline-s3-credentials", key: "s3-endpoint"}}},
        {name: "AWS_DEFAULT_REGION", value: $region},
        {name: "NXF_HOME", value: "/data/workdir/.nextflow"},
        {name: "NXF_ANSI_LOG", value: "false"}
      ] |
      .spec.template.spec.containers[0].volumeMounts = [
        {name: "workdir", mountPath: "/data/workdir"},
        {name: "reference", mountPath: "/data/reference", readOnly: true},
        {name: "config", mountPath: "/config", readOnly: true}
      ] |
      .spec.template.spec.volumes = [
        {name: "workdir", persistentVolumeClaim: {claimName: "nf-workdir-pvc"}},
        {name: "reference", persistentVolumeClaim: {claimName: "nf-reference-pvc", readOnly: true}},
        {name: "config", configMap: {name: $configmap}}
      ] |
      .spec.template.spec.tolerations = [
        {key: "workload", value: "star-compute", operator: "Equal", effect: "NoSchedule"}
      ]' \
  | kubectl apply -f - >/dev/null

printf 'Nextflow Job: %s\n' "$JOB"
printf 'Cluster ID: %s\nNamespace: %s\nPipeline: %s @ %s\n' "$CLUSTER_ID" "$NS" "$PIPELINE" "$NF_VERSION"
printf 'Input: %s\nOutput: %s\nResume: %s\n' "$INPUT_URI" "$OUTPUT_URI" "$([[ $RESUME == 1 ]] && printf yes || printf no)"
printf 'Follow logs: kubectl logs -n %s -f job/%s\n' "$NS" "$JOB"
(kubectl logs -n "$NS" -f "job/${JOB}" --pod-running-timeout="${JOB_TIMEOUT_SECONDS}s" || true) &
LOG_PID=$!

for ((elapsed=0; elapsed<JOB_TIMEOUT_SECONDS; elapsed+=10)); do
  job_state="$(kubectl get job "$JOB" -n "$NS" -o json)"
  succeeded="$(jq -r '.status.succeeded // 0' <<<"$job_state")"
  failed="$(jq -r '.status.failed // 0' <<<"$job_state")"
  complete="$(jq -r '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length' <<<"$job_state")"
  failure_condition="$(jq -r '[.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length' <<<"$job_state")"
  if [[ "$succeeded" == "1" || "$complete" == "1" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
    wait "$LOG_PID" 2>/dev/null || true
    kubectl delete configmap "$CONFIGMAP" -n "$NS" --ignore-not-found >/dev/null
    printf 'Nextflow pipeline completed: %s\n' "$OUTPUT_URI"
    exit 0
  fi
  if (( failed > 0 || failure_condition > 0 )); then
    break
  fi
  sleep 10
done

kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true
kubectl logs -n "$NS" "job/${JOB}" >&2 || true
kubectl describe job "$JOB" -n "$NS" >&2 || true
fail "Nextflow Job ${JOB} did not complete successfully or exceeded ${JOB_TIMEOUT_SECONDS}s. The Job and ConfigMap are retained for diagnosis and --resume."
