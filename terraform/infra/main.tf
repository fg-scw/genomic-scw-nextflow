terraform {
  required_version = ">= 1.11.0"

  backend "s3" {}

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.83.0"
    }
  }
}

provider "scaleway" {
  project_id = var.scw_project_id
  region     = var.scaleway_region
  zone       = var.scaleway_zone
}

# This read fails during plan if the requested Kapsule version is not available
# in the selected region. It also provides a precondition input for the cluster.
data "scaleway_k8s_version" "requested" {
  name   = var.k8s_version
  region = var.scaleway_region
}
