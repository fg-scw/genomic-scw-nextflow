output "namespace" {
  description = "Namespace containing Nextflow resources."
  value       = kubernetes_namespace.bioinformatics.metadata[0].name
}

output "workdir_pvc" {
  description = "SFS RWX PVC used as the Nextflow work directory."
  value       = kubernetes_persistent_volume_claim.workdir.metadata[0].name
}

output "reference_pvc" {
  description = "SFS RWX PVC reserved for genome references."
  value       = kubernetes_persistent_volume_claim.reference.metadata[0].name
}
