output "cluster_id" {
  description = "Raw Kapsule cluster UUID for `scw k8s kubeconfig install`."
  value       = split("/", scaleway_k8s_cluster.main.id)[1]
}

output "region" {
  description = "Scaleway region used by Kapsule, SFS, Secret Manager, and S3."
  value       = var.scaleway_region
}

output "input_bucket_name" {
  description = "Versioned S3 bucket for immutable or accessioned FASTQ inputs."
  value       = scaleway_object_bucket.data["input"].name
}

output "results_bucket_name" {
  description = "Versioned S3 bucket for pipeline outputs."
  value       = scaleway_object_bucket.data["results"].name
}

output "pipeline_credentials_secret_id" {
  description = "Secret Manager secret ID used by scripts/sync-k8s-secret.sh."
  value       = scaleway_secret.pipeline_credentials.id
}

output "pipeline_credentials_revision" {
  description = "Current Secret Manager revision for the pipeline credentials."
  value       = scaleway_secret_version.pipeline_credentials.revision
}

output "pipeline_iam_application_id" {
  description = "Dedicated IAM application ID for pipeline bucket policy principals."
  value       = scaleway_iam_application.pipeline.id
}

output "workdir_size_gb" {
  description = "Configured SFS work PVC capacity."
  value       = var.workdir_size_gb
}

output "reference_size_gb" {
  description = "Configured SFS reference PVC capacity."
  value       = var.reference_size_gb
}
