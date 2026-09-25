variable "scw_project_id" {
  description = "Scaleway Project UUID. Credentials come from SCW_ACCESS_KEY and SCW_SECRET_KEY."
  type        = string
}

variable "operator_user_id" {
  description = "Scaleway user UUID allowed to read metadata from the input and results buckets."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.operator_user_id))
    error_message = "operator_user_id must be a Scaleway user UUID."
  }
}

variable "cluster_name" {
  description = "Resource name prefix; also used to derive globally unique bucket names."
  type        = string
  default     = "hcl-public-netflow"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3-32 lowercase letters, digits, or hyphens, with alphanumeric ends."
  }
}

variable "scaleway_region" {
  description = "Scaleway region for Kapsule, File Storage, Secret Manager, and Object Storage."
  type        = string
  default     = "fr-par"
}

variable "scaleway_zone" {
  description = "Availability zone for Kapsule node pools."
  type        = string
  default     = "fr-par-3"
}

variable "k8s_version" {
  description = "Pinned Kapsule version. This deployment intentionally targets 1.37.0."
  type        = string
  default     = "1.37.0"

  validation {
    condition     = var.k8s_version == "1.37.0"
    error_message = "This repository currently supports Kapsule 1.37.0 only."
  }
}

variable "vpc_cidr" {
  description = "IPv4 subnet allocated to the cluster Private Network."
  type        = string
  default     = "172.16.8.0/22"
}

variable "orchestrator_node_type" {
  description = "POP2 node hosting Nextflow's driver and light tasks."
  type        = string
  default     = "POP2-4C-16G"
}

variable "orchestrator_max_nodes" {
  description = "Autoscaler ceiling for light pipeline tasks. Increase for production throughput."
  type        = number
  default     = 2

  validation {
    condition     = var.orchestrator_max_nodes >= 1 && var.orchestrator_max_nodes <= 20
    error_message = "orchestrator_max_nodes must be between 1 and 20."
  }
}

variable "compute_node_type" {
  description = "High-memory POP2 node for STAR and other memory-intensive tasks (8 vCPU / 64 GB)."
  type        = string
  default     = "POP2-HM-8C-64G"
}

variable "compute_max_nodes" {
  description = "Autoscaler ceiling for high-memory pipeline tasks. Increase for production throughput."
  type        = number
  default     = 2

  validation {
    condition     = var.compute_max_nodes >= 1 && var.compute_max_nodes <= 20
    error_message = "compute_max_nodes must be between 1 and 20."
  }
}

variable "workdir_size_gb" {
  description = "SFS RWX capacity for Nextflow work files. Set to about 2000 GB for production throughput."
  type        = number
  default     = 200

  validation {
    condition     = var.workdir_size_gb >= 25 && var.workdir_size_gb <= 50000
    error_message = "workdir_size_gb must be between 25 and 50000."
  }
}

variable "reference_size_gb" {
  description = "SFS RWX capacity for the reference genome and annotation files."
  type        = number
  default     = 50

  validation {
    condition     = var.reference_size_gb >= 25 && var.reference_size_gb <= 50000
    error_message = "reference_size_gb must be between 25 and 50000."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days before superseded S3 object versions are removed. Current versions are retained indefinitely."
  type        = number
  default     = 365

  validation {
    condition     = var.noncurrent_version_retention_days >= 30 && var.noncurrent_version_retention_days <= 3650
    error_message = "noncurrent_version_retention_days must be between 30 and 3650."
  }
}

variable "pipeline_api_key_expires_at" {
  description = "Optional RFC3339 expiration for the pipeline API key. Set and rotate deliberately."
  type        = string
  default     = null
  nullable    = true
}

variable "pipeline_secret_revision" {
  description = "Increment to publish a new write-only Secret Manager version after credential rotation."
  type        = number
  default     = 1

  validation {
    condition     = var.pipeline_secret_revision >= 1 && floor(var.pipeline_secret_revision) == var.pipeline_secret_revision
    error_message = "pipeline_secret_revision must be a positive integer."
  }
}

variable "tags" {
  description = "Tags applied to Scaleway resources."
  type        = list(string)
  default     = ["env=poc", "project=hcl-public-netflow", "pipeline=nf-core-rnaseq"]
}
