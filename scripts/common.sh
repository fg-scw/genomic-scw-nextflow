#!/usr/bin/env bash
# Shared checks and paths for the Nextflow deployment scripts.

{ set +x; } 2>/dev/null || true
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_INFRA="${REPO_ROOT}/terraform/infra"
NS="${NEXTFLOW_NAMESPACE:-bioinformatics}"
NF_VERSION="3.14.0"
NEXTFLOW_VERSION="25.10.4"
NEXTFLOW_IMAGE="${NEXTFLOW_IMAGE:-nextflow/nextflow:${NEXTFLOW_VERSION}}"
PIPELINE="nf-core/rnaseq"
S3_REGION="${SCW_REGION:-}"
S3_ENDPOINT="${SCW_S3_ENDPOINT:-}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: ${cmd}"
  done
}

validate_run_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || fail "Run ID must be 1-40 lowercase letters, digits or hyphens, starting with a letter or digit."
}

load_bucket_outputs() {
  [[ -d "$TF_INFRA" ]] || fail "Terraform infra directory is missing: ${TF_INFRA}"
  INPUT_BUCKET="$(terraform -chdir="$TF_INFRA" output -raw input_bucket_name 2>/dev/null)" || fail "Terraform output input_bucket_name is unavailable; apply infra first."
  RESULTS_BUCKET="$(terraform -chdir="$TF_INFRA" output -raw results_bucket_name 2>/dev/null)" || fail "Terraform output results_bucket_name is unavailable; apply infra first."
  INFRA_REGION="$(terraform -chdir="$TF_INFRA" output -raw region 2>/dev/null)" || fail "Terraform output region is unavailable; apply infra first."
  S3_REGION="${SCW_REGION:-$INFRA_REGION}"
  S3_ENDPOINT="${SCW_S3_ENDPOINT:-https://s3.${S3_REGION}.scw.cloud}"
  CLUSTER_ID="$(terraform -chdir="$TF_INFRA" output -raw cluster_id 2>/dev/null)" || fail "Terraform output cluster_id is unavailable; apply infra first."
  [[ -n "$INPUT_BUCKET" && -n "$RESULTS_BUCKET" && -n "$CLUSTER_ID" && -n "$S3_REGION" && -n "$S3_ENDPOINT" ]] || fail "Terraform returned an empty required output."
}

load_pipeline_s3_credentials() {
  if [[ -n "${PIPELINE_S3_ACCESS_KEY:-}" && -n "${PIPELINE_S3_SECRET_KEY:-}" ]]; then
    return 0
  fi
  if [[ -n "${PIPELINE_S3_ACCESS_KEY:-}" || -n "${PIPELINE_S3_SECRET_KEY:-}" ]]; then
    fail "Set both PIPELINE_S3_ACCESS_KEY and PIPELINE_S3_SECRET_KEY, or unset both to read them from Secret Manager."
  fi

  require_commands scw jq terraform
  local secret_id revision payload
  secret_id="$(terraform -chdir="$TF_INFRA" output -raw pipeline_credentials_secret_id 2>/dev/null)" \
    || fail "Terraform output pipeline_credentials_secret_id is unavailable."
  revision="$(terraform -chdir="$TF_INFRA" output -raw pipeline_credentials_revision 2>/dev/null)" \
    || fail "Terraform output pipeline_credentials_revision is unavailable."
  payload="$(scw secret version access "$secret_id" revision="$revision" region="$S3_REGION" raw=true 2>/dev/null)" \
    || fail "Could not read the pipeline S3 credentials from Scaleway Secret Manager."
  PIPELINE_S3_ACCESS_KEY="$(jq -er '.access_key | select(type == "string" and length > 0)' <<<"$payload")" \
    || fail "Secret Manager payload is missing access_key."
  PIPELINE_S3_SECRET_KEY="$(jq -er '.secret_key | select(type == "string" and length > 0)' <<<"$payload")" \
    || fail "Secret Manager payload is missing secret_key."
  unset payload
}

aws_pipeline() {
  AWS_ACCESS_KEY_ID="$PIPELINE_S3_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$PIPELINE_S3_SECRET_KEY" \
  AWS_DEFAULT_REGION="$S3_REGION" \
  AWS_EC2_METADATA_DISABLED=true \
    aws --endpoint-url "$S3_ENDPOINT" "$@"
}

require_kubernetes_base() {
  require_commands kubectl jq
  kubectl cluster-info >/dev/null 2>&1 || fail "kubectl cannot reach a cluster; configure KUBECONFIG/context first."
  server_version="$(kubectl version -o json | jq -r '.serverVersion.gitVersion // empty')"
  [[ "$server_version" == v1.37.* ]] || fail "Expected Kubernetes 1.37, connected server is ${server_version:-unknown}."
  kubectl get namespace "$NS" >/dev/null 2>&1 || fail "Namespace ${NS} is missing; deploy the Kubernetes platform first."
  kubectl get pvc nf-workdir-pvc nf-reference-pvc -n "$NS" >/dev/null 2>&1 || fail "The Nextflow work/reference PVCs are missing; deploy the Kubernetes platform first."
  kubectl get serviceaccount nextflow -n "$NS" >/dev/null 2>&1 || fail "ServiceAccount nextflow is missing in namespace ${NS}."
}

require_kubernetes_platform() {
  require_kubernetes_base
  kubectl get secret pipeline-s3-credentials -n "$NS" -o json \
    | jq -e '.data | has("access-key") and has("secret-key") and has("s3-endpoint")' >/dev/null \
    || fail "Secret pipeline-s3-credentials is missing one or more required keys."
}

s3_input_uri() {
  printf 's3://%s/validation/%s/samplesheet.csv' "$INPUT_BUCKET" "$1"
}

s3_output_uri() {
  printf 's3://%s/runs/%s' "$RESULTS_BUCKET" "$1"
}
