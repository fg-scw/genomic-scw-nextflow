variable "kubeconfig_path" {
  description = "Kubeconfig installed after the infrastructure phase."
  type        = string
  default     = "~/.kube/config-hcl-public-netflow"
}

variable "namespace" {
  description = "Namespace that contains the Nextflow driver and task pods."
  type        = string
  default     = "bioinformatics"
}

variable "workdir_size_gb" {
  description = "SFS capacity requested by nf-workdir-pvc; keep aligned with infra/terraform.tfvars."
  type        = number
  default     = 200

  validation {
    condition     = var.workdir_size_gb >= 25 && var.workdir_size_gb <= 50000
    error_message = "workdir_size_gb must be between 25 and 50000."
  }
}

variable "reference_size_gb" {
  description = "SFS capacity requested by nf-reference-pvc; keep aligned with infra/terraform.tfvars."
  type        = number
  default     = 50

  validation {
    condition     = var.reference_size_gb >= 25 && var.reference_size_gb <= 50000
    error_message = "reference_size_gb must be between 25 and 50000."
  }
}
