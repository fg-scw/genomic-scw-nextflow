# Exploitation

## Suivre et reprendre un run

```bash
export KUBECONFIG="$HOME/.kube/config-hcl-public-netflow"
make status
kubectl logs -n bioinformatics "job/nextflow-$RUN_ID" -c nextflow
kubectl describe job -n bioinformatics "nextflow-$RUN_ID"
kubectl get events -n bioinformatics --sort-by=.lastTimestamp
```

La reprise utilise le même `RUN_ID` et l'UUID conservé dans `.nextflow/sessions/<RUN_ID>` sur SFS. Après vérification d'un état **Failed ou Complete**, mettez `RUN_RESUME=1` dans `run.env`, puis :

```bash
kubectl delete job -n bioinformatics "nextflow-$RUN_ID"
make run
```

Ne supprimez pas un Job actif. Un template de Job est immuable : si la configuration de référence change, supprimez uniquement son Job terminal avant de relancer `make reference`. Les ConfigMaps hashées ne sont pas supprimées automatiquement; retirez-les seulement lorsqu'aucun Job ne les utilise.

## Stockage et protections

| Élément | Fonctionnement |
| --- | --- |
| Head et tâches à deux PVC | Placés sur des pools capables de monter les deux SFS; le petit orchestrator n'en monte qu'un. |
| Scratch GEN3 | Tag Terraform `scw-create-scratch-volume`; montage `/scratch` par `hostPath`. Chaque pod STAR vérifie ext4, périphérique distinct, écriture et ≥60 GiB libres. |
| Données temporaires | Perdues avec le nœud. Seules les sorties déclarées retournent dans le workdir SFS; ne comptez pas sur le scratch pour reprendre. |
| Référence | Checksums à l'installation, tailles à chaque lancement. Une corruption conservant la taille exige un contrôle SHA complet. |
| Reprise | UUID propre au run, rapports écrasables, head protégé contre l'éviction, RBAC et plugins explicitement configurés. |
| Pods Pending | Une montée autoscaler ou une file d'attente CPU peut être normale; inspectez les événements si l'attente persiste. |
| Pod bloqué en I/O | Inspectez nœud et stockage; attendez sa disparition effective avant reprise, sans suppression forcée. |
| Terraform 403 | Vérifiez `operator_user_id` et les policies des buckets; gardez le refresh activé. |

Le profil GEN3 place uniquement l'indexation et l'alignement STAR sur MEMORY3; Salmon/QC et head restent sur POP2. L'index d'alignement est lu depuis SFS, le travail temporaire écrit sur NVMe. Le test de cette branche a validé ce montage et son contrôle par pod, sans benchmark disque isolé.

## Terraform à plusieurs

- Même bucket privé/versionné et mêmes clés de state pour tous : un fichier pour `infra`, un pour `kubernetes`, avec `use_lockfile=true`.
- Une identité par opérateur, autorisée à lister le bucket, lire/écrire le state et lire/créer/supprimer `.tflock`. Pour S3, la clé doit cibler le projet d'état (projet préféré ou suffixe `@UUID_PROJET_ETAT`).
- Un seul apply par racine. `-lock-timeout=5m` attend le verrou; coordonnez aussi les changements entre infra et Kubernetes. Refaites un plan après un changement appliqué par un collègue.
- Le state contient la clé pipeline. Placez son bucket dans un projet distinct, protégez ses anciennes versions et ne partagez pas les plans. Le backend du POC reste dans le projet pipeline : **à migrer avant un usage partagé ou la production**.

Pour un verrou abandonné, vérifiez que le processus propriétaire est arrêté avant `terraform -chdir=terraform/infra force-unlock LOCK_ID`. N'effacez pas `.tflock` manuellement. Pour restaurer un state, gelez les opérations, sauvegardez l'état courant, restaurez une version vérifiée et relancez un plan. Vérifiez aussi la prise en charge de `encrypt=true` sur un nouveau backend. [Backend S3 Terraform](https://developer.hashicorp.com/terraform/language/backend/s3).

## Limites et nettoyage

Le petit run ne qualifie pas le dimensionnement, la restauration complète ou la validité biologique. Avant la production : données représentatives, reprise/restauration, contrôles d'intégrité, IAM/rétention et validation bioinformatique. MEMORY3 a fonctionné avec SFS dans le POC, mais ne figure pas parmi les CPU pleinement qualifiés dans la [matrice File Storage Scaleway](https://www.scaleway.com/en/docs/file-storage/reference-content/file-system-instance-selection/); confirmer cette prise en charge avant de généraliser ce pool.

Avant `make destroy`, arrêtez les runs et sauvegardez SFS/S3. Terraform détruit Kubernetes puis l'infrastructure après confirmation; le bucket d'état externe reste conservé. Les buckets de données sont versionnés : ne les videz pas pour forcer un destroy. L'expiration des anciennes versions est configurable; les uploads multipart incomplets expirent après sept jours.
