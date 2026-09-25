# POC et préparation production

## État actuel

Le dépôt déploie le projet Scaleway `hcl-nextflow` (SA-Demo, `fr-par-3`) et un pipeline RNA-seq de démonstration sur Kapsule 1.37.0. Le run `validation-20260925` est en cours; le POC ne sera validé qu'après succès de `make validate-run` et inspection des artefacts.

Les valeurs par défaut sont destinées à un pilote : pools orchestrateur POP2-4C-16G et calcul POP2-HM-8C-64G, jusqu'à deux nœuds chacun; PVC SFS 200 Go workdir et 50 Go référence. Le workdir a été augmenté de 100 à 200 Go après un débit observé proche du débit nominal SFS du volume de 100 Go; le gain de performance reste à mesurer sur un nouveau run. Le jeu d'essai est limité à 50 000 paires. Les volumes visés de 300–400 échantillons / 2,2 To ne sont pas qualifiés.

## Avant données de production

- **Capacité** : mesurer RAM/CPU STAR, débit et capacité SFS, autoscaling, durée et coût avec les plus gros échantillons représentatifs. Ajuster pools et PVC après mesure.
- **Reprise et restauration** : interrompre/reprendre un run sur le même workdir; tester la restauration SFS, des objets S3 et du state dans un environnement isolé.
- **Données et QC** : définir rétention, chiffrement, droits d'accès, observabilité et alertes. Faire valider références, checksums, paramètres, métriques et rapports par le responsable bioinformatique.
- **IAM** : Object Storage IAM Scaleway est à portée projet. Les identités pipeline ont lecture/écriture objet; la clé backend a bucket read, objet read/write/delete pour le state et `.tflock`. Placer seulement les ressources requises dans ce projet. Pour la production, isoler le backend dans un projet distinct ou ajouter des protections explicites sur les autres buckets.
- **Cycle de vie** : confirmer versions Kubernetes, providers, images et pipeline supportées; prévoir maintenance et rollback.

## Scratch NVMe local

Les instances Scaleway GEN3 MEMORY exposent du NVMe local éphémère, à benchmarker pour les tâches STAR intensives en I/O. Ce POC ne le monte pas : `scratch=true` seul ne choisit ni ne monte ce NVMe. Il faut déclarer explicitement le volume et son montage dans les pods de tâches et garantir leur placement sur les nœuds qui l'exposent.

Le scratch est local au nœud, non partagé et perdu avec le pod ou le nœud. Réserver SFS au workdir reprenable et aux références partagées, S3 aux entrées et résultats persistants. Comparer le débit STAR, le coût et le comportement après rescheduling avant adoption.

Ne qualifier la plateforme de production qu'après validation à l'échelle cible, tests de reprise/restauration, revue de sécurité et approbation bioinformatique.
