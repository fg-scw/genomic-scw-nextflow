resource "kubernetes_namespace" "bioinformatics" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "nf-core-rnaseq"
    }
  }
}

resource "kubernetes_service_account" "nextflow" {
  metadata {
    name      = "nextflow"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
}

# Nextflow only manages task pods and reads their logs/events in this namespace.
resource "kubernetes_role" "nextflow_pod_manager" {
  metadata {
    name      = "nextflow-pod-manager"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "nextflow" {
  metadata {
    name      = "nextflow-pod-manager"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.nextflow_pod_manager.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.nextflow.metadata[0].name
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }
}

resource "kubernetes_persistent_volume_claim" "workdir" {
  metadata {
    name      = "nf-workdir-pvc"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "sfs-standard"

    resources {
      requests = { storage = "${var.workdir_size_gb}G" }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim" "reference" {
  metadata {
    name      = "nf-reference-pvc"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "sfs-standard"

    resources {
      requests = { storage = "${var.reference_size_gb}G" }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_config_map" "nextflow_config" {
  metadata {
    name      = "nextflow-config"
    namespace = kubernetes_namespace.bioinformatics.metadata[0].name
  }

  data = {
    "nextflow.config" = file("${path.module}/../../nextflow/nextflow.config")
  }
}
