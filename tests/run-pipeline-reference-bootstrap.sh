#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
touch "$tmp/job"
cat > "$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  cluster-info) ;;
  'version -o json') printf '{"serverVersion":{"gitVersion":"v1.37.4"}}\n' ;;
  'get secret pipeline-s3-credentials -n bioinformatics -o json')
    printf '{"data":{"access-key":"x","secret-key":"x","s3-endpoint":"x"}}\n' ;;
  'get job reference-bootstrap-ensembl-110 -n bioinformatics -o json')
    [[ -e "$TEST_JOB" ]] || exit 1
    if [[ "${TEST_JOB_STATE:-success}" == verify-failed ]]; then
      printf '{"status":{"succeeded":0,"active":0},"metadata":{"labels":{"reference-verify-only":"true"}}}\n'
    else
      printf '{"status":{"succeeded":1,"active":0}}\n'
    fi
    ;;
  'get job reference-bootstrap-ensembl-110 -n bioinformatics') [[ -e "$TEST_JOB" ]] ;;
  create\ configmap\ reference-manifest-check\ -n\ bioinformatics\ --from-file=check-reference.sh=*\ --dry-run=client\ -o\ yaml)
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: reference-manifest-check\n'
    ;;
  delete\ job\ reference-bootstrap-ensembl-110\ *)
    rm -f "$TEST_JOB"
    printf 'delete\n' >> "$TEST_EVENTS"
    ;;
  'apply -f -'|'apply -n bioinformatics -f -')
    manifest="$(cat)"
    if [[ "$manifest" == *'kind: Job'* ]]; then
      printf '%s\n' "$manifest" > "$TEST_MANIFEST"
      touch "$TEST_JOB"
      printf 'apply\n' >> "$TEST_EVENTS"
    fi
    ;;
  wait\ --for=condition=complete\ job/reference-bootstrap-ensembl-110\ *) ;;
  logs\ job/reference-bootstrap-ensembl-110\ *) printf 'Reference contents revalidated.\n' ;;
  'get namespace bioinformatics'|'get pvc nf-workdir-pvc nf-reference-pvc -n bioinformatics'|\
    'get serviceaccount nextflow -n bioinformatics') ;;
  *) printf 'Unexpected kubectl call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/kubectl"

PATH="$tmp/bin:$PATH" TEST_JOB="$tmp/job" TEST_EVENTS="$tmp/events" TEST_MANIFEST="$tmp/job.yaml" \
  bash "$repo_root/scripts/bootstrap-reference.sh" >/dev/null
[[ "$(<"$tmp/events")" == $'delete\napply' ]]
grep -Fq 'value: "true"' "$tmp/job.yaml"
grep -Fq 'reference-verify-only: "true"' "$tmp/job.yaml"
grep -Fq '/opt/reference-check/check-reference.sh "$ref"' "$tmp/job.yaml"
grep -Fq 'Reference data is missing after a previously successful bootstrap.' "$tmp/job.yaml"
PATH="$tmp/bin:$PATH" TEST_JOB="$tmp/job" TEST_EVENTS="$tmp/events" TEST_MANIFEST="$tmp/retry.yaml" \
  TEST_JOB_STATE=verify-failed bash "$repo_root/scripts/bootstrap-reference.sh" >/dev/null
[[ "$(<"$tmp/events")" == $'delete\napply\ndelete\napply' ]]
grep -Fq 'value: "true"' "$tmp/retry.yaml"
printf 'Completed reference Jobs are rerun to verify the PVC contents.\n'
