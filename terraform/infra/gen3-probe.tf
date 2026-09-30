# Optional GEN3 scratch benchmark pool. Keep it idle between runs and isolated
# from normal pipeline pods; matching STAR pods trigger scale-up.
resource "scaleway_k8s_pool" "gen3_probe" {
  cluster_id       = scaleway_k8s_cluster.main.id
  version          = scaleway_k8s_cluster.main.version
  name             = "gen3-probe"
  node_type        = "MEMORY3-X8C-64G"
  size             = 1
  min_size         = 0
  max_size         = 1
  autoscaling      = true
  autohealing      = true
  region           = var.scaleway_region
  zone             = "fr-par-2"
  root_volume_type = "sbs_5k"
  tags             = concat(var.tags, ["role=gen3-probe", "scw-create-scratch-volume"])

  taints {
    key    = "workload"
    value  = "gen3-probe"
    effect = "NoSchedule"
  }

  lifecycle {
    ignore_changes = [size]
  }
}
