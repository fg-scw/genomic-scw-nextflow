# Exploitation

## Cluster et jobs

```bash
make kubeconfig
make status
kubectl logs -n bioinformatics job/<job>
kubectl describe job -n bioinformatics <job>
kubectl get events -n bioinformatics --sort-by=.lastTimestamp
```

Pour reprendre un run, conserver le même `RUN_ID` et ne passer `RESUME=1` qu'après contrôle du workdir et des sorties intermédiaires :

```bash
make run RUN_ID=<run-id> INPUT=s3://bucket/path/samplesheet.csv RESUME=1
```

Le runner conserve l'UUID de session Nextflow dans le PVC workdir, sous `.nextflow/sessions/<RUN_ID>`, puis passe cet UUID à `-resume`. Pour un run échoué créé avant ce suivi, retrouver son UUID dans l'historique ou le log Nextflow et créer ce fichier sur le PVC avant `RESUME=1`; le runner refuse de deviner la session globale la plus récente.

## Incidents rencontrés

| Symptôme | Cause | Protection / reprise |
|---|---|---|
| Pods Nextflow `Pending` lors du montage SFS | Chaque head/tâche peut demander les PVC workdir et référence; limite CSI par nœud. | Placer les pods à deux PVC sur `star-compute` et limiter la concurrence selon sa capacité. |
| Nextflow reçoit `forbidden` sur `pods/status` | RBAC incomplet sur cette sous-ressource. | Accorder `get` sur `pods/status` au ServiceAccount `nextflow`. |
| Plugin absent ou configuration refusée | Le plugin doit être déclaré avec sa version. | Utiliser `id 'name@version'` dans `nextflow.config`. |
| Conflit de nom ou rapports obsolètes pendant `-resume` | `-name` imposé ou Nextflow refuse d'écraser les fichiers trace/report/timeline existants. | Garder le même `RUN_ID`/workdir sans `-name`; activer `report.overwrite = true`, `timeline.overwrite = true` et `trace.overwrite = true`. |
| Autoscaler évince le head Nextflow | Pod head considéré comme évictable. | Annoter le head `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`. |
| STAR rapporte moins de 50 000 entrées sur le sous-ensemble démo | TrimGalore élimine quelques reads avant l'alignement. | Le validateur exige au moins 45 000 entrées STAR (90 % des 50 000 paires brutes) et affiche séparément le sous-ensemble brut et le compte après trimming. |
| L'ancien validateur du POC échouait sur macOS avec une classe awk non terminée | Slash non échappé dans une classe regex awk. | Le correctif séparait les clés S3 avec `awk -F/` et comparait les champs chemin. |
| L'ancien validateur du POC ne trouvait pas `quant.sf` | Le chemin supposé incluait `/salmon/`; nf-core/rnaseq 3.14.0 publie `star_salmon/<sample>/quant.sf`. | Le validateur a été corrigé d'après les clés S3 réelles du pipeline. |
| Pod STAR reste `Terminating` en état D/I/O | Processus bloqué en attente d'I/O sur le stockage. | Attendre sa disparition effective avant reprise; inspecter nœud et stockage, ne pas le supprimer de force. |
| Fichiers STAR subsistent sur `/scratch` après interruption | Le scratch `hostPath` est local au nœud; l'arrêt brutal peut empêcher le nettoyage de la tâche. | Reprendre depuis le workdir SFS avec le même `RUN_ID`; ne pas compter sur ces fichiers. Le remplacement du nœud les perd. |
| Garde scratch échoue dans l'image STAR | L'image ne contient pas `stat`. | Le garde lit `/proc/mounts` et `df` pour vérifier ext4, le périphérique distinct, l'écriture et 60 GiB libres avant chaque pod STAR; il s'appliquera aux prochains runs. |
| Référence SFS lente à revérifier après succès | Un SHA complet relisait FASTA et GTF à chaque bootstrap. | Ancien manifeste : migration avec SHA en 11 min 46 s; lancement suivant, contrôle tailles en 13 s sans SHA. Absence/troncature échoue; corruption à taille identique non détectée, donc SHA périodique en production. |
| Nœud GEN3 remplacé pendant STAR | Le scratch est local au nœud. | Observé à 11:12:46 UTC : Nextflow a repris automatiquement `gen3-recovery-20260926` sur `bbfe88`; contrôle manuel dans le pod : `root=overlay`, `/scratch=/dev/sdb ext4`, ~145,6 GiB. Job terminé à 11:50:16 UTC et validation passée : quatre BAM et featureCounts identiques octet par octet au premier GEN3; Salmon 10 040 transcrits non nuls. Le garde par pod n'était pas dans le ConfigMap de ce run. |
| Restauration d'objet à vérifier | Un exercice limité n'équivaut pas à une reprise complète. | Suppression puis restauration d'un fichier de 1 MiB depuis SFS et S3 : SHA-256 identique (`634fbf86…dbf`); données de test nettoyées. |
| Débit SFS faible avec 100 Go | Limite de débit du volume sur le profil pilote. | Le workdir pilote est passé à 200 Go; mesurer le gain avant dimensionnement production. |
| `terraform -chdir=terraform/infra plan` échoue en refresh avec `GetBucketCors` HTTP 403 sur input/results | Le principal opérateur n'était pas autorisé dans les politiques restrictives des buckets. | Résolu : renseigner `operator_user_id`; le plan Terraform complet avec refresh réussit après ajout des statements aux deux policies. Garder le refresh activé; ne pas utiliser `-refresh=false` en routine. |

## Préserver et détruire

Avant `make destroy`, arrêter les nouveaux runs, attendre ou annuler les jobs actifs, sauvegarder les données S3 et les données SFS à conserver, puis vérifier le backend distant. La cible détruit d'abord les ressources Kubernetes puis l'infrastructure et demande confirmation Terraform. Les PVC peuvent contenir des références et des fichiers de travail; leur destruction n'est pas une purge sélective. Le bucket de state est externe au Terraform de l'application et doit être conservé.

Les buckets de données ont le versioning activé. Les versions courantes ne sont pas purgées automatiquement; les versions remplacées expirent après 365 jours par défaut et les uploads multipart incomplets après 7 jours. Un bucket non vide peut empêcher sa suppression par Terraform. Ne pas vider de bucket pour faire réussir `destroy`.

## État distant

### Travail à plusieurs

Chaque contributeur copie les exemples en fichiers locaux, puis renseigne le même bucket, la même région et le même endpoint. Gardez les mêmes chemins S3 de state entre contributeurs, mais un chemin distinct par racine (`infra.tfstate` et `kubernetes.tfstate`); conservez `use_lockfile=true` dans les deux fichiers.

```bash
cp terraform/infra/backend.hcl.example terraform/infra/backend.hcl
cp terraform/kubernetes/backend.hcl.example terraform/kubernetes/backend.hcl
```

Un administrateur du projet d'état crée une fois le bucket privé et versionné :

```bash
scw object bucket create NOM_BUCKET_ETAT enable-versioning=true acl=private project-id=UUID_PROJET_ETAT region=fr-par
```

Chaque opérateur utilise sa propre identité et ses propres clés Scaleway; ne partagez pas une clé personnelle. L'identité du backend doit pouvoir lister le bucket, lire et écrire le state, ainsi que lire, créer et supprimer le fichier `.tflock` (`ObjectStorageObjectsRead`, `ObjectStorageObjectsWrite`, `ObjectStorageObjectsDelete`). Scaleway accorde ces permissions Object Storage au niveau projet : gardez le projet d'état distinct du projet de déploiement (`scw_project_id`) et limitez les accès à chacun. Pour l'accès S3, configurez le projet d'état comme projet préféré de la clé API.

Si deux opérateurs travaillent sur la même racine, le second reçoit une erreur de verrou pendant l'opération du premier; `-lock-timeout=5m` permet d'attendre. Les verrous `infra` et `kubernetes` sont distincts, mais Kubernetes dépend de l'infrastructure. Le verrou ne protège pas la période entre un plan et son apply : coordonnez cette séquence et relancez le plan si quelqu'un a appliqué un changement depuis. Pour un verrou abandonné, vérifiez d'abord que le processus Terraform est terminé et récupérez son ID dans le message d'erreur, puis lancez la commande dans la racine concernée :

```bash
terraform -chdir=terraform/infra force-unlock LOCK_ID
```

Remplacez `infra` par `kubernetes` pour l'autre state. Ne supprimez jamais `.tflock` à la main. Sur le bucket pilote, un second `plan` lancé pendant un `apply` temporaire a été refusé par le verrou S3 le 29 septembre 2026; il a réussi après la fin de l'`apply`. Ce test valide la concurrence entre deux processus, pas les droits de deux identités distinctes. Le state, ses versions antérieures et les fichiers de plan peuvent contenir des secrets, dont la clé IAM du pipeline : ne les commitez ni ne les partagez, et restreignez leur lecture.

Les exemples activent `encrypt=true`. Le bucket pilote en `fr-par` a accepté un PUT temporaire avec `AES256` et les plans Terraform avec verrou le 29 septembre 2026. La [documentation Scaleway](https://www.scaleway.com/en/docs/object-storage/troubleshooting/400-error-aes256/) indique pourtant que cet en-tête peut être rejeté. Vérifiez l'écriture et le verrouillage lors de la création d'un autre backend; ne supposez pas ce comportement identique dans toute région.

Pour une restauration, geler les opérations Terraform, conserver une copie du state courant, restaurer une version vérifiée du state et faire un `plan` avant tout `apply`. Références : [backend S3 et verrouillage Terraform](https://developer.hashicorp.com/terraform/language/backend/s3), [données sensibles et state Terraform](https://developer.hashicorp.com/terraform/language/manage-sensitive-data), [portée projet des droits Object Storage](https://www.scaleway.com/en/docs/object-storage/api-cli/combining-iam-and-object-storage/) et [permissions S3 Scaleway](https://www.scaleway.com/en/docs/object-storage/reference-content/s3-iam-permissions-equivalence/).
