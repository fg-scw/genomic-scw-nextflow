# nf-core/rnaseq sur Scaleway Kapsule

POC Terraform pour Kapsule **1.37.0**, Nextflow **25.10.4** et `nf-core/rnaseq` **3.14.0**. Le projet Scaleway précréé `hcl-nextflow` (`1d6906b8-42b0-4141-8752-28b7fcfccb95`, organisation SA-Demo) est en région `fr-par`, zone `fr-par-3`; Terraform y déploie les ressources.

Le pipeline utilise `nf-k8s` 1.2.2, `nf-amazon` 3.4.1 et GRCh38 Ensembl 110. Les entrées et résultats vont dans Object Storage; le workdir Nextflow et la référence partagée sont sur SFS RWX.

## Infrastructure

```mermaid
flowchart LR
  subgraph SCW["Projet hcl-nextflow · fr-par-3"]
    subgraph K["Kapsule 1.37.0"]
      subgraph O["Pool orchestrator"]
        REF["Job bootstrap<br/>GRCh38 Ensembl 110"]
      end
      subgraph C["Pool star-compute"]
        HEAD["Job head Nextflow"]
        TASKS["Pods de tâches nf-core<br/>dont STAR"]
      end
    end
    WORK[("SFS RWX<br/>workdir · 200 Go")]
    REFVOL[("SFS RWX<br/>référence · 50 Go")]
    SHEET[("Object Storage<br/>samplesheet")]
    FASTQ[("Object Storage<br/>FASTQ")]
    RESULTS[("Object Storage<br/>résultats")]
    BLOCK["Block Storage sbs_5k<br/>disques système des nœuds<br/>pas le workdir/référence"]
    NVME["GEN3 MEMORY NVMe<br/>option scratch · non déployée"]
  end

  REF -->|"écrit la référence"| REFVOL
  REFVOL -->|"lecture seule"| TASKS
  HEAD -->|"orchestration"| TASKS
  SHEET -->|"lecture au lancement"| HEAD
  FASTQ -->|"source des reads"| HEAD
  HEAD <-->|"staging FASTQ / reprise"| WORK
  WORK -->|"FASTQ stagés"| TASKS
  TASKS -->|"sorties de tâches"| WORK
  HEAD -->|"publishDir depuis le workdir SFS"| RESULTS
  O -->|"disques système"| BLOCK
  C -->|"disques système"| BLOCK
  TASKS -.->|"benchmark futur; montage explicite requis"| NVME
  classDef optional stroke-dasharray: 5 5;
  class NVME optional;
```

## Workflow

```mermaid
flowchart LR
  A[Bootstrap state] --> B[Terraform infrastructure]
  B --> C[Kubeconfig + Terraform Kubernetes]
  C --> D[Sync secret]
  D --> E[Préparer GRCh38 et FASTQ]
  E --> F[Exécuter nf-core/rnaseq]
  F --> G[Valider Job, BAM, quantifications, MultiQC]
```

## Prérequis et configuration

Installer Terraform 1.11+, Scaleway CLI `scw`, `kubectl`, AWS CLI v2, `jq`, `curl`, `gzip`, `make` et Bash. Le profil Scaleway doit gérer le projet dédié et lire ses secrets. Un accès S3 backend distinct est requis.

Variables : `SCW_PROFILE` pour Scaleway; `STATE_SECRET_ID`, `STATE_SECRET_REVISION` et `STATE_REGION` pour charger l'identité backend; `STATE_BUCKET` pour les deux states; `RUN_ID` pour chaque run. `STATE_PROJECT_ID` est déjà réglé sur le projet `hcl-nextflow` dans Makefile.

Copier les exemples puis remplacer le bucket `REPLACE_WITH_PRECREATED_STATE_BUCKET` par le même nom dans les deux fichiers backend :

```bash
cp terraform/infra/backend.hcl.example terraform/infra/backend.hcl
cp terraform/kubernetes/backend.hcl.example terraform/kubernetes/backend.hcl
cp terraform/infra/terraform.tfvars.example terraform/infra/terraform.tfvars
cp terraform/kubernetes/terraform.tfvars.example terraform/kubernetes/terraform.tfvars
```

Le bucket Terraform doit être privé et versionné. Il est distinct des buckets input/résultats. La cible `make bootstrap-state` le crée (ou vérifie son versioning); elle passe le `STATE_PROJECT_ID` explicitement au CLI Scaleway.

Définir le profil Scaleway et les coordonnées non secrètes de la clé backend, puis la charger dans le shell courant. Remplacer les valeurs d'exemple par celles de l'environnement. La valeur du secret ne s'affiche pas et ne s'écrit pas dans le dépôt :

```bash
export SCW_PROFILE="your-scaleway-profile"
export STATE_SECRET_ID="your-secret-id"
export STATE_SECRET_REVISION="your-secret-revision"
export STATE_REGION="fr-par"
set +x
state_credentials="$(scw secret version access "$STATE_SECRET_ID" revision="$STATE_SECRET_REVISION" region="$STATE_REGION" raw=true)"
export AWS_ACCESS_KEY_ID="$(jq -er '.access_key' <<<"$state_credentials")"
export AWS_SECRET_ACCESS_KEY="$(jq -er '.secret_key' <<<"$state_credentials")"
unset state_credentials
export STATE_BUCKET="replace-with-unique-state-bucket"
```

Les scripts du pipeline lisent automatiquement leur propre clé S3 depuis Secret Manager. `PIPELINE_S3_ACCESS_KEY` et `PIPELINE_S3_SECRET_KEY` ne sont que des surcharges locales. Ne jamais enregistrer de clé, secret ou kubeconfig dans Git.

Les permissions Object Storage Scaleway sont accordées au niveau projet. Les identités pipeline et backend couvrent les buckets du projet selon leurs permission sets; le projet doit rester dédié à cette solution. La clé backend comprend la suppression nécessaire au verrou Terraform `.tflock`.

## Déployer et valider

`deploy-and-validate` déploie l'infrastructure puis Kubernetes, synchronise le secret, prépare la référence et un petit jeu RNA-seq humain, lance le pipeline et contrôle les artefacts :

```bash
make deploy-and-validate STATE_BUCKET="$STATE_BUCKET" RUN_ID=validation-20260925
```

Terraform demande confirmation. Après revue des plans, `AUTO_APPROVE=1` permet une exécution non interactive. Pour un cluster existant :

```bash
make smoke-test RUN_ID=validation-20260925
make validate-run RUN_ID=validation-20260925
make status
```

Avant de détruire, sauvegarder les données S3/SFS à conserver et arrêter les jobs actifs. `make destroy` est interactif; le bucket de state est conservé :

```bash
make destroy
```

Le run utilise une entrée SRR1039508 réduite à 50 000 paires. La validation vérifie la fin du Job, les logs STAR, le BAM, les quantifications et le rapport MultiQC. Elle confirme le fonctionnement technique, pas la validité biologique des résultats. Reprendre explicitement un run avec `RESUME=1` après vérification du workdir :

```bash
make smoke-test RUN_ID=validation-20260925 RESUME=1
```

## POC et production

Le run humain a validé le parcours e2e sur un PVC workdir SFS de 200 Go et une référence de 50 Go : le Job s'est terminé et `make validate-run` a vérifié les artefacts. Le chargement STAR a observé environ 22 MB/s sur SFS; aucune comparaison contrôlée entre les PVC de 100 et 200 Go ne permet d'attribuer un gain à l'agrandissement. Cette validation confirme le fonctionnement technique, pas la validité biologique. Les pools et PVC restent dimensionnés pour le pilote; les volumes de 300–400 échantillons ou 2,2 To, la reprise après panne, les coûts et la restauration ne sont pas qualifiés.

Avant toute production, faire un benchmark représentatif STAR, dimensionner SFS/autoscaling, tester reprise et restauration, définir rétention/observabilité, et faire valider les métriques QC. Les permissions IAM objet sont à l'échelle du projet : séparer aussi le backend Terraform dans un projet isolé ou protéger explicitement les autres buckets.

Les instances GEN3 MEMORY offrent une option de benchmark scratch NVMe local; elle n'est pas activée ici. Voir [Préparation production](docs/PRODUCTION-READINESS.md). Les opérations de reprise et destruction sont dans [Exploitation](docs/OPERATIONS.md).

## Observations du pilote — 25 septembre 2026 (UTC)

| Timestamp UTC | Étape | Résultat observé | Pool / lieu |
|---|---|---|---|
| 13:47:37–14:46:37 | Bootstrap de la référence | Job GRCh38 Ensembl 110 terminé. | orchestrator |
| 15:00:27 | Premier Job Nextflow | Démarrage du run; une tâche STAR de tri apparaît à 15:36:59. | star-compute |
| ≈16:07 | Éviction autoscaler | Head évincé; le pod STAR porte un `deletionTimestamp` à 16:06:50. | star-compute |
| 16:19:06–16:19:56 | Reprise | Job/head puis pod STAR recréés; caches Nextflow réutilisés. | star-compute |
| 16:27:49 | Index STAR | Nouvelle étape de génération d'index observée. | star-compute |
| 16:43:46 | Étape STAR de tri | Étape observée après la reprise. | star-compute |
| ≈17:05 | Écriture `SA_*` | Écriture de blocs temporaires observée; Job encore `Running` lors de la capture de 17:41. | star-compute |
| 18:28:01 | Suffix array STAR | Génération et empaquetage terminés. | star-compute |
| 18:59:52 | Génération de l'index STAR | Étape terminée avec succès. | star-compute |
| 18:59:56–19:22:29 | Lecture de l'index STAR | 29,8 GB chargés depuis SFS en 22 min 33 s. | star-compute |
| ≈19:26 | Alignement STAR | 49 539 reads après trimming; 94,06 % mappés de façon unique; BAM de 7,6 MB. | star-compute |
| 19:28:59 | Pool de calcul | Le second nœud `star-compute` est `Ready`. | star-compute |
| 19:38:41 | Job Nextflow | Job terminé (`Complete`). | star-compute |
| ≈19:43 | `make validate-run` | Validation passée : BAM de 7 864 439 octets, 10 052 transcrits quantifiés, 13 gènes avec des comptes non nuls et rapport MultiQC présent. | — (commande locale) |
