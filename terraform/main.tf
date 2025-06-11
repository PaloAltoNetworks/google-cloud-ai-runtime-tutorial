# -------------------------------------------------------------------------------------
# Locals
# -------------------------------------------------------------------------------------

locals {
  project_id               = var.gcp_project_id
  region                   = var.gcp_region
  zone                     = var.gcp_zone
  airs_name                = "airs-${substr(random_string.main.result, 0, 4)}"
  ai_vm_image              = "https://www.googleapis.com/compute/v1/projects/ql-hosting-10131989/global/images/x705972644-ai-app-v2"
  openai_api_key           = var.openai_api_key
  allowed_ips              = var.allowed_ips
  gce_subnet_name          = "gce-vpc-${local.region}-subnet"
  gce_subnet_cidr          = "10.1.0.0/24"
  gke_subnet_name          = "gke-vpc-${local.region}-subnet"
  gke_subnet_cidr          = "10.10.0.0/24"
  gke_subnet_cidr_cluster  = "10.20.0.0/16"
  gke_subnet_cidr_services = "10.30.0.0/16"
  gke_cluster_name         = "cluster1"
  gke_version              = "1.30"
  gke_secondary_ranges     = flatten(module.vpc_gke[*].subnets_secondary_ranges)
}

# -------------------------------------------------------------------------------------
# Provider
# -------------------------------------------------------------------------------------

terraform {

  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

provider "google" {
  project = local.project_id
  region  = local.region
  zone    = local.zone
}

# -------------------------------------------------------------------------------------
# Create GSC bucket & log router for VPC flow logs
# -------------------------------------------------------------------------------------

resource "random_string" "main" {
  length      = 16
  min_lower   = 8
  min_numeric = 8
  special     = false
}

resource "google_storage_bucket" "gcs" {
  name          = "flow-logs-${random_string.main.result}"
  location      = "US"
  force_destroy = true
}

resource "google_logging_project_sink" "log_router" {
  name                   = "flow-logs-sink"
  destination            = "storage.googleapis.com/${google_storage_bucket.gcs.name}"
  filter                 = "(logName =~ \"logs/cloudaudit.googleapis.com%2Fdata_access\" AND protoPayload.methodName:(\"google.cloud.aiplatform.\")) OR ((logName=\"projects/${local.project_id}/logs/compute.googleapis.com%2Fvpc_flows\"))"
  unique_writer_identity = true

  depends_on = [
    google_storage_bucket.gcs
  ]
}

resource "google_project_iam_binding" "gcs-bucket-writer" {
  project = local.project_id
  role    = "roles/storage.objectCreator"

  members = [
    google_logging_project_sink.log_router.writer_identity
  ]
}

resource "google_project_iam_audit_config" "all_services" {
  project = local.project_id
  service = "allServices"
  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}


resource "google_project_iam_audit_config" "ai_platform" {
  project = local.project_id
  service = "aiplatform.googleapis.com"
  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}


# -------------------------------------------------------------------------------------
# Create VPCs
# -------------------------------------------------------------------------------------

module "vpc_gke" {
  source       = "terraform-google-modules/network/google"
  version      = "~> 4.0"
  project_id   = local.project_id
  network_name = "gke-vpc"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name               = local.gke_subnet_name
      subnet_ip                 = local.gke_subnet_cidr
      subnet_region             = local.region
      subnet_flow_logs          = "true"
      subnet_flow_logs_interval = "INTERVAL_5_SEC"
      subnet_flow_logs_sampling = 1.0
      subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
    }
  ]

  secondary_ranges = {
    (local.gke_subnet_name) = [
      {
        range_name    = "${local.gke_subnet_name}-cluster"
        ip_cidr_range = local.gke_subnet_cidr_cluster
      },
      {
        range_name    = "${local.gke_subnet_name}-services"
        ip_cidr_range = local.gke_subnet_cidr_services
      }
    ]
  }

  firewall_rules = [
    {
      name      = "gke-vpc-ingress-public"
      direction = "INGRESS"
      priority  = "100"
      ranges    = local.allowed_ips
      allow = [
        {
          protocol = "all"
          ports    = []
        }
      ]
    },
    {
      name      = "gke-vpc-ingress-rfc"
      direction = "INGRESS"
      priority  = "100"
      ranges    = ["10.0.0.0/8","192.168.0.0/16","172.16.0.0/12"]
      allow = [
        {
          protocol = "all"
          ports    = []
        }
      ]
    }
  ]
  depends_on = [
    google_storage_bucket.gcs
  ]
}


module "vpc_gce" {
  source       = "terraform-google-modules/network/google"
  version      = "~> 4.0"
  project_id   = local.project_id
  network_name = "gce-vpc"
  routing_mode = "GLOBAL"

  subnets = [
    {
      subnet_name               = local.gce_subnet_name
      subnet_ip                 = local.gce_subnet_cidr
      subnet_region             = local.region
      subnet_flow_logs          = "true"
      subnet_flow_logs_interval = "INTERVAL_5_SEC"
      subnet_flow_logs_sampling = 1.0
      subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
      subnet_flow_logs_filter   = "false"
    }
  ]

  firewall_rules = [
    {
      name      = "gce-vpc-ingress-public"
      direction = "INGRESS"
      priority  = "100"
      ranges    = local.allowed_ips
      allow = [
        {
          protocol = "all"
          ports    = []
        }
      ]
    },
    {
      name      = "gce-vpc-ingress-rfc"
      direction = "INGRESS"
      priority  = "100"
      ranges    = ["10.0.0.0/8","192.168.0.0/16","172.16.0.0/12"]
      allow = [
        {
          protocol = "all"
          ports    = []
        }
      ]
    }
  ]
  depends_on = [
    google_storage_bucket.gcs
  ]
}

# -------------------------------------------------------------------------------------
# Create VMs
# -------------------------------------------------------------------------------------

# Service account for AI VM.  Needed to reach vertex APIs.
resource "google_service_account" "ai" {
  account_id = "ai-sa-${random_string.main.result}"
  project    = local.project_id
}


# AI Application VM.
resource "google_project_iam_member" "ai" {
  project = local.project_id
  role    = "roles/owner" #"roles/aiplatform.user" #"roles/aiplatform.admin"
  member  = "serviceAccount:${google_service_account.ai.email}"
}

resource "google_compute_instance" "ai" {
  name         = "ai-vm"
  machine_type = "e2-standard-4"
  zone         = local.zone

  boot_disk {
    initialize_params {
      image = local.ai_vm_image
    }
  }

  network_interface {
    subnetwork = module.vpc_gce.subnets_self_links[0]
    network_ip = cidrhost(local.gce_subnet_cidr, 10)
    access_config {}
  }

  service_account {
    email = google_service_account.ai.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  // Required metadata. The values are used to authenticate to vertex APIs.
  metadata = {
    project-id  = local.project_id
    region      = local.region
    openai-key  = local.openai_api_key
    openai-port = "80"
    gemini-port = "8080"

  }
}



# -------------------------------------------------------------------------------------
# Create GKE cluster
# -------------------------------------------------------------------------------------

module "gke" {
  source                     = "terraform-google-modules/kubernetes-engine/google"
  version                    = "~> 28.0"
  project_id                 = local.project_id
  name                       = local.gke_cluster_name
  regional                   = true
  region                     = local.region
  network                    = module.vpc_gke.network_name
  subnetwork                 = module.vpc_gke.subnets_names[0]
  ip_range_pods              = local.gke_secondary_ranges[0].range_name
  ip_range_services          = local.gke_secondary_ranges[1].range_name
  release_channel            = "UNSPECIFIED"
  kubernetes_version         = local.gke_version
  create_service_account     = true
  http_load_balancing        = true
  network_policy             = true
  horizontal_pod_autoscaling = false

  node_pools = [
    {
      name               = "default-node-pool"
      machine_type       = "e2-standard-2"
      initial_node_count = 1
      auto_upgrade       = false
    }
  ]

  node_pools_oauth_scopes = {
    all = []
    default-node-pool = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
  depends_on = [
    module.vpc_gke
  ]
}

data "google_container_cluster" "gke" {
  name     = module.gke.name
  location = local.region
}
