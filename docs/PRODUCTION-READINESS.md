# État de préparation à la production

## Position actuelle

Ce dépôt automatise un parcours de validation sur Scaleway Kapsule : infrastructure Terraform, ressources Kubernetes, préparation d'une petite entrée RNA-seq humaine, exécution de `nf-core/rnaseq` et contrôle des principaux artefacts. Un run de validation réussi prouve le fonctionnement de ce parcours sur le jeu de démonstration. Il ne qualifie pas à lui seul la solution pour traiter des données cliniques ou un run NovaSeq de plusieurs centaines d'échantillons.

Ne considérer le service comme prêt pour la production qu'après les contrôles de cette page, sur les tailles, volumes de données, règles de sécurité et objectifs de reprise effectivement visés.

## Contrôles avant données de production

- [ ] **État Terraform** : backend S3 distant séparé du state applicatif, versioning activé, `use_lockfile=true`, accès limité aux opérateurs et à la CI nécessaires. Vérifier les permissions Get/Put/Delete sur les objets `.tflock`, sauvegarder et tester la restauration de l'objet state. Comme les permissions Object Storage IAM Scaleway sont au niveau projet, isoler le backend dans un projet distinct ou établir des protections explicites pour les autres buckets.
- [ ] **Secrets** : clés Scaleway, clés S3, kubeconfig et state absents de Git et des journaux CI. Rotation testée. L'accès aux versions de secrets Scaleway et aux Secrets Kubernetes est restreint et audité.
- [ ] **Données** : buckets d'entrée et de résultats privés, chiffrement et politiques de rétention définis. Définir où vivent les FASTQ, BAM et rapports et qui peut les lire. La policy autorise le dépôt des données de validation sous `validation/*` dans le bucket d'entrée; vérifier les besoins avant d'y déposer des données supplémentaires.
- [ ] **Isolation IAM** : Scaleway Object Storage accorde les actions S3 à l'échelle du projet. La solution utilise le projet dédié `hcl-nextflow`; vérifier que ce projet ne contient pas de buckets ou données sans rapport avec le pipeline, car les droits de l'identité couvrent son périmètre de projet.
- [ ] **Réseau et cluster** : contrôler les règles d'accès à l'API Kubernetes, les Private Networks, la sortie Internet requise pour les images et les références, et les quotas Scaleway dans la région cible.
- [ ] **Capacité** : exécuter un benchmark avec les plus gros échantillons représentatifs. Mesurer le pic RAM/CPU, stockage temporaire, capacité et débit SFS, durée, coûts et comportement de l'autoscaler. Confirmer que les tâches STAR peuvent être planifiées avec leur demande mémoire réelle.
- [ ] **Intégrité scientifique** : figer les versions du pipeline, des conteneurs et des références GRCh38/GTF; consigner leurs checksums et paramètres. Faire valider les métriques d'alignement et MultiQC par le responsable bioinformatique.
- [ ] **Reprise** : provoquer l'interruption d'un run, reprendre avec le même identifiant et le même workdir, puis vérifier les artefacts réutilisés. N'utiliser `--resume` que lorsque ce workdir et ses résultats intermédiaires sont intègres.
- [ ] **Observabilité** : définir la conservation des logs Nextflow et Kubernetes, les alertes sur échec, OOM, volumes presque pleins, erreurs d'accès S3 et coûts inattendus.
- [ ] **Récupération** : exercer la restauration des objets, références, PVC et state Terraform dans un environnement isolé. Documenter le RTO/RPO et les responsables d'astreinte.
- [ ] **Cycle de vie** : suivre les versions Kubernetes et Terraform/providers supportées, avec une fenêtre de mise à jour et un rollback testé.

## Limites connues du parcours de démonstration

- Le dataset de démonstration est petit et sert à vérifier le flux humain bout à bout. Il ne simule pas un run complet de 300–400 échantillons ni 2,2 To de FASTQ.
- La génération ou le chargement de la référence est une étape séparée et coûteuse en temps et stockage. Les références doivent être versionnées et validées avant les runs métier.
- Le state Terraform protège l'accès à l'infrastructure mais n'est pas un coffre à secrets : les valeurs sensibles qui sont stockées dans les ressources du provider Scaleway peuvent s'y trouver. Le state distant doit donc être privé, chiffré, versionné et protégé par IAM.
- L'identité S3 générée par Terraform reçoit `ObjectStorageObjectsRead` et `ObjectStorageObjectsWrite` dans le projet dédié `hcl-nextflow`. Les bucket policies limitent ses opérations attendues : lecture de l'entrée, dépôt des FASTQ de validation sous `validation/*`, et lecture/écriture des résultats. L'identité du backend a aussi `ObjectStorageBucketsRead`, `ObjectStorageObjectsRead`, `ObjectStorageObjectsWrite` et `ObjectStorageObjectsDelete`, notamment pour la gestion des verrous Terraform. Ces permissions IAM sont attribuées à l'échelle du projet, sans être restreintes aux seuls buckets concernés; ne pas y héberger de données sans rapport. Pour la production, placer le backend dans un projet isolé ou appliquer des protections explicites aux autres buckets. La permission est configurée mais le run e2e doit encore être exécuté dans le compte cible avant d'être considéré comme validé.
- Les données intermédiaires sur SFS et les résultats S3 ont des cycles de vie distincts. La destruction du cluster et des PVC peut supprimer les données de travail; elle ne doit pas servir de politique de purge des résultats.
- Les valeurs par défaut de pools et de PVC sont destinées à un pilote. Ajuster taille, concurrence et quotas après benchmark et revue de coût.

## Option de benchmark : scratch NVMe local

Les instances Scaleway GEN3 MEMORY exposent un NVMe local éphémère qui peut être évalué pour les tâches STAR ou autres tâches sensibles aux I/O. Ce dépôt ne l'active pas dans le pilote : `scratch=true` seul ne sélectionne pas le NVMe et ne monte aucun volume. Il faut configurer explicitement un volume et son chemin de montage dans les pods de tâches, puis s'assurer que ces pods sont planifiés sur les nœuds GEN3 MEMORY qui fournissent ce stockage.

Ce scratch est local au nœud, non partagé et non persistant : son contenu peut disparaître avec le pod ou le nœud et ne doit pas contenir les entrées, références ou sorties à conserver. Garder le workdir reprenable et les références partagées sur SFS, et les entrées/résultats durables sur S3. Comparer les performances STAR, la concurrence, le coût et le comportement en cas de rescheduling à un run équivalent utilisant le stockage du pilote avant toute adoption.

## Critère de passage

La revue de production doit contenir les journaux du run représentatif, les métriques de ressources et de coûts, les checksums des références et des sorties, le rapport QC approuvé, ainsi que le compte rendu d'un test de reprise et d'une restauration. Sans ces éléments, qualifier le déploiement de pilote validé, pas de plateforme prête pour la production.
