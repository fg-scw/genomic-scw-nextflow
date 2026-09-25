#!/usr/bin/env bash
set -euo pipefail

: "${STATE_BUCKET:?Set STATE_BUCKET to the dedicated Terraform state bucket name}"
STATE_REGION="${STATE_REGION:-fr-par}"
S3_ENDPOINT="https://s3.${STATE_REGION}.scw.cloud"

for command in scw aws; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 127
  }
done

if scw object bucket get "$STATE_BUCKET" region="$STATE_REGION" >/dev/null 2>&1; then
  printf 'State bucket already exists: %s\n' "$STATE_BUCKET"
else
  printf 'Creating private, versioned state bucket: %s\n' "$STATE_BUCKET"
  scw object bucket create "$STATE_BUCKET" enable-versioning=true acl=private region="$STATE_REGION"
fi

versioning_status="$(aws --endpoint-url "$S3_ENDPOINT" --region "$STATE_REGION" \
  s3api get-bucket-versioning --bucket "$STATE_BUCKET" --query Status --output text 2>/dev/null || true)"
if [[ "$versioning_status" != "Enabled" ]]; then
  aws --endpoint-url "$S3_ENDPOINT" --region "$STATE_REGION" s3api put-bucket-versioning \
    --bucket "$STATE_BUCKET" \
    --versioning-configuration Status=Enabled
fi

versioning_status="$(aws --endpoint-url "$S3_ENDPOINT" --region "$STATE_REGION" \
  s3api get-bucket-versioning --bucket "$STATE_BUCKET" --query Status --output text)"
[[ "$versioning_status" == "Enabled" ]] || {
  printf 'Versioning is not enabled for state bucket %s\n' "$STATE_BUCKET" >&2
  exit 1
}

printf 'State bucket ready: %s (%s, versioning enabled)\n' "$STATE_BUCKET" "$STATE_REGION"
