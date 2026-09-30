#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/repo"
cp -R "$repo_root/kubernetes/base" "$repo_root/kubernetes/run" "$tmp/repo/"
run="$tmp/repo/run"
cp "$run/run.env.example" "$run/run.env"

kubectl kustomize "$run" > "$tmp/first.yaml"
kubectl kustomize "$run" > "$tmp/repeat.yaml"
configmap_name() {
  awk '/^kind: ConfigMap$/ { configmap=1; next } configmap && /^  name: / { print $2; exit }' "$1"
}
first_name="$(configmap_name "$tmp/first.yaml")"
[[ -n "$first_name" && "$first_name" == "$(configmap_name "$tmp/repeat.yaml")" ]]
grep -Fxq '  name: nextflow-example' "$tmp/first.yaml"
grep -Fq '  RUN_RESUME: "0"' "$tmp/first.yaml"
grep -Fq 'immutable: true' "$tmp/first.yaml"
grep -Fq '        - $(NF_PROFILE)' "$tmp/first.yaml"
grep -Fq '        - $(INPUT)' "$tmp/first.yaml"
grep -Fq '        - $(OUTDIR)' "$tmp/first.yaml"
grep -Fq '        - /data/workdir/report-$(RUN_ID).html' "$tmp/first.yaml"
grep -Fq '        - /config/reference.sh' "$tmp/first.yaml"
grep -Fq '        - /data/reference/GRCh38/Ensembl-110' "$tmp/first.yaml"
grep -Fq '        k8s.scaleway.com/pool-name: star-compute' "$tmp/first.yaml"
grep -Fq '        cluster-autoscaler.kubernetes.io/safe-to-evict: "false"' "$tmp/first.yaml"
grep -Fq '          claimName: nf-reference-pvc' "$tmp/first.yaml"
grep -Fq '          readOnly: true' "$tmp/first.yaml"
grep -Fq "  name: $first_name" "$tmp/first.yaml"
grep -Fq "          name: $first_name" "$tmp/first.yaml"
[[ "$(grep -Fc "$first_name" "$tmp/first.yaml")" == 8 ]]

awk 'substr($0, 1, 7) == "OUTDIR=" { print "OUTDIR=s3://example-bucket/other"; next } { print }' \
  "$run/run.env" > "$tmp/changed.env"
mv "$tmp/changed.env" "$run/run.env"
kubectl kustomize "$run" > "$tmp/changed.yaml"
changed_name="$(configmap_name "$tmp/changed.yaml")"
[[ -n "$changed_name" && "$changed_name" != "$first_name" ]]
grep -Fxq '  name: nextflow-example' "$tmp/changed.yaml"

printf 'Kustomize renders the Job, native args and shared hash; changing run.env changes the ConfigMap hash.\n'
