# Temporary one-node probe for MEMORY3 scratch-device discovery. Keep the
# NoSchedule taint so normal pipeline pods cannot land on this test node.
resource "scaleway_k8s_pool" "gen3_probe" {
  cluster_id       = scaleway_k8s_cluster.main.id
  version          = scaleway_k8s_cluster.main.version
  name             = "gen3-probe"
  node_type        = "MEMORY3-X8C-64G"
  size             = 1
  min_size         = 1
  max_size         = 1
  autoscaling      = false
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
}
