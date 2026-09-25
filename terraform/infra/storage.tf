locals {
  bucket_names = {
    input   = "${var.cluster_name}-input-${substr(var.scw_project_id, 0, 8)}"
    results = "${var.cluster_name}-results-${substr(var.scw_project_id, 0, 8)}"
  }
}

resource "scaleway_object_bucket" "data" {
  for_each = local.bucket_names

  name       = each.value
  region     = var.scaleway_region
  project_id = var.scw_project_id
  tags = {
    project = var.cluster_name
    purpose = each.key
  }

  # Never delete FASTQ or analysis results as a side effect of terraform destroy.
  # Versioning allows recovery; only old noncurrent versions and abandoned
  # multipart uploads are cleaned automatically.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    id                                     = "expire-noncurrent-versions"
    enabled                                = true
    abort_incomplete_multipart_upload_days = 7

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }
}

resource "scaleway_object_bucket_policy" "input_read" {
  bucket     = scaleway_object_bucket.data["input"].name
  project_id = var.scw_project_id

  policy = jsonencode({
    Version = "2023-04-17"
    Id      = "${var.cluster_name}-input-read"
    Statement = [{
      Sid       = "PipelineReadInput"
      Effect    = "Allow"
      Principal = { SCW = "application_id:${scaleway_iam_application.pipeline.id}" }
      Action    = ["s3:ListBucket", "s3:GetObject"]
      Resource  = [scaleway_object_bucket.data["input"].name, "${scaleway_object_bucket.data["input"].name}/*"]
    }]
  })
}

resource "scaleway_object_bucket_policy" "results_rw" {
  bucket     = scaleway_object_bucket.data["results"].name
  project_id = var.scw_project_id

  policy = jsonencode({
    Version = "2023-04-17"
    Id      = "${var.cluster_name}-results-rw"
    Statement = [{
      Sid       = "PipelineReadWriteResults"
      Effect    = "Allow"
      Principal = { SCW = "application_id:${scaleway_iam_application.pipeline.id}" }
      Action = [
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:ListMultipartUploadParts",
        "s3:GetObject",
        "s3:PutObject",
      ]
      Resource = [scaleway_object_bucket.data["results"].name, "${scaleway_object_bucket.data["results"].name}/*"]
    }]
  })
}
