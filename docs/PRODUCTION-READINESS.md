# POC et préparation production

## État actuel

Le dépôt déploie ses ressources dans le projet Scaleway précréé `hcl-nextflow` (SA-Demo, `fr-par-3`) et a exécuté un pipeline RNA-seq de démonstration sur Kapsule 1.37.0. Le run `validation-20260925` a subi une éviction de l'autoscaler, a repris et s'est terminé. Le contrôle technique des artefacts a passé avant 19:43:12 UTC; cela ne qualifie ni la validité biologique ni la production.

Le dépôt vise la faisabilité et la stabilité du POC sur un petit jeu, pas un run de 300–400 échantillons / 2,2 To; cette échelle relève d'une qualification production séparée. Les valeurs par défaut sont destinées au pilote : pools orchestrateur POP2-4C-16G et calcul POP2-HM-8C-64G, jusqu'à deux nœuds chacun; PVC SFS 200 Go workdir et 50 Go référence. Le chargement STAR a mesuré environ 22 MB/s sur le workdir SFS de 200 Go; aucune comparaison contrôlée avec 100 Go n'isole l'effet du changement de capacité. Le jeu d'essai est limité à 50 000 paires.

Le profil opt-in `gen3_scratch_benchmark` et le pool `gen3-probe` en `fr-par-2` sont configurés. Le premier Job GEN3 s'est terminé avec succès à 09:52:48 UTC et la validation technique a passé. Après remplacement du nœud à 11:12:46 UTC, Nextflow a repris automatiquement `gen3-recovery-20260926` sur `bbfe88`; une inspection manuelle du pod a relevé `root=overlay`, `/scratch=/dev/sdb ext4` et ~145,6 GiB. Le Job s'est terminé à 11:50:16 UTC et le contrôle technique des sorties a passé.

Un exercice a supprimé puis restauré un fichier de 1 MiB depuis SFS et S3 avec le même SHA-256 (`634fbf86…dbf`); les données temporaires ont été nettoyées. Cela ne qualifie pas une restauration complète.

Le 26 septembre, un manifeste historique a été vérifié par SHA complet puis migré : `genome.fa` et `genes.gtf` étaient OK; les tailles enregistrées sont 3 151 425 851 B et 1 463 917 491 B. Cette opération a duré 11 min 46 s. Le bootstrap suivant a validé les tailles en 13 s sans SHA complet. Ce contrôle détecte absence et troncature, pas une corruption conservant exactement la taille; prévoir des vérifications SHA périodiques pour la production.

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

Ces mesures forment une seule série sur un seul échantillon, avec STAR en charge. `curl` ne passe pas par le plugin S3 Nextflow; `POSIX_FADV_DONTNEED` ne garantit pas l'absence de cache. `/tmp` est l'overlay du conteneur, pas un benchmark Block Storage. Les disques système Block Storage sbs_5k et le scratch NVMe GEN3 n'ont pas fait l'objet d'un benchmark disque isolé. Le bucket temporaire et les fichiers de test ont été supprimés.

## Avant données de production

- **Capacité production** : mesurer RAM/CPU STAR, débit et capacité SFS, autoscaling, durée et coût sur des échantillons pleine profondeur représentatifs. C'est une qualification distincte du POC.
- **Reprise et restauration** : interrompre/reprendre un run sur le même workdir; tester la restauration SFS, des objets S3 et du state dans un environnement isolé.
- **Données et QC** : définir rétention, chiffrement, droits d'accès, observabilité et alertes. Faire valider références, checksums, paramètres, métriques et rapports par le responsable bioinformatique.
- **IAM** : Object Storage IAM Scaleway est à portée projet. Les identités pipeline ont lecture/écriture objet; la clé backend a bucket read, objet read/write/delete pour le state et `.tflock`. Le bucket d'état du pilote historique est encore dans le projet du pipeline : le migrer vers un projet distinct avant le travail multi-utilisateur ou des données de production. Le state infra contient la clé IAM du pipeline : limiter sa lecture, y compris sur les anciennes versions, et prévoir sa rotation si le state a été exposé. Définir une expiration et une procédure de rotation avant des données de production.
- **Cycle de vie** : confirmer versions Kubernetes, providers, images et pipeline supportées; prévoir maintenance et rollback.

## Scratch NVMe local

Les trois pools Terraform portent le tag Scaleway `scw-create-scratch-volume`; il ne fournit un volume utilisable que sur les nouveaux nœuds compatibles créés avec ce tag. La présence d'un scratch sur les POP2 déjà provisionnés n'est pas garantie. Seul `gen3-probe` sert au test : les pods STAR y montent `/scratch` par `hostPath`. Le préflight vérifie un montage ext4 inscriptible sur un périphérique distinct du système, mais pas le modèle NVMe. `hostPath` n'est pas comptabilisé dans le stockage éphémère Kubernetes; `STAR_ALIGN` est donc limité à une tâche simultanée.

Lors de l'essai, le tag Terraform a été appliqué au pool; le remplacement d'un nœud a créé automatiquement un volume scratch de 160 Go. Le préflight terminé sur le nouveau nœud `a873a8` a vu `/dev/sdb` en ext4 sur `/scratch`, avec 146 Go utilisables et `hostPath.type: Directory`. Après un scale-down à zéro réussi, le préflight a redimensionné le pool de 0 à 1; son Job a terminé et a été nettoyé. L'API rapporte ensuite le pool à `size=0`, `ready`. Sur le pod de tâche Nextflow, `hostPath.type` apparaît vide : la directive de montage utilisée ne permet pas de le fixer; le préflight, lui, exige `Directory`.

Le préflight de lancement ne suffit pas après un remplacement de nœud. Chaque pod STAR contrôlera donc aussi `/proc/mounts` et `df`: `/scratch` devra être ext4, inscriptible, distinct de la source du système et disposer d'au moins 60 GiB libres. L'image STAR ne contenant pas `stat`, le garde n'en dépend pas. Ce changement n'était pas présent dans le ConfigMap du run de reprise et s'appliquera aux prochains runs; le scratch de `bbfe88` a été inspecté manuellement.

Le profil active `scratch=true` pour `STAR_GENOMEGENERATE` et `STAR_ALIGN`. Seul `STAR_GENOMEGENERATE` force `stageInMode = 'copy'` : FASTA/GTF sont copiés depuis la référence SFS vers le scratch, puis l'index produit revient dans le workdir SFS. `STAR_ALIGN` garde le staging par défaut : l'index du workdir reste lu depuis SFS, tandis que les fichiers de travail STAR sont écrits sur `/scratch` et les sorties déclarées sont recopiées vers SFS. Le head publie ensuite les résultats depuis SFS vers S3. Les autres tâches du pipeline restent sur POP2 `star-compute` en `fr-par-3`.

Ce test ne mesure pas isolément l'effet du scratch : le pilote de référence utilisait POP2 en `fr-par-3`, tandis que le pool MEMORY3 d'essai est en `fr-par-2`; type de nœud et zone changent aussi. Pour attribuer un gain au stockage local, comparer scratch activé et désactivé sur le même type de nœud et dans la même zone. Le profil et le jeu pilote de 50 000 paires vérifient la faisabilité du parcours, pas la performance d'un lot de production. En particulier, scratch ne supprime pas les lectures d'index observées sur SFS par `STAR_ALIGN`.

Le scratch est local au nœud. Une interruption peut y laisser des fichiers temporaires; le remplacement du nœud les perd. Ils ne font pas partie du cache reprenable : garder le workdir sur SFS et reprendre avec le même `RUN_ID` et le même profil. Mesurer séparément les lectures SFS, les écritures scratch, les transferts stage-in/stage-out et la durée STAR; les compteurs `rchar`/`wchar` de Nextflow ne distinguent pas les montages. Ne conclure qu'après fin du Job, validation des artefacts et mesure de la reprise.

### Mesure de `STAR_GENOMEGENERATE` sur GEN3 — 26 septembre 2026 (UTC)

| Étape / métrique | Résultat observé |
|---|---|
| Entrée | Début de tâche à 08:08:29; environ 4,3 GiB de FASTA/GTF copiés sur scratch avant le calcul (durée de copie non isolée). |
| Tâche Nextflow | Durée 1 h 08 min 27 s; `realtime` 36 min 40 s; CPU 447,1 %; RSS maximale 51,5 GB. |
| STAR | Calcul interne terminé à 08:54:16. |
| Sortie | Index de 29,8 GB recopié vers SFS; fin vers 09:16:56, soit environ 22 min 40 s à ~22 MB/s. |
| Même tâche sur POP2/SFS | Durée Nextflow 2 h 39 min 57 s; `realtime` 2 h 39 min 55 s. |

La durée de tâche GEN3 est 2,34× plus courte; le `realtime` rapporté est environ 4,36× plus court. Cette comparaison n'isole pas l'effet du scratch : type de nœud et zone diffèrent.

### Mesure de `STAR_ALIGN` sur GEN3 — 26 septembre 2026 (UTC)

| Étape / métrique | Résultat observé |
|---|---|
| Tâche GEN3 | Début à 09:17:02; durée 25 min 31 s, `realtime` 25 min 29 s. |
| Lecture de l'index STAR | 29,8 GB lus depuis SFS de 09:18:42 à 09:39:35 : 20 min 53 s, contre 22 min 33 s lors du pilote POP2/SFS. Le scratch n'a pas mis l'index en cache. |
| Même tâche sur POP2/SFS | Durée 26 min 24 s; `realtime` 26 min 23 s. |

Les durées `STAR_ALIGN` sont proches et le chargement de l'index reste sur SFS; les différences de type de nœud et de zone empêchent d'attribuer un gain au scratch.

Le Job Nextflow GEN3 s'est terminé avec succès (`completionTime` 09:52:48 UTC). Le contrôle technique des sorties a passé : 49 539 paires après trimming, 94,06 % mappés de façon unique, BAM de 7 864 439 octets, 10 036 lignes Salmon non nulles, 13 gènes featureCounts non nuls et MultiQC présent. Pour comparer au baseline POP2, les FASTQ et BAM ont des SHA-256 identiques; featureCounts a le même ETag et la même taille.

Sur les trois runs, les 252 894 transcrits et environ 45 676 `NumReads` sont constants; les lignes Salmon non nulles sont 10 052 (POP2), 10 036 (GEN3 initial) et 10 040 (reprise). TPM Pearson / variation totale : POP2 contre GEN3 initial, 0,999053 / 0,9234 %; POP2 contre reprise, 0,998008 / 0,9836 %; GEN3 initial contre reprise, 0,997640 / 0,9623 %. Une variation liée à l'inférence Salmon est probable, mais non démontrée; aucun seuil QC biologique précis n'est défini.

Le retry `gen3-recovery-20260926` a lui aussi passé le contrôle technique : 49 539 paires, 94,06 % mappés de façon unique, BAM de 7 864 439 octets, 10 040 quantifications Salmon non nulles, 13 gènes featureCounts non nuls et MultiQC présent. Après téléchargement depuis S3, les quatre BAM (`Aligned.out`, transcriptome, `markdup.sorted`, `sorted`) et featureCounts étaient identiques octet par octet au run `gen3-scratch-20260926`, avec SHA-256 correspondants. Le compte Salmon diffère entre les deux runs GEN3; la cause reste à établir. Ces contrôles techniques ne qualifient pas la biologie ni la production.

Ne qualifier la plateforme de production qu'après validation à l'échelle cible, tests de reprise/restauration, revue de sécurité et approbation bioinformatique.
