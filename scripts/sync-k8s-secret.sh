#!/usr/bin/env bash
{ set +x; } 2>/dev/null || true
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
infra_dir="$repo_root/terraform/infra"
namespace="${NEXTFLOW_NAMESPACE:-bioinformatics}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for command_name in kubectl jq terraform scw; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: $command_name"
done
[[ -d "$infra_dir" ]] || fail "Terraform infra directory is missing: $infra_dir"

kubectl cluster-info >/dev/null 2>&1 || fail 'kubectl cannot reach a cluster; configure KUBECONFIG/context first.'
server_version="$(kubectl version -o json | jq -r '.serverVersion.gitVersion // empty')"
[[ "$server_version" == v1.37.* ]] || fail "Expected Kubernetes 1.37, connected server is ${server_version:-unknown}."
kubectl get namespace "$namespace" >/dev/null 2>&1 || fail "Namespace $namespace is missing; deploy the Kubernetes platform first."
kubectl get pvc nf-workdir-pvc nf-reference-pvc -n "$namespace" >/dev/null 2>&1 \
  || fail 'The Nextflow work/reference PVCs are missing; deploy the Kubernetes platform first.'
kubectl get serviceaccount nextflow -n "$namespace" >/dev/null 2>&1 \
  || fail "ServiceAccount nextflow is missing in namespace $namespace."

terraform_outputs="$(terraform -chdir="$infra_dir" output -json)" \
  || fail 'Terraform outputs are unavailable; apply infra first.'
output_region="$(jq -er '.region.value | select(type == "string" and length > 0)' <<<"$terraform_outputs")" \
  || fail 'Terraform output region is unavailable.'
secret_id="$(jq -er '.pipeline_credentials_secret_id.value | select(type == "string" and length > 0)' <<<"$terraform_outputs")" \
  || fail 'Terraform output pipeline_credentials_secret_id is unavailable.'
revision="$(jq -er '
  .pipeline_credentials_revision.value |
  if (type == "number" and . > 0 and floor == .) or (type == "string" and test("^[1-9][0-9]*$"))
  then tostring else empty end
' <<<"$terraform_outputs")" || fail 'Terraform output pipeline_credentials_revision is invalid.'
unset terraform_outputs

secret_id="${secret_id##*/}"
[[ "$secret_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] \
  || fail 'Terraform pipeline_credentials_secret_id must be a UUID or region/UUID.'
region="${SCW_REGION:-$output_region}"
[[ -n "$region" ]] || fail 'Terraform returned an empty region.'
payload="$(scw secret version access "$secret_id" revision="$revision" region="$region" raw=true 2>/dev/null)" \
  || fail 'Could not read pipeline S3 credentials from Scaleway Secret Manager.'

umask 077
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
chmod 0700 "$tmp_dir"
jq -erj '.access_key | select(type == "string" and length > 0)' <<<"$payload" > "$tmp_dir/access-key" \
  || fail 'Secret Manager payload is missing access_key.'
jq -erj '.secret_key | select(type == "string" and length > 0)' <<<"$payload" > "$tmp_dir/secret-key" \
  || fail 'Secret Manager payload is missing secret_key.'
jq -erj '.s3_endpoint | select(type == "string" and startswith("https://") and length > 8)' <<<"$payload" > "$tmp_dir/s3-endpoint" \
  || fail 'Secret Manager payload is missing a valid s3_endpoint.'
unset payload
chmod 0600 "$tmp_dir/access-key" "$tmp_dir/secret-key" "$tmp_dir/s3-endpoint"
for credential_file in "$tmp_dir/access-key" "$tmp_dir/secret-key" "$tmp_dir/s3-endpoint"; do
  [[ -s "$credential_file" ]] || fail 'A synchronized credential file is empty.'
  mode="$(stat -c '%a' "$credential_file" 2>/dev/null || stat -f '%Lp' "$credential_file" 2>/dev/null)" \
    || fail 'Could not verify permissions on a temporary credential file.'
  [[ "$mode" == 600 ]] || fail 'Temporary credential file permissions are not 0600.'
done

kubectl create secret generic pipeline-s3-credentials -n "$namespace" \
  --from-file=access-key="$tmp_dir/access-key" \
  --from-file=secret-key="$tmp_dir/secret-key" \
  --from-file=s3-endpoint="$tmp_dir/s3-endpoint" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

printf 'Synchronized pipeline Object Storage credentials into Secret pipeline-s3-credentials in namespace %s.\n' "$namespace"
