# POC et préparation production

## État actuel

Le dépôt déploie ses ressources dans le projet Scaleway précréé `hcl-nextflow` (SA-Demo, `fr-par-3`) et exécute un pipeline RNA-seq de démonstration sur Kapsule 1.37.0. Le run `validation-20260925` a subi une éviction de l'autoscaler, a repris et s'est terminé. `make validate-run` a passé les contrôles techniques avant 19:43:12 UTC; cela ne qualifie ni la validité biologique ni la production.

Les valeurs par défaut sont destinées à un pilote : pools orchestrateur POP2-4C-16G et calcul POP2-HM-8C-64G, jusqu'à deux nœuds chacun; PVC SFS 200 Go workdir et 50 Go référence. Le chargement STAR a mesuré environ 22 MB/s sur le workdir SFS de 200 Go; aucune comparaison contrôlée avec 100 Go n'isole l'effet du changement de capacité. Le jeu d'essai est limité à 50 000 paires. Les volumes visés de 300–400 échantillons / 2,2 To ne sont pas qualifiés.

Le profil opt-in `gen3_scratch_benchmark` et le pool `gen3-probe` en `fr-par-2` sont configurés. `STAR_GENOMEGENERATE` et `STAR_ALIGN` ont été mesurés; le Job GEN3 s'est terminé avec succès à 09:52:48 UTC et la validation technique a passé. La reproductibilité des quantifications reste à revoir.

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

- **Capacité** : mesurer RAM/CPU STAR, débit et capacité SFS, autoscaling, durée et coût avec les plus gros échantillons représentatifs. Ajuster pools et PVC après mesure.
- **Reprise et restauration** : interrompre/reprendre un run sur le même workdir; tester la restauration SFS, des objets S3 et du state dans un environnement isolé.
- **Données et QC** : définir rétention, chiffrement, droits d'accès, observabilité et alertes. Faire valider références, checksums, paramètres, métriques et rapports par le responsable bioinformatique.
- **IAM** : Object Storage IAM Scaleway est à portée projet. Les identités pipeline ont lecture/écriture objet; la clé backend a bucket read, objet read/write/delete pour le state et `.tflock`. Placer seulement les ressources requises dans ce projet. Pour la production, isoler le backend dans un projet distinct ou ajouter des protections explicites sur les autres buckets.
- **Cycle de vie** : confirmer versions Kubernetes, providers, images et pipeline supportées; prévoir maintenance et rollback.

## Scratch NVMe local

Le pool d'essai `gen3-probe` utilise le tag Scaleway `scw-create-scratch-volume`; les pods STAR le montent sur `/scratch` par `hostPath`. Le préflight place un pod sur ce pool et vérifie un montage ext4 inscriptible, avec une source bloc distincte du système. Il ne vérifie ni le modèle NVMe ni la capacité réelle. `hostPath` n'est pas comptabilisé dans le stockage éphémère Kubernetes; `STAR_ALIGN` est donc limité à une tâche simultanée.

Lors de l'essai, le tag Terraform a été appliqué au pool; le remplacement d'un nœud a créé automatiquement un volume scratch de 160 Go. Le préflight terminé sur le nouveau nœud `a873a8` a vu `/dev/sdb` en ext4 sur `/scratch`, avec 146 Go utilisables et `hostPath.type: Directory`. Après un scale-down à zéro réussi, le préflight a redimensionné le pool de 0 à 1; son Job a terminé et a été nettoyé. L'API rapporte ensuite le pool à `size=0`, `ready`. Sur le pod de tâche Nextflow, `hostPath.type` apparaît vide : la directive de montage utilisée ne permet pas de le fixer; le préflight, lui, exige `Directory`.

Le profil active `scratch=true` pour `STAR_GENOMEGENERATE` et `STAR_ALIGN`. Seul `STAR_GENOMEGENERATE` force `stageInMode = 'copy'` : FASTA/GTF sont copiés depuis la référence SFS vers le scratch, puis l'index produit revient dans le workdir SFS. `STAR_ALIGN` garde le staging par défaut : l'index du workdir reste lu depuis SFS, tandis que les fichiers de travail STAR sont écrits sur `/scratch` et les sorties déclarées sont recopiées vers SFS. Le head publie ensuite les résultats depuis SFS vers S3. RSEM et les autres tâches restent sur POP2 `star-compute` en `fr-par-3`.

Ce test ne mesure pas encore l'effet isolé du scratch : le pilote de référence utilisait POP2 en `fr-par-3`, tandis que le pool MEMORY3 d'essai est en `fr-par-2`; le type de nœud et la zone changent aussi. Pour attribuer un gain au stockage local, comparer scratch activé et désactivé sur le même type de nœud et dans la même zone. La limite à une tâche STAR et le jeu pilote de 50 000 paires ne qualifient pas un lot de 300–400 échantillons. En particulier, scratch ne supprime pas les lectures d'index observées sur SFS par `STAR_ALIGN`.

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

Le Job Nextflow GEN3 s'est terminé avec succès (`completionTime` 09:52:48 UTC). `make validate-run RUN_ID=gen3-scratch-20260926` a passé les contrôles techniques : 49 539 paires après trimming, 94,06 % mappés de façon unique, BAM de 7 864 439 octets, 10 036 lignes Salmon non nulles, 13 gènes featureCounts non nuls et MultiQC présent. Le BAM et featureCounts ont les mêmes tailles et ETags S3 que le baseline POP2; Salmon diffère (10 036 contre 10 052 lignes non nulles), avec 252 894 transcrits et 45 676 reads mappés dans les deux cas. La reproductibilité biologique reste à examiner; ce résultat ne qualifie pas la production.

## Qualification de 300–400 échantillons

Le sous-ensemble de 50 000 paires valide le parcours, mais ne prédit pas la durée d'un échantillon complet. Pour `N` échantillons, mesurer `tᵢ` sur des échantillons représentatifs et estimer le temps STAR par `max(max(tᵢ), Σtᵢ / C_eff)`, plus les attentes de planification. À durées proches, cela correspond à environ `ceil(N / C_eff) × t_STAR`. `C_eff` est le parallélisme réellement observé, pas la capacité théorique du pool.

| Configuration actuelle | Parallélisme STAR maximal | Ordre de grandeur des vagues STAR pour 300–400 échantillons |
|---|---:|---:|
| POP2 `star-compute`, deux workers au plus | 2 (effectif à mesurer; contention possible) | 150–400 |
| GEN3 `gen3-probe`, un nœud et `maxForks=1` | 1 | 300–400 |

Ajouter au temps de bout en bout le chemin critique des autres étapes, attentes et transferts; compter la génération de l'index une seule fois si elle a lieu dans ce run. Qualifier d'abord plusieurs échantillons complets couvrant les tailles réelles, puis un lot test avec autoscaling; comparer scratch activé/désactivé sur le même type de nœud et dans la même zone. Enfin tester interruption/reprise et restauration S3, SFS et state en environnement isolé, avec objectifs de durée, coût et RPO/RTO définis. Le passage en production reste conditionné à ces mesures et à la validation biologique.

Ne qualifier la plateforme de production qu'après validation à l'échelle cible, tests de reprise/restauration, revue de sécurité et approbation bioinformatique.
