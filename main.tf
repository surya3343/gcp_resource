#Configure the Google Cloud provider
    provider "google" {
    credentials = "${file("${var.credentials}")}"
    project     = "${var.gcp_project}"
    region      = "${var.region}"
    }
    #Create VPC
    resource "google_compute_network" "vpc1" {
    name                    = "${var.name}-vpc1"
    auto_create_subnetworks = "false"
    }

    resource "google_compute_network" "vpc2" {
    name                    = "${var.name}-vpc2"
    auto_create_subnetworks = "false"
    }

    #Create Subnets
    resource "google_compute_subnetwork" "public-subnet1" {
    name          = "${var.name}-public-subnet1"
    ip_cidr_range = "${var.subnet_cidr1}"
    network       = "${var.name}-vpc1"
    depends_on    = ["google_compute_network.vpc1"]
    region      = "${var.region}"
    }

    resource "google_compute_subnetwork" "private-subnet1" {
    name          = "${var.name}-private-subnet1"
    ip_cidr_range = "${var.subnet_cidr2}"
    network       = "${var.name}-vpc1"
    depends_on    = ["google_compute_network.vpc1"]
    region      = "${var.region}"
    }

    resource "google_compute_subnetwork" "public-subnet2" {
    name          = "${var.name}-public-subnet2"
    ip_cidr_range = "${var.subnet_cidr3}"
    network       = "${var.name}-vpc2"
    depends_on    = ["google_compute_network.vpc2"]
    region      = "${var.region}"
    }
    resource "google_compute_subnetwork" "private-subnet2" {
    name          = "${var.name}-private-subnet2"
    ip_cidr_range = "${var.subnet_cidr4}"
    network       = "${var.name}-vpc2"
    depends_on    = ["google_compute_network.vpc2"]
    region      = "${var.region}"
    }

    #VPC firewall configuration
    resource "google_compute_firewall" "firewall1" {
    name    = "${var.name}-firewall1"
    network = "${google_compute_network.vpc1.name}"

    allow {
        protocol = "icmp"
    }

    allow {
        protocol = "tcp"
        ports    = ["22"]
    }

    source_ranges = ["${var.myip}"]
    }

    resource "google_compute_firewall" "firewall2" {
    name    = "${var.name}-firewall2"
    network = "${google_compute_network.vpc2.name}"

    allow {
        protocol = "icmp"
    }

    allow {
        protocol = "tcp"
        ports    = ["22"]
    }

    source_ranges = ["${var.myip}"]
    }

    #Compute Instance

  resource "google_compute_instance" "network1" {
  name         = "${var.network1-instname}"
  machine_type = "${var.vmtype}"
  zone         = "asia-south1-a"
  tags = ["${google_compute_firewall.firewall1.name}"]

  boot_disk {
    initialize_params {
      image = "${var.image}"
      size = "${var.disk_size}"
    }
  }

  // Local SSD disk
  scratch_disk {
    interface = "SCSI"
  }

  network_interface {
    network = "${google_compute_network.vpc1.name}"
    subnetwork = "${google_compute_subnetwork.public-subnet1.name}"

    access_config {
      // Ephemeral IP
    }
  }

  metadata_startup_script = "echo hi > /test.txt"

  service_account {
    email = "${var.sa-email}"
    scopes = ["https://www.googleapis.com/auth/devstorage.read_only",
        "https://www.googleapis.com/auth/logging.write",
        "https://www.googleapis.com/auth/monitoring.write",
        "https://www.googleapis.com/auth/servicecontrol",
        "https://www.googleapis.com/auth/service.management.readonly",
        "https://www.googleapis.com/auth/trace.append"
        ]
  }
}

  resource "google_compute_instance" "network2" {
  name         = "${var.network2-instname}"
  machine_type = "${var.vmtype}"
  zone         = "asia-south1-c"
  tags = ["${google_compute_firewall.firewall2.name}"]

  boot_disk {
    initialize_params {
      image = "${var.image}"
      size = "${var.disk_size}"
    }
  }

  // Local SSD disk
  scratch_disk {
    interface = "SCSI"
  }

  network_interface {
    network = "${google_compute_network.vpc2.name}"
    subnetwork = "${google_compute_subnetwork.private-subnet2.name}"

  }

  metadata_startup_script = "echo hi > /test.txt"

  service_account {
    email = "${var.sa-email}"
    scopes = ["https://www.googleapis.com/auth/devstorage.read_only",
        "https://www.googleapis.com/auth/logging.write",
        "https://www.googleapis.com/auth/monitoring.write",
        "https://www.googleapis.com/auth/servicecontrol",
        "https://www.googleapis.com/auth/service.management.readonly",
        "https://www.googleapis.com/auth/trace.append"
        ]
  }
}



# VPC Peering 

resource "google_compute_network_peering" "peering1" {
  name         = "peering1"
  network      = "${google_compute_network.vpc1.id}" 
  peer_network = "${google_compute_network.vpc2.id}"
}

resource "google_compute_network_peering" "peering2" {
  name         = "peering2"
  network      = "${google_compute_network.vpc2.id}"
  peer_network = "${google_compute_network.vpc1.id}"
}

# Private GKE cluster

resource "google_container_cluster" "private_cluster" {
  name     = "my-private-gke-cluster"
  location = "asia-south1-a"
  network = "${google_compute_network.vpc1.id}"
  subnetwork = "${google_compute_subnetwork.public-subnet2.id}"

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1

  private_cluster_config {

      enable_private_nodes = true
      enable_private_endpoint = true
      master_ipv4_cidr_block = "${var.master_ip_range}"
  }

  node_config {
      disk_size_gb = "${var.node_disk_size}"
      disk_type    = "${var.node_disk_type}"
  }

  master_auth {
    username = ""
    password = ""

    client_certificate_config {
      issue_client_certificate = false
    }
  }
}

resource "google_container_node_pool" "primary_preemptible_nodes" {
  name       = "my-private-gke-cluster-pool"
  location   = "asia-south1-a"
  cluster    = "${google_container_cluster.private_cluster.name}"
  node_count = 1

  autoscaling {
      min_node_count = "${var.node_min_count}"
      max_node_count = "${var.node_max_count}"
  }

  management {
      auto_repair = true
      auto_upgrade = true
  }

  node_config {
    machine_type = "${var.gke_node_type}"

    metadata = {
      disable-legacy-endpoints = "true"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }
}


# Peering Address

resource "google_compute_global_address" "private_sql_ip_address" {
  provider = google-beta

  name          = "private_sql_ip_address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = "${google_compute_network.vpc1.id}"
}

# Service Peering

resource "google_service_networking_connection" "private_vpc_connection" {
  provider = google-beta

  network                 = "${google_compute_network.vpc1.id}"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = ["${google_compute_global_address.private_sql_ip_address.name}"]
}

# Cloud SQL Instance

resource "random_id" "db_name_suffix" {
  byte_length = 4
}

resource "google_sql_database_instance" "instance" {
  provider = google-beta

  name   = "private-db-instance-${random_id.db_name_suffix.hex}"
  region = "${var.region}"

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier = "${var.db_tier}"
    ip_configuration {
      ipv4_enabled    = false
      private_network = "${google_compute_network.vpc1.id}"
    }
  }
}

provider "google-beta" {
  region = "${var.region}"
  zone   = "asia-south1-a"
}
