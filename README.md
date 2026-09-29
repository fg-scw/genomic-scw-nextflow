# RNA-seq sur Scaleway Kapsule

Ce dépôt déploie Kapsule **1.37.0**, Nextflow **25.10.4** et nf-core/rnaseq **3.14.0**. Les pools de calcul se mettent à l'échelle à la demande. Le test intégré utilise GRCh38 Ensembl 110 et 50 000 paires de reads.

## Architecture

```mermaid
flowchart LR
  S3IN[("Object Storage<br/>samplesheet + FASTQ")] -->|samplesheet| HEAD
  OP["Machine opérateur<br/>Terraform"] --> K
  subgraph K["Kapsule 1.37"]
    ORCH["Pool orchestrator<br/>bootstrap référence"]
    HEAD["Job Nextflow head<br/>sur star-compute"]
    subgraph TASK["Pods nf-core/rnaseq"]
      STAR["STAR / Salmon / QC"]
      SCRATCH[("/scratch<br/>NVMe local, optionnel")]
    end
    HEAD --> STAR
  end
  ORCH --> REFVOL[("SFS référence<br/>GRCh38")]
  REFVOL --> STAR
  S3IN -->|FASTQ| STAR
  WORK[("SFS workdir<br/>cache et reprise")] <--> HEAD
  WORK <--> STAR
  STAR --> WORK
  WORK -->|publication| S3OUT[("Object Storage<br/>résultats")]
  STAR -. "profil GEN3 seulement<br/>hostPath" .-> SCRATCH
  STATE[("Object Storage<br/>Terraform state")] -. "state + lock" .-> OP
```

Le workdir partagé conserve les tâches terminées et permet la reprise avec le même RUN_ID. Le scratch est local au nœud, éphémère et utilisé seulement avec le profil GEN3. Les trois pools portent le tag scw-create-scratch-volume; seuls les nœuds compatibles créés avec ce tag reçoivent le volume.

## Avant de commencer

Sur macOS avec Homebrew :

```bash
brew install scw kubectl awscli jq make curl gzip
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
scw login
```

Terraform 1.11 ou plus récent est requis. Il faut aussi une API key Scaleway autorisée à gérer le projet (réseau, Kapsule, SFS, Object Storage, Secret Manager) et les ressources IAM de l'application Nextflow. Pour ce POC dédié, demandez les permission sets **AllProductsFullAccess** sur le projet et **IAMApplicationManager** (ou **IAMManager**) pour créer l'application, sa clé et sa politique; réduisez ces droits avant la production. Voir la [documentation IAM Scaleway](https://www.scaleway.com/en/docs/iam/credentials/create-api-keys/). L'opérateur doit pouvoir lire le secret de pipeline.

Utilisez le profil local créé par `scw login` pour le déploiement. Si `SCW_SECRET_KEY` est exportée, `scw k8s kubeconfig install` l'inscrit dans le kubeconfig.

Pour le premier déploiement, préparez un bucket S3 privé et versionné pour l'état Terraform, ainsi que ses identifiants S3 (AWS_ACCESS_KEY_ID et AWS_SECRET_ACCESS_KEY). Placez ce bucket dans un **projet Scaleway distinct** du projet Nextflow : l'identité du pipeline possède des droits Object Storage à l'échelle de son projet.

Dans la console Scaleway, vérifiez les [quotas de l'organisation](https://www.scaleway.com/en/docs/organizations-and-projects/organization/organization-quotas/) et les disponibilités en fr-par-3 (et fr-par-2 pour le pool GEN3) : nœuds des types configurés, CPU/RAM, Kapsule, volumes SFS de 200 et 50 Go, buckets Object Storage et objets IAM/Secrets. Les quotas varient selon l'organisation; demandez leur augmentation avant le déploiement si nécessaire. Renseignez l'UUID de l'opérateur dans operator_user_id.

## Configuration et déploiement

Copiez les exemples de configuration :

```bash
cp terraform/infra/backend.hcl.example terraform/infra/backend.hcl
cp terraform/kubernetes/backend.hcl.example terraform/kubernetes/backend.hcl
cp terraform/infra/terraform.tfvars.example terraform/infra/terraform.tfvars
cp terraform/kubernetes/terraform.tfvars.example terraform/kubernetes/terraform.tfvars
```

Dans les deux backend.hcl, mettez le nom du même bucket d'état. Dans terraform/infra/terraform.tfvars, indiquez le Project UUID cible et l'UUID utilisateur operator_user_id. Ajustez les types et tailles dans ce fichier si besoin. Ne commitez ni ces fichiers générés, ni vos clés. L'état Terraform infra contient la clé IAM du pipeline : limitez l'accès au bucket d'état et à ses anciennes versions.

Un administrateur du projet d'état crée **une seule fois** son bucket privé et versionné, dans un projet différent de `scw_project_id` :

```bash
scw object bucket create mon-bucket-etat enable-versioning=true acl=private project-id=UUID_PROJET_ETAT region=fr-par
```

Chaque opérateur charge ses propres identifiants S3 autorisés sur ce bucket avant Terraform :

```bash
export AWS_ACCESS_KEY_ID="CLE_ETAT"
export AWS_SECRET_ACCESS_KEY="SECRET_ETAT"
```

Le premier plan vérifie l'infrastructure Scaleway. Examinez-le puis déployez :

```bash
make plan
make deploy
```

Le déploiement crée les buckets, le réseau, Kapsule, les pools, SFS, l'identité de pipeline, le namespace, les PVC et le secret Kubernetes. Terraform affiche et demande confirmation pour chacun des deux plans, infrastructure puis Kubernetes.

## Lancer un run synthétique, puis vos données

Le dépôt ne génère pas de FASTQ. Utilisez un jeu synthétique fourni par votre équipe ou votre outil de simulation, puis répétez les étapes avec les échantillons réels. Chaque run a son propre identifiant et son propre préfixe S3.

Préparez une samplesheet nf-core/rnaseq et déposez-la avec les FASTQ dans le bucket d'entrée, sous validation/<run-id>/. Le CSV doit référencer les FASTQ par URI s3:// :

```csv
sample,fastq_1,fastq_2,strandedness
patient_001,s3://BUCKET/validation/synthetic-001/patient_001_R1.fastq.gz,s3://BUCKET/validation/synthetic-001/patient_001_R2.fastq.gz,unstranded
```

Récupérez le nom du bucket avec `make outputs`. Pour les uploads, utilisez les identifiants de l'application dans un sous-shell : les identifiants du state restent ainsi actifs pour `make run`.

```bash
SECRET_ID=$(terraform -chdir=terraform/infra output -raw pipeline_credentials_secret_id)
SECRET_REVISION=$(terraform -chdir=terraform/infra output -raw pipeline_credentials_revision)
(
set -e
SECRET=$(scw secret version access "$SECRET_ID" revision="$SECRET_REVISION" region=fr-par raw=true)
AWS_ACCESS_KEY_ID=$(jq -er '.access_key' <<<"$SECRET")
AWS_SECRET_ACCESS_KEY=$(jq -er '.secret_key' <<<"$SECRET")
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=fr-par
unset SECRET
aws --endpoint-url https://s3.fr-par.scw.cloud s3 cp patient_001_R1.fastq.gz s3://BUCKET/validation/synthetic-001/
aws --endpoint-url https://s3.fr-par.scw.cloud s3 cp patient_001_R2.fastq.gz s3://BUCKET/validation/synthetic-001/
aws --endpoint-url https://s3.fr-par.scw.cloud s3 cp samplesheet.csv s3://BUCKET/validation/synthetic-001/
)
```

Remplacez `BUCKET` par le nom du bucket d'entrée. La policy de l'application autorise l'écriture sous `validation/`. Vous pouvez aussi utiliser la console Object Storage. Lancez ensuite :

```bash
make run RUN_ID=synthetic-001 INPUT=s3://BUCKET/validation/synthetic-001/samplesheet.csv
```

make run vérifie la référence GRCh38 sur SFS (et l'installe si nécessaire), puis attend la fin du pipeline. La commande échoue si Nextflow retourne une erreur. Contrôlez le rapport MultiQC et les fichiers de sortie, puis lancez les données réelles avec une nouvelle samplesheet :

```bash
make run RUN_ID=real-001 INPUT=s3://BUCKET/validation/real-001/samplesheet.csv
```

Les ressources par processus se règlent dans nextflow/nextflow.config; les paramètres, notamment la référence, dans nextflow/params.yaml. Pour reprendre un run échoué, vérifiez ses entrées et son workdir SFS puis gardez le même identifiant :

```bash
make run RUN_ID=synthetic-001 INPUT=s3://BUCKET/validation/synthetic-001/samplesheet.csv RESUME=1
make status
kubectl logs -n bioinformatics -f job/nextflow-synthetic-001
```

Par défaut, les BAM intermédiaires ne sont pas conservés pour limiter stockage et transferts. Pour les garder, ajoutez SAVE_ALIGN_INTERMEDS=true à make run.

Pour tester les pods STAR sur le pool MEMORY3 et son NVMe /scratch, après avoir vérifié le montage du nouveau nœud :

```bash
make run RUN_ID=scratch-001 INPUT=s3://BUCKET/validation/scratch-001/samplesheet.csv GEN3_SCRATCH_BENCHMARK=1
```

## Essai observé le 29 septembre 2026

Le test `smoke-simplified-20260929` a tourné sur le cluster **déjà créé** du projet `hcl-nextflow`, en `fr-par-3`. `make deploy` a réconcilié Terraform et Kubernetes sans changement d'infrastructure. Ce test ne mesure donc pas le temps d'un déploiement neuf. Lors de la création initiale, le cluster Kapsule est passé de « créé » à « prêt » le 25 septembre entre 13:39:25 et 13:41:47 UTC (2 min 22 s), sans que cela mesure l'installation complète.

Le jeu public [ENA SRR1039508](https://www.ebi.ac.uk/ena/browser/view/SRR1039508) contient ici **un échantillon humain RNA-seq**, réduit à **50 000 paires de lectures de 63 bases** : deux FASTQ compressés de 2 628 433 et 2 598 516 octets (5 226 949 octets au total), `unstranded`. La référence est **GRCh38 Ensembl 110**. Le pipeline a vérifié la référence SFS, généré l'index STAR, contrôlé et filtré les FASTQ, aligné les lectures avec STAR, quantifié avec Salmon et featureCounts, puis produit les contrôles qualité et MultiQC. Le run a utilisé les nœuds **POP2** et SFS; le pool GEN3/NVMe n'a pas participé à cet essai.

| Heure UTC | Étape observée | Résultat | Pool |
| --- | --- | --- | --- |
| 15:52:13–15:52:23 | Vérification de la référence déjà présente | Job terminé | orchestrator |
| 15:52:30 | Démarrage du Job Nextflow | Échantillon pris en charge | star-compute |
| ~16:08–18:46 | Génération de l'index STAR | Index disponible sur SFS | star-compute |
| 18:47:02–19:13:17 | STAR : chargement de l'index puis alignement | 46 597 / 49 539 paires alignées de façon unique (94,06 %) | star-compute |
| ~19:13–19:23 | Salmon, featureCounts, QC et publication | Sorties écrites dans Object Storage | star-compute |
| 19:23:47 | Fin du Job | `Complete`, pipeline réussi | star-compute |

**Durée du run : 3 h 31 min 17 s.** Après filtrage, 49 539 paires sont restées. featureCounts a affecté 43 428 fragments; Salmon a trouvé 10 029 transcrits avec une abondance non nulle. Le rapport MultiQC, le BAM, les quantifications et les logs sont présents dans `s3://hcl-public-netflow-results-1d6906b8/runs/smoke-simplified-20260929/` (389 objets, environ 557 Mo). Ces chiffres valident l'exécution technique sur un seul petit échantillon; ils ne définissent pas de seuil QC biologique. Les précédents essais ont donné 10 036 à 10 052 transcrits Salmon non nuls avec les mêmes comptes STAR/featureCounts : cet écart reste à expliquer avant de fixer une tolérance.

**Coût estimé du run : environ 4,9 € HT**, aux tarifs `fr-par-3` relevés lors du test :

| Ressource | Tarif | Durée retenue | Coût |
| --- | ---: | ---: | ---: |
| orchestrator POP2-4C-16G | 0,2205 €/h | 3 h 31 | ~0,78 € |
| 1er star-compute POP2-HM-8C-64G | 0,618 €/h | 3 h 31 | ~2,17 € |
| 2e star-compute POP2-HM-8C-64G | 0,618 €/h | ~2 h 50–53, retrait à 18:57:10 | ~1,75–1,78 € |
| SFS 250 Go | 0,000221 €/Go/h | 3 h 31 | ~0,19 € |

Le plan de contrôle Kapsule mutualisé est gratuit. Object Storage et les volumes système des nœuds ajoutent un faible coût non chiffré ici. Cette estimation porte sur la durée du Job, **pas sur la facture** : les nœuds et SFS existaient avant le test, et la facturation peut inclure une durée minimale. Après le run, orchestrator et SFS continuent à coûter environ 0,28 €/h tant qu'ils restent provisionnés. Voir les [tarifs Scaleway](https://www.scaleway.com/en/pricing/storage/) et [Kapsule](https://www.scaleway.com/en/pricing/containers/).

### Refaire le test

Dans le projet POC, la samplesheet et les FASTQ de l'essai sont déjà dans le bucket d'entrée. Après la configuration ci-dessus, utilisez un nouvel identifiant pour ne pas mélanger les sorties :

```bash
make plan
make deploy
INPUT_BUCKET=$(terraform -chdir=terraform/infra output -raw input_bucket_name)
RUN_ID="smoke-$(date -u +%Y%m%d-%H%M)"
make run RUN_ID="$RUN_ID" INPUT="s3://$INPUT_BUCKET/validation/validation-20260925/samplesheet.csv"
kubectl get job -n bioinformatics "nextflow-$RUN_ID"
kubectl logs -n bioinformatics "job/nextflow-$RUN_ID" | tail -n 3
```

Pour reproduire le jeu dans **votre propre projet**, ces commandes extraient les 50 000 premières paires depuis les FASTQ [ENA](https://www.ebi.ac.uk/ena/browser/view/SRR1039508). `head` arrête le téléchargement dès que le sous-jeu est complet; le nombre de lignes est vérifié pour chaque fichier.

```bash
for mate in 1 2; do
  curl -fsSL "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR103/008/SRR1039508/SRR1039508_${mate}.fastq.gz" 2>/dev/null \
    | gzip -dc | head -n 200000 | gzip -c > "SRR1039508_${mate}.fastq.gz"
  test "$(gzip -dc "SRR1039508_${mate}.fastq.gz" | wc -l)" -eq 200000
done
```

Créez la samplesheet, versez les fichiers avec les identifiants de l'application, puis lancez le Job. Les identifiants du backend Terraform restent dans le shell principal :

```bash
INPUT_BUCKET=$(terraform -chdir=terraform/infra output -raw input_bucket_name)
PREFIX=validation/ena-50k
printf 'sample,fastq_1,fastq_2,strandedness\nSRR1039508,s3://%s/%s/SRR1039508_1.fastq.gz,s3://%s/%s/SRR1039508_2.fastq.gz,unstranded\n' \
  "$INPUT_BUCKET" "$PREFIX" "$INPUT_BUCKET" "$PREFIX" > samplesheet.csv
SECRET_ID=$(terraform -chdir=terraform/infra output -raw pipeline_credentials_secret_id)
SECRET_REVISION=$(terraform -chdir=terraform/infra output -raw pipeline_credentials_revision)
(
  set -e
  SECRET=$(scw secret version access "$SECRET_ID" revision="$SECRET_REVISION" region=fr-par raw=true)
  AWS_ACCESS_KEY_ID=$(jq -er '.access_key' <<<"$SECRET")
  AWS_SECRET_ACCESS_KEY=$(jq -er '.secret_key' <<<"$SECRET")
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  unset SECRET
  for file in SRR1039508_1.fastq.gz SRR1039508_2.fastq.gz samplesheet.csv; do
    aws --endpoint-url https://s3.fr-par.scw.cloud --region fr-par s3 cp "$file" "s3://$INPUT_BUCKET/$PREFIX/"
  done
)
RUN_ID="smoke-$(date -u +%Y%m%d-%H%M)"
make run RUN_ID="$RUN_ID" INPUT="s3://$INPUT_BUCKET/$PREFIX/samplesheet.csv"
```

Si le terminal perd la connexion pendant l'attente, vérifiez le Job avec `kubectl get job -n bioinformatics "nextflow-$RUN_ID"` avant toute relance; le Job peut continuer dans Kapsule. Contrôlez le rapport `multiqc/star_salmon/multiqc_report.html` dans le bucket de résultats indiqué par `make outputs`.

## Nettoyage et limites

Avant make destroy, arrêtez les jobs et sauvegardez les données S3/SFS à garder. Le bucket d'état reste en place. destroy demande confirmation.

Le dépôt valide le parcours POC sur un petit jeu; il ne qualifie pas encore le dimensionnement production, une restauration complète ni les seuils biologiques. Les constats et corrections des incidents de reprise sont dans [Exploitation](docs/OPERATIONS.md); mesures et limites de performance dans [Préparation production](docs/PRODUCTION-READINESS.md).
