resource "scaleway_iam_application" "pipeline" {
  name        = "${var.cluster_name}-pipeline"
  description = "nf-core/rnaseq S3 identity; Object Storage IAM permissions are project-scoped"
  tags        = var.tags
}

resource "scaleway_iam_api_key" "pipeline" {
  application_id     = scaleway_iam_application.pipeline.id
  default_project_id = var.scw_project_id
  description        = "Nextflow pipeline access to input and results buckets"
  expires_at         = var.pipeline_api_key_expires_at
}

# This intentionally grants bucket metadata access only. Scaleway's S3
# authorization requires compatible project-level IAM permissions in addition
# to bucket policies. Do not expand this policy in a shared project without
# reviewing the project-wide impact; validate application S3 actions live.
resource "scaleway_iam_policy" "pipeline_object_storage" {
  name           = "${var.cluster_name}-pipeline-object-storage"
  description    = "Object Storage bucket metadata access for pipeline"
  application_id = scaleway_iam_application.pipeline.id
  tags           = var.tags

  rule {
    project_ids          = [var.scw_project_id]
    permission_set_names = ["ObjectStorageBucketsRead"]
  }
}

resource "scaleway_secret" "pipeline_credentials" {
  name        = "${var.cluster_name}-pipeline-s3-credentials"
  path        = "/nf-rnaseq"
  description = "Nextflow S3 credentials, synced into the bioinformatics namespace after K8s apply"
  type        = "key_value"
  project_id  = var.scw_project_id
  region      = var.scaleway_region
  tags        = var.tags
}

resource "scaleway_secret_version" "pipeline_credentials" {
  secret_id       = scaleway_secret.pipeline_credentials.id
  region          = var.scaleway_region
  data_wo_version = var.pipeline_secret_revision
  data_wo = jsonencode({
    access_key     = scaleway_iam_api_key.pipeline.access_key
    secret_key     = scaleway_iam_api_key.pipeline.secret_key
    region         = var.scaleway_region
    s3_endpoint    = "https://s3.${var.scaleway_region}.scw.cloud"
    input_bucket   = scaleway_object_bucket.data["input"].name
    results_bucket = scaleway_object_bucket.data["results"].name
  })
}
