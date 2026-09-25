#!/usr/bin/env bash
# Download and verify only the pinned GRCh38 FASTA/GTF. nf-core builds its own
# STAR index from these files so STAR_GENOMEGENERATE and STAR_ALIGN stay compatible.
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_kubernetes_platform

JOB="reference-bootstrap-ensembl-110"
if kubectl get job "$JOB" -n "$NS" >/dev/null 2>&1; then
  succeeded="$(kubectl get job "$JOB" -n "$NS" -o json | jq -r '.status.succeeded // 0')"
  active="$(kubectl get job "$JOB" -n "$NS" -o json | jq -r '.status.active // 0')"
  if [[ "$succeeded" == "1" ]]; then
    printf 'Reference bootstrap already completed: GRCh38 Ensembl release 110.\n'
    exit 0
  elif (( active > 0 )); then
    printf 'Waiting for existing reference bootstrap Job %s...\n' "$JOB"
  else
    kubectl delete job "$JOB" -n "$NS" --wait=true >/dev/null
  fi
fi

if ! kubectl get job "$JOB" -n "$NS" >/dev/null 2>&1; then
  kubectl apply -n "$NS" -f - <<'MANIFEST'
apiVersion: batch/v1
kind: Job
metadata:
  name: reference-bootstrap-ensembl-110
  labels:
    app.kubernetes.io/name: nextflow-reference-bootstrap
    app.kubernetes.io/version: "110"
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 21600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nextflow-reference-bootstrap
    spec:
      restartPolicy: Never
      containers:
        - name: download-reference
          image: alpine:3.22.1
          command: ["/bin/sh", "-euc"]
          args:
            - |
              apk add --no-cache curl coreutils
              root=/data/reference/GRCh38
              ref="${root}/Ensembl-110"
              tmp="${root}/.Ensembl-110.tmp-$$"
              fasta_name=Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz
              gtf_name=Homo_sapiens.GRCh38.110.gtf.gz
              fasta_base=https://ftp.ensembl.org/pub/release-110/fasta/homo_sapiens/dna
              gtf_base=https://ftp.ensembl.org/pub/release-110/gtf/homo_sapiens

              if [ -s "${ref}/reference.manifest" ]; then
                cd "$ref"
                sha256sum -c SHA256SUMS
                grep -Fx 'assembly=GRCh38' reference.manifest
                grep -Fx 'ensembl_release=110' reference.manifest
                echo "Verified existing GRCh38 Ensembl-110 reference."
                exit 0
              fi
              if [ -e "$ref" ]; then
                echo "Reference directory exists without a valid manifest: $ref" >&2
                exit 1
              fi

              mkdir -p "$root" "$tmp"
              cd "$tmp"
              curl -fsSL --retry 5 --retry-all-errors -o fasta.CHECKSUMS "${fasta_base}/CHECKSUMS"
              curl -fsSL --retry 5 --retry-all-errors -o gtf.CHECKSUMS "${gtf_base}/CHECKSUMS"
              curl -fsSL --retry 5 --retry-all-errors -o "$fasta_name" "${fasta_base}/${fasta_name}"
              curl -fsSL --retry 5 --retry-all-errors -o "$gtf_name" "${gtf_base}/${gtf_name}"
              verify_checksum() {
                file="$1"
                checksums="$2"
                record="$(awk -v file="$file" '$NF == file {print; exit}' "$checksums")"
                [ -n "$record" ] || { echo "No checksum entry for $file in $checksums" >&2; return 1; }
                # Ensembl CHECKSUMS for classic FASTA/GTF data use Unix `sum`
                # (BSD algorithm: checksum + block count); accept MD5 too so a
                # format change fails closed only when the entry is unknown.
                set -- $record
                if [ "$#" -eq 2 ] && [ "${#1}" -eq 32 ]; then
                  case "$1" in *[!0-9a-fA-F]*) echo "Invalid MD5 checksum for $file" >&2; return 1 ;; esac
                  printf '%s  %s\n' "$1" "$file" | md5sum -c -
                elif [ "$#" -eq 3 ]; then
                  case "$1:$2" in *[!0-9:]*|:*|*:) echo "Invalid Unix sum entry for $file" >&2; return 1 ;; esac
                  expected="$1 $2"
                  actual="$(sum -r "$file" | awk '{print $1 " " $2}')"
                  [ "$actual" = "$expected" ] || { echo "Checksum mismatch for $file (expected $expected, got $actual)" >&2; return 1; }
                  echo "$file: OK (BSD sum)"
                else
                  echo "Unsupported Ensembl checksum entry for $file: $record" >&2
                  return 1
                fi
              }
              verify_checksum "$fasta_name" fasta.CHECKSUMS
              verify_checksum "$gtf_name" gtf.CHECKSUMS
              gzip -t "$fasta_name" "$gtf_name"
              gzip -dc "$fasta_name" > genome.fa
              gzip -dc "$gtf_name" > genes.gtf
              test -s genome.fa && test -s genes.gtf
              chmod 0644 genome.fa genes.gtf
              sha256sum genome.fa genes.gtf > SHA256SUMS
              fasta_sha256="$(awk '$2 == "genome.fa" {print $1; found=1; exit} END {if (!found) exit 1}' SHA256SUMS)"
              gtf_sha256="$(awk '$2 == "genes.gtf" {print $1; found=1; exit} END {if (!found) exit 1}' SHA256SUMS)"
              for digest in "$fasta_sha256" "$gtf_sha256"; do
                [ "${#digest}" -eq 64 ] || { echo "Invalid SHA-256 entry in SHA256SUMS" >&2; exit 1; }
                case "$digest" in *[!0-9a-f]*) echo "Invalid SHA-256 entry in SHA256SUMS" >&2; exit 1 ;; esac
              done
              cat > reference.manifest <<EOF_MANIFEST
              assembly=GRCh38
              ensembl_release=110
              fasta_source=${fasta_base}/${fasta_name}
              gtf_source=${gtf_base}/${gtf_name}
              fasta_sha256=${fasta_sha256}
              gtf_sha256=${gtf_sha256}
              EOF_MANIFEST
              chmod 0644 SHA256SUMS reference.manifest
              cd "$root"
              mv "$tmp" "$ref"
              echo "Installed verified GRCh38 Ensembl release 110 FASTA and GTF."
              cat "${ref}/reference.manifest"
          volumeMounts:
            - name: reference
              mountPath: /data/reference
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
      volumes:
        - name: reference
          persistentVolumeClaim:
            claimName: nf-reference-pvc
MANIFEST
fi

if ! kubectl wait --for=condition=complete "job/${JOB}" -n "$NS" --timeout=6h >/dev/null; then
  kubectl logs "job/${JOB}" -n "$NS" || true
  kubectl describe job "$JOB" -n "$NS" >&2 || true
  fail "Reference bootstrap failed. Inspect Job ${JOB} in namespace ${NS}."
fi
kubectl logs "job/${JOB}" -n "$NS"
