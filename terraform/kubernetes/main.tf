terraform {
  required_version = ">= 1.11.0"

  backend "s3" {}

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37.0"
    }
  }
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}
