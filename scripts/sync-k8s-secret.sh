#!/usr/bin/env bash
# Synchronize the pipeline's least-privilege Object Storage credentials into K8s.
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_commands scw terraform kubectl jq
load_bucket_outputs
require_kubernetes_base

secret_id="$(terraform -chdir="$TF_INFRA" output -raw pipeline_credentials_secret_id 2>/dev/null)" \
  || fail "Terraform output pipeline_credentials_secret_id is unavailable."
revision="$(terraform -chdir="$TF_INFRA" output -raw pipeline_credentials_revision 2>/dev/null)" \
  || fail "Terraform output pipeline_credentials_revision is unavailable."
payload="$(scw secret version access "$secret_id" revision="$revision" region="$S3_REGION" raw=true 2>/dev/null)" \
  || fail "Could not read pipeline credentials from Scaleway Secret Manager."

tmp_dir="$(mktemp -d)"
chmod 0700 "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT
umask 077
jq -erj '.access_key | select(type == "string" and length > 0)' <<<"$payload" > "${tmp_dir}/access-key" \
  || fail "Secret Manager payload is missing access_key."
jq -erj '.secret_key | select(type == "string" and length > 0)' <<<"$payload" > "${tmp_dir}/secret-key" \
  || fail "Secret Manager payload is missing secret_key."
jq -erj '.s3_endpoint | select(type == "string" and startswith("https://"))' <<<"$payload" > "${tmp_dir}/s3-endpoint" \
  || fail "Secret Manager payload is missing a valid s3_endpoint."
unset payload
chmod 0600 "${tmp_dir}/access-key" "${tmp_dir}/secret-key" "${tmp_dir}/s3-endpoint"
for credential_file in "${tmp_dir}/access-key" "${tmp_dir}/secret-key" "${tmp_dir}/s3-endpoint"; do
  [[ -s "$credential_file" ]] || fail "A synchronized credential file is empty."
  mode="$(stat -c '%a' "$credential_file" 2>/dev/null || stat -f '%Lp' "$credential_file" 2>/dev/null)" \
    || fail "Could not verify permissions on a temporary credential file."
  [[ "$mode" == 600 ]] || fail "Temporary credential file permissions are not 0600."
done

kubectl create secret generic pipeline-s3-credentials -n "$NS" \
  --from-file=access-key="${tmp_dir}/access-key" \
  --from-file=secret-key="${tmp_dir}/secret-key" \
  --from-file=s3-endpoint="${tmp_dir}/s3-endpoint" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

printf 'Synchronized pipeline Object Storage credentials into Secret pipeline-s3-credentials in namespace %s.\n' "$NS"
