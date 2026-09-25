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

## Préserver et détruire

Avant `make destroy`, arrêter les nouveaux runs, attendre ou annuler les jobs actifs, sauvegarder les données S3 et les données SFS à conserver, puis vérifier le backend distant. La cible détruit d'abord les ressources Kubernetes puis l'infrastructure et demande confirmation Terraform. Les PVC peuvent contenir des références et des fichiers de travail; leur destruction n'est pas une purge sélective. Le bucket de state est externe au Terraform de l'application et doit être conservé.

Les buckets de données ont le versioning activé. Les versions courantes ne sont pas purgées automatiquement; les versions remplacées expirent après 365 jours par défaut et les uploads multipart incomplets après 7 jours. Un bucket non vide peut empêcher sa suppression par Terraform. Ne pas vider de bucket pour faire réussir `destroy`.

## État distant

Les deux racines Terraform ont des clés distinctes et utilisent `use_lockfile=true`. Ne pas supprimer manuellement `.tflock` ni lancer `force-unlock` avant d'avoir confirmé que le détenteur est terminé. Les permissions du backend sont au niveau projet Scaleway; protéger l'ensemble du projet, pas uniquement le bucket de state.

Pour une restauration, geler les opérations Terraform, conserver une copie du state courant, restaurer une version vérifiée du state et faire un `plan` avant tout `apply`.
