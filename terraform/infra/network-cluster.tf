resource "scaleway_vpc" "main" {
  name       = "${var.cluster_name}-vpc"
  region     = var.scaleway_region
  project_id = var.scw_project_id
  tags       = var.tags
}

resource "scaleway_vpc_private_network" "main" {
  name       = "${var.cluster_name}-pn"
  vpc_id     = scaleway_vpc.main.id
  region     = var.scaleway_region
  project_id = var.scw_project_id
  tags       = var.tags

  ipv4_subnet {
    subnet = var.vpc_cidr
  }
}

resource "scaleway_k8s_cluster" "main" {
  name                        = "${var.cluster_name}-kapsule"
  description                 = "Managed Kapsule 1.37 for nf-core/rnaseq"
  version                     = data.scaleway_k8s_version.requested.name
  cni                         = "cilium"
  region                      = var.scaleway_region
  project_id                  = var.scw_project_id
  private_network_id          = split("/", scaleway_vpc_private_network.main.id)[1]
  delete_additional_resources = false
  tags                        = concat(var.tags, ["scw-filestorage-csi"])

  auto_upgrade {
    enable                        = false
    maintenance_window_start_hour = 3
    maintenance_window_day        = "sunday"
  }

  autoscaler_config {
    estimator                     = "binpacking"
    expander                      = "least_waste"
    disable_scale_down            = false
    scale_down_delay_after_add    = "5m"
    scale_down_unneeded_time      = "10m"
    ignore_daemonsets_utilization = true
    skip_nodes_with_local_storage = false
  }

  lifecycle {
    precondition {
      condition     = contains(data.scaleway_k8s_version.requested.available_cnis, "cilium")
      error_message = "Kapsule ${var.k8s_version} in ${var.scaleway_region} does not offer Cilium."
    }
  }
}

resource "scaleway_k8s_pool" "orchestrator" {
  cluster_id  = scaleway_k8s_cluster.main.id
  version     = scaleway_k8s_cluster.main.version
  name        = "orchestrator"
  node_type   = var.orchestrator_node_type
  size        = 1
  min_size    = 1
  max_size    = var.orchestrator_max_nodes
  autoscaling = true
  autohealing = true
  region      = var.scaleway_region
  zone        = var.scaleway_zone
  tags        = concat(var.tags, ["role=orchestrator"])

  upgrade_policy {
    max_unavailable = 1
    max_surge       = 1
  }

  lifecycle {
    ignore_changes = [size]
  }
}

resource "scaleway_k8s_pool" "compute" {
  cluster_id  = scaleway_k8s_cluster.main.id
  version     = scaleway_k8s_cluster.main.version
  name        = "star-compute"
  node_type   = var.compute_node_type
  size        = 1
  min_size    = 0
  max_size    = var.compute_max_nodes
  autoscaling = true
  autohealing = true
  region      = var.scaleway_region
  zone        = var.scaleway_zone
  tags        = concat(var.tags, ["role=star-compute"])

  taints {
    key    = "workload"
    value  = "star-compute"
    effect = "NoSchedule"
  }

  upgrade_policy {
    max_unavailable = 1
    max_surge       = 0
  }

  # Kapsule requires size >= 1 when the pool is first created. The autoscaler
  # can scale this pool down to zero; Terraform must preserve that decision.
  lifecycle {
    ignore_changes = [size]
  }
}
