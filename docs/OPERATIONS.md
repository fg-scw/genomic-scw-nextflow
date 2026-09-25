# Exploitation, reprise et destruction

## État Terraform

Le backend est un bucket Object Storage créé avant `terraform init` par `make bootstrap-state`, distinct des buckets de données et avec versioning activé. Chaque root Terraform utilise une clé d'état dédiée et `use_lockfile=true`. Garder les fichiers `backend.hcl` hors Git et n'y inscrire aucun secret. Les credentials Scaleway viennent de l'environnement; les identifiants de projet et paramètres non secrets sont dans les fichiers `terraform.tfvars` locaux.

Si un `terraform apply` est interrompu, lire la sortie et l'état avant de recommencer. Initialiser les deux roots avec leur backend, lancer `plan`, puis appliquer seulement le plan revu. Ne pas supprimer manuellement les objets `.tflock` et ne pas lancer `force-unlock` sans confirmer que le processus ayant acquis le verrou est terminé et que l'identifiant correspond.

Les valeurs `sensitive` masquent certaines sorties CLI; elles ne chiffrent pas le state. Limiter les accès au bucket backend et aux versions de state comme à des secrets d'infrastructure.

## Rétablir l'accès au cluster

Après création ou remplacement du cluster, réinstaller son kubeconfig Scaleway avant de gérer les objets Kubernetes :

```bash
make kubeconfig
kubectl get nodes -o wide
kubectl get pvc -n bioinformatics
```

Le kubeconfig est local et ne doit pas être commité. En cas d'échec d'une ressource Kubernetes, consulter `kubectl describe`, les événements du namespace et les logs du pod concerné avant de relancer Terraform.

## Diagnostiquer et reprendre un run

Conserver l'identifiant de run utilisé pour préparer les entrées et lancer le pipeline. Il désigne une samplesheet et une destination de sortie stables. Pour un échec, examiner le Job Nextflow, le journal de tête et les pods qui ont échoué :

```bash
kubectl get jobs,pods -n bioinformatics -o wide
kubectl describe job -n bioinformatics <job>
kubectl logs -n bioinformatics job/<job>
kubectl get events -n bioinformatics --sort-by=.lastTimestamp
```

Ne pas reprendre aveuglément un run dont un résultat intermédiaire est erroné. Un hit de cache Nextflow peut réutiliser une sortie invalide. Corriger la cause, vérifier le workdir et ne lancer `make run-pipeline RUN_ID=<id> RESUME=1` que si la reprise est voulue et les fichiers intermédiaires sont cohérents. La validation finale vérifie la présence et la taille des principaux artefacts ainsi que le rapport MultiQC; un biologiste reste responsable de l'interprétation scientifique.

## Préserver les données avant destruction

Le teardown est volontairement interactif. Avant de détruire :

1. Arrêter les nouveaux runs et attendre ou annuler explicitement les Jobs actifs.
2. Inventorier les objets des buckets d'entrée et de résultats; copier les données à conserver vers un emplacement de sauvegarde distinct et vérifier le nombre d'objets et la taille copiée.
3. Sauvegarder les références et données de travail SFS nécessaires à une reprise. Les PVC peuvent être détruits avec les ressources Kubernetes ou le cluster.
4. Vérifier que le bucket et les objets de backend Terraform sont conservés.
5. Détruire d'abord les ressources Kubernetes, puis l'infrastructure Kapsule, en examinant chaque plan de destruction.

Ne pas vider un bucket d'entrée/résultats ni désactiver sa protection contre la destruction pour rendre un `destroy` possible. Les buckets de données sont versionnés : les versions courantes ne sont pas supprimées automatiquement; les versions remplacées expirent après 365 jours par défaut, valeur réglable, et les uploads multipart incomplets après 7 jours. Si Terraform refuse de supprimer un bucket non vide, garder ce bucket et ses données; procéder à une purge séparée uniquement selon la politique de rétention approuvée.

## Restauration

Pour restaurer, récupérer une version connue du state backend uniquement après avoir gelé les opérations Terraform et vérifié l'horodatage/la version à restaurer. Restaurer les jeux de données depuis leur copie vérifiée, déployer l'infrastructure et la plateforme, réinstaller le kubeconfig, réinjecter le secret de pipeline depuis Scaleway Secret Manager, puis exécuter un run de validation avec un nouvel identifiant. Ne jamais remplacer le state courant à l'aveugle : une sauvegarde de l'objet actuel est requise avant toute restauration.
