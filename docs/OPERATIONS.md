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
make run-pipeline RUN_ID=<run-id> RESUME=1
```

## Incidents rencontrés

| Symptôme | Cause | Protection / reprise |
|---|---|---|
| Pods Nextflow `Pending` lors du montage SFS | Chaque head/tâche peut demander les PVC workdir et référence; limite CSI par nœud. | Placer les pods à deux PVC sur `star-compute` et limiter la concurrence selon sa capacité. |
| Nextflow reçoit `forbidden` sur `pods/status` | RBAC incomplet sur cette sous-ressource. | Accorder `get` sur `pods/status` au ServiceAccount `nextflow`. |
| Plugin absent ou configuration refusée | Le plugin doit être déclaré avec sa version. | Utiliser `id 'name@version'` dans `nextflow.config`. |
| Conflit de nom ou rapports obsolètes pendant `-resume` | `-name` imposé ou Nextflow refuse d'écraser les fichiers trace/report/timeline existants. | Garder le même `RUN_ID`/workdir sans `-name`; activer `report.overwrite = true`, `timeline.overwrite = true` et `trace.overwrite = true`. |
| Autoscaler évince le head Nextflow | Pod head considéré comme évictable. | Annoter le head `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`. |
| STAR rapporte moins de 50 000 entrées sur le sous-ensemble démo | TrimGalore élimine quelques reads avant l'alignement. | Le validateur exige au moins 45 000 entrées STAR (90 % des 50 000 paires brutes) et affiche séparément le sous-ensemble brut et le compte après trimming. |
| `validate-run` échoue sur macOS avec une classe awk non terminée | Slash non échappé dans une classe regex awk. | Séparer les clés S3 avec `awk -F/` et comparer les champs chemin; éviter `[^/]` dans une regex awk. |
| `validate-run` ne trouve pas `quant.sf` | Le chemin supposé incluait `/salmon/`; nf-core/rnaseq 3.14.0 publie `star_salmon/<sample>/quant.sf`. | Valider les chemins contre les clés S3 réellement publiées par la version du pipeline. |
| Pod STAR reste `Terminating` en état D/I/O | Processus bloqué en attente d'I/O sur le stockage. | Attendre sa disparition effective avant reprise; inspecter nœud et stockage, ne pas le supprimer de force. |
| Débit SFS faible avec 100 Go | Limite de débit du volume sur le profil pilote. | Le workdir pilote est passé à 200 Go; mesurer le gain avant dimensionnement production. |
| `terraform -chdir=terraform/infra plan` échoue en refresh avec `GetBucketCors` HTTP 403 sur input/results | Le principal opérateur n'était pas autorisé dans les politiques restrictives des buckets. | Résolu : renseigner `operator_user_id`; le plan Terraform complet avec refresh réussit après ajout des statements aux deux policies. Garder le refresh activé; ne pas utiliser `-refresh=false` en routine. |

## Préserver et détruire

Avant `make destroy`, arrêter les nouveaux runs, attendre ou annuler les jobs actifs, sauvegarder les données S3 et les données SFS à conserver, puis vérifier le backend distant. La cible détruit d'abord les ressources Kubernetes puis l'infrastructure et demande confirmation Terraform. Les PVC peuvent contenir des références et des fichiers de travail; leur destruction n'est pas une purge sélective. Le bucket de state est externe au Terraform de l'application et doit être conservé.

Les buckets de données ont le versioning activé. Les versions courantes ne sont pas purgées automatiquement; les versions remplacées expirent après 365 jours par défaut et les uploads multipart incomplets après 7 jours. Un bucket non vide peut empêcher sa suppression par Terraform. Ne pas vider de bucket pour faire réussir `destroy`.

## État distant

Les deux racines Terraform ont des clés distinctes et utilisent `use_lockfile=true`. Ne pas supprimer manuellement `.tflock` ni lancer `force-unlock` avant d'avoir confirmé que le détenteur est terminé. Les permissions du backend sont au niveau projet Scaleway; protéger l'ensemble du projet, pas uniquement le bucket de state.

Pour une restauration, geler les opérations Terraform, conserver une copie du state courant, restaurer une version vérifiée du state et faire un `plan` avant tout `apply`.
