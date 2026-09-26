resource "scaleway_iam_application" "pipeline" {
  name        = "${var.cluster_name}-pipeline"
  description = "nf-core/rnaseq S3 identity; object permissions are scoped to the dedicated project"
  tags        = var.tags
}

resource "scaleway_iam_api_key" "pipeline" {
  application_id     = scaleway_iam_application.pipeline.id
  default_project_id = var.scw_project_id
  description        = "Nextflow pipeline access to input and results buckets"
  expires_at         = var.pipeline_api_key_expires_at
}

# Scaleway grants Object Storage IAM permission sets at project scope. The
# bucket policies below further constrain this application to reading the
# input bucket and reading/writing the results bucket. Keep this project
# dedicated to this deployment: the IAM permission sets themselves are not
# scoped to individual buckets.
resource "scaleway_iam_policy" "pipeline_object_storage" {
  name           = "${var.cluster_name}-pipeline-object-storage"
  description    = "Object Storage object read/write permissions for Nextflow in the dedicated project"
  application_id = scaleway_iam_application.pipeline.id
  tags           = var.tags

  rule {
    project_ids = [var.scw_project_id]
    permission_set_names = [
      "ObjectStorageObjectsRead",
      "ObjectStorageObjectsWrite",
    ]
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
