// ----------------------------------------------------------------------------
// Create and configure the Kubernetes cluster
//
// https://www.terraform.io/docs/providers/google/r/container_cluster.html
// ----------------------------------------------------------------------------
locals {
  cluster_oauth_scopes = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/compute",
    "https://www.googleapis.com/auth/devstorage.full_control",
    "https://www.googleapis.com/auth/service.management",
    "https://www.googleapis.com/auth/servicecontrol",
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring",
  ]
  master_authorized_networks_config = length(var.master_authorized_networks) == 0 ? [] : [{
    cidr_blocks : var.master_authorized_networks
  }]
  enable_private_cluster_config = (var.enable_private_nodes || var.enable_private_endpoint) ? true : false
  enable_vpc_native             = (var.ip_range_pods != "" || var.ip_range_services != "") ? true : false
}

resource "google_container_cluster" "jx_cluster" {
//  provider                  = google-beta
  provider                  = google
  name                      = var.cluster_name
  description               = "jenkins-x cluster"
  location                  = var.cluster_location
  network                   = var.cluster_network
  subnetwork                = var.cluster_subnetwork
  enable_kubernetes_alpha   = var.enable_kubernetes_alpha
  enable_legacy_abac        = var.enable_legacy_abac
  enable_shielded_nodes     = var.enable_shielded_nodes
  initial_node_count        = var.min_node_count
  logging_service           = var.logging_service
  monitoring_service        = var.monitoring_service
  default_max_pods_per_node = var.max_pods_per_node
  node_version              = "1.21.11-gke.1100"

  dynamic "private_cluster_config" {
    for_each = local.enable_private_cluster_config ? [{
      enable_private_nodes    = var.enable_private_nodes
      enable_private_endpoint = var.enable_private_endpoint
      master_ipv4_cidr_block  = var.master_ipv4_cidr_block
    }] : []

    content {
      enable_private_endpoint = private_cluster_config.value.enable_private_endpoint
      enable_private_nodes    = private_cluster_config.value.enable_private_nodes
      master_ipv4_cidr_block  = private_cluster_config.value.master_ipv4_cidr_block
    }
  }

  dynamic "master_authorized_networks_config" {
    for_each = local.master_authorized_networks_config
    content {
      dynamic "cidr_blocks" {
        for_each = master_authorized_networks_config.value.cidr_blocks
        content {
          cidr_block   = lookup(cidr_blocks.value, "cidr_block", "")
          display_name = lookup(cidr_blocks.value, "display_name", "")
        }
      }
    }
  }

  dynamic "ip_allocation_policy" {
    for_each = local.enable_vpc_native ? [{
      ip_range_pods     = var.ip_range_pods
      ip_range_services = var.ip_range_services
    }] : []

    content {
      cluster_ipv4_cidr_block  = ip_allocation_policy.value.ip_range_pods
      services_ipv4_cidr_block = ip_allocation_policy.value.ip_range_services
    }
  }

  // should disable master auth
  master_auth {
    username = ""
    password = ""
  }

  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }

  release_channel {
    channel = var.release_channel
  }

  workload_identity_config {
    identity_namespace = "${var.gcp_project}.svc.id.goog"
  }

  resource_labels = var.resource_labels

  cluster_autoscaling {
    enabled = true

    auto_provisioning_defaults {
      oauth_scopes = local.cluster_oauth_scopes
    }

    resource_limits {
      resource_type = "cpu"
      minimum       = ceil(var.min_node_count * var.machine_types_cpu[var.node_machine_type])
      maximum       = ceil(var.max_node_count * var.machine_types_cpu[var.node_machine_type])
    }

    resource_limits {
      resource_type = "memory"
      minimum       = ceil(var.min_node_count * var.machine_types_memory[var.node_machine_type])
      maximum       = ceil(var.max_node_count * var.machine_types_memory[var.node_machine_type])
    }
  }

  node_config {
    preemptible  = var.node_preemptible
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size
    disk_type    = var.node_disk_type

    oauth_scopes = local.cluster_oauth_scopes

    workload_metadata_config {
      node_metadata = "GKE_METADATA_SERVER"
    }

    tags = [var.cluster_name]

  }
}

module "jx-health" {
  count  = var.jx2 && var.kuberhealthy ? 0 : 1
  source = "github.com/jenkins-x/terraform-jx-health?ref=main"
//  source = "github.com/cryptocurrency-services/terraform-jx-health"

  depends_on = [
    google_container_cluster.jx_cluster
  ]
}

// ----------------------------------------------------------------------------
// Add main Jenkins X Kubernetes namespace
//
// https://www.terraform.io/docs/providers/kubernetes/r/namespace.html
// ----------------------------------------------------------------------------
resource "kubernetes_namespace" "jenkins_x_namespace" {
  count = var.jx2 ? 1 : 0
  metadata {
    name = var.jenkins_x_namespace
  }
  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
  depends_on = [
    google_container_cluster.jx_cluster
  ]
}

// ----------------------------------------------------------------------------
// Add the Terraform generated jx-requirements.yml to a configmap so it can be
// sync'd with the Git repository
//
// https://www.terraform.io/docs/providers/kubernetes/r/namespace.html
// ----------------------------------------------------------------------------
resource "kubernetes_config_map" "jenkins_x_requirements" {
  count = var.jx2 ? 0 : 1
  metadata {
    name      = "terraform-jx-requirements"
    namespace = "default"
  }
  data = {
    "jx-requirements.yml" = var.content
  }
  depends_on = [
    google_container_cluster.jx_cluster
  ]
}

resource "helm_release" "jx-git-operator" {
  count = var.jx2 || var.jx_git_url == "" ? 0 : 1

  provider         = helm
  name             = "jx-git-operator"
  chart            = "jx-git-operator"
  namespace        = "jx-git-operator"
  repository       = "https://jenkins-x-charts.github.io/repo"
  version          = var.jx_git_operator_version
  create_namespace = true

  set {
    name  = "bootServiceAccount.enabled"
    value = true
  }
  set {
    name  = "bootServiceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
    value = "${var.cluster_name}-boot@${var.gcp_project}.iam.gserviceaccount.com"
  }
  set {
    name  = "env.NO_RESOURCE_APPLY"
    value = true
  }
  set {
    name  = "url"
    value = var.jx_git_url
  }
  set {
    name  = "username"
    value = var.jx_bot_username
  }
  set {
    name  = "password"
    value = var.jx_bot_token
  }

  lifecycle {
    ignore_changes = all
  }
  depends_on = [
    google_container_cluster.jx_cluster
  ]
}
