# POC et préparation production

## État actuel

Le dépôt déploie ses ressources dans le projet Scaleway précréé `hcl-nextflow` (SA-Demo, `fr-par-3`) et exécute un pipeline RNA-seq de démonstration sur Kapsule 1.37.0. Le run `validation-20260925` a subi une éviction de l'autoscaler, a repris et s'est terminé. `make validate-run` a passé les contrôles techniques avant 19:43:12 UTC; cela ne qualifie ni la validité biologique ni la production.

Les valeurs par défaut sont destinées à un pilote : pools orchestrateur POP2-4C-16G et calcul POP2-HM-8C-64G, jusqu'à deux nœuds chacun; PVC SFS 200 Go workdir et 50 Go référence. Le chargement STAR a mesuré environ 22 MB/s sur le workdir SFS de 200 Go; aucune comparaison contrôlée avec 100 Go n'isole l'effet du changement de capacité. Le jeu d'essai est limité à 50 000 paires. Les volumes visés de 300–400 échantillons / 2,2 To ne sont pas qualifiés.

## Mesures du pilote — 25 septembre 2026 (UTC)

Mesures faites depuis le pod head Nextflow sur `star-compute`, pendant une écriture STAR sur SFS. Les tests S3 utilisaient `curl` signé et un bucket privé temporaire du même projet.

| Cible / opération | Résultat observé |
|---|---|
| S3, PUT 64 MiB | Premier essai : 5,663 s (~11,9 MB/s); essais suivants : 1,434 et 1,410 s (~46,8–47,6 MB/s). |
| S3, GET 64 MiB | 0,565 / 0,759 / 0,423 s (~88–159 MB/s). |
| S3, HEAD | p50 81,9 ms; plage 72,6–122,7 ms. |
| S3, PUT 4 KiB | p50 396 ms; plage 176–610 ms. |
| S3, GET FASTQ réel (2 628 433 octets) | 0,179 / 0,103 / 0,095 s. |
| SFS virtiofs, PVC 200 Go | Écriture 64 MiB + `fsync`: 8,035 s (8,0 MiB/s); lecture après `POSIX_FADV_DONTNEED`: 8,977 s (7,1 MiB/s). `fsync` 4 KiB × 20 : p50 23,22 ms, p95 23,91 ms. |
| STAR, fichier `SA` | Croissance de 18,9 à 20,8 Go en 87 s, environ 22 MB/s. |
| STAR, lecture réelle du génome depuis SFS | `Genome` 3 219 295 493 B + `SA` 24 990 345 232 B + `SAindex` 1 565 873 619 B (29,8 GB) chargés de 18:59:56 à 19:22:29 UTC : 22 min 33 s, ~22 MB/s overhead inclus. |
| `/tmp` overlay du conteneur | Baseline 64 MiB : écriture 0,092 s, lecture 0,066 s; `fsync` 4 KiB : p50 1,70 ms. |

Ces mesures forment une seule série sur un seul échantillon, avec STAR en charge. `curl` ne passe pas par le plugin S3 Nextflow; `POSIX_FADV_DONTNEED` ne garantit pas l'absence de cache. `/tmp` est l'overlay du conteneur, pas un benchmark Block Storage. Les disques système Block Storage sbs_5k et le scratch NVMe GEN3 n'ont pas été benchmarkés directement. Le bucket temporaire et les fichiers de test ont été supprimés.

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
