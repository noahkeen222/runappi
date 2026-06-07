terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = "us-central1"
  zone    = "us-central1-a"
}

# -------------------------------------------------------
# Variables
# -------------------------------------------------------

variable "project_id" {
  description = "Your GCP project ID"
  type        = string
}

variable "ssh_public_key" {
  description = "Your SSH public key for VM access (paste contents of ~/.ssh/id_rsa.pub)"
  type        = string
}

variable "ssh_user" {
  description = "SSH username"
  type        = string
  default     = "runappi"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "runappi_db"
}

variable "db_user" {
  description = "PostgreSQL username"
  type        = string
  default     = "runappi_user"
}

variable "db_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

# -------------------------------------------------------
# Cloud Storage bucket for cold data offload
# -------------------------------------------------------

resource "google_storage_bucket" "runappi_cold" {
  name          = "${var.project_id}-runappi-cold"
  location      = "US-CENTRAL1"
  storage_class = "STANDARD"

  force_destroy = false

  uniform_bucket_level_access = true

  # MVP: delete anything older than a year
  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type = "Delete"
    }
  }
}

# -------------------------------------------------------
# Service account for the VM (least-privilege)
# Only allows writing to the cold storage bucket
# -------------------------------------------------------

resource "google_service_account" "runappi_vm" {
  account_id   = "runappi-vm-sa"
  display_name = "Runappi VM Service Account"
}

resource "google_storage_bucket_iam_member" "runappi_vm_storage" {
  bucket = google_storage_bucket.runappi_cold.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.runappi_vm.email}"
}

resource "google_compute_disk" "pg_data_disk" {
  name = "pg-data-disk"
  size = 20
  type = "pd-standard"
  zone = "us-central1-a"
}

# -------------------------------------------------------
# Firewall rules
# -------------------------------------------------------

resource "google_compute_firewall" "runappi_allow_http_https" {
  name    = "runappi-allow-http-https"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  # Open to all for now — tighten to Cloudflare IP ranges once proxy is confirmed
  source_ranges = ["0.0.0.0/0"] ### Change with cloudfare range
  target_tags   = ["runappi"]
}

resource "google_compute_firewall" "runappi_allow_ssh" {
  name    = "runappi-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["184.189.208.236/32"]
  target_tags   = ["runappi"]
}

# -------------------------------------------------------
# e2-micro VM (always free in us-central1)
# -------------------------------------------------------

resource "google_compute_instance" "runappi" {
  name         = "runappi"
  machine_type = "e2-micro"
  zone         = "us-central1-a"

  tags = ["runappi"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30           
      type  = "pd-standard"
    }
  }

  attached_disk {
    source      = google_compute_disk.pg_data_disk.id
    device_name = "pg-data-disk"
    mode        = "READ_WRITE"
  }

  network_interface {
    network = "default"
    access_config {}
  }

  service_account {
    email  = google_service_account.runappi_vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${var.ssh_public_key}"
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # Base system packages
    apt-get update -q
    apt-get install -y -q \
      python3 python3-pip python3-venv \
      git curl unzip
    # Install PostgreSQL only if missing
    if ! command -v psql >/dev/null 2>&1; then
      apt-get install -y -q postgresql postgresql-contrib
    fi

    DISK_DEVICE="/dev/disk/by-id/google-pg-data-disk"

    # Wait for attached disk to appear
    for _ in {1..30}; do
      if [ -b "$DISK_DEVICE" ]; then
        break
      fi
      sleep 2
    done

    if [ ! -b "$DISK_DEVICE" ]; then
      echo "Attached PostgreSQL disk not found: $DISK_DEVICE"
      exit 1
    fi

    # Format disk once if no filesystem exists
    if ! blkid "$DISK_DEVICE" >/dev/null 2>&1; then
      mkfs.ext4 -F "$DISK_DEVICE"
    fi

    mkdir -p /mnt/pgdata
    DISK_UUID="$(blkid -s UUID -o value "$DISK_DEVICE")"

    # Persist mount in fstab
    if ! grep -q "$DISK_UUID" /etc/fstab; then
      echo "UUID=$DISK_UUID /mnt/pgdata ext4 defaults,nofail 0 2" >> /etc/fstab
    fi

    if ! mountpoint -q /mnt/pgdata; then
      mount /mnt/pgdata
    fi

    PG_VERSION="$(ls /etc/postgresql | sort -V | tail -n1)"
    if [ -z "$PG_VERSION" ]; then
      echo "PostgreSQL version directory not found under /etc/postgresql"
      exit 1
    fi

    PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    PG_DATA_SRC="/var/lib/postgresql/$PG_VERSION/main"
    PG_DATA_DST="/mnt/pgdata"

    # Move PostgreSQL data to persistent disk
    systemctl stop postgresql || true

    if [ ! -f "$PG_DATA_DST/PG_VERSION" ]; then
      mkdir -p "$PG_DATA_DST"
      cp -a "$PG_DATA_SRC/." "$PG_DATA_DST/"
    fi

    chown -R postgres:postgres /mnt/pgdata
    chmod 700 "$PG_DATA_DST"

    # Force data directory to mounted disk and keep Postgres local-only
    if grep -Eq "^[#[:space:]]*data_directory[[:space:]]*=" "$PG_CONF"; then
      sed -i "s|^[#[:space:]]*data_directory[[:space:]]*=.*|data_directory = '/mnt/pgdata'|" "$PG_CONF"
    else
      echo "data_directory = '/mnt/pgdata'" >> "$PG_CONF"
    fi

    if grep -Eq "^[#[:space:]]*listen_addresses[[:space:]]*=" "$PG_CONF"; then
      sed -i "s|^[#[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = 'localhost'|" "$PG_CONF"
    else
      echo "listen_addresses = 'localhost'" >> "$PG_CONF"
    fi

    systemctl restart postgresql
    systemctl enable postgresql

    DB_NAME_B64='${base64encode(var.db_name)}'
    DB_USER_B64='${base64encode(var.db_user)}'
    DB_PASSWORD_B64='${base64encode(var.db_password)}'

    DB_NAME="$(printf '%s' "$DB_NAME_B64" | base64 -d)"
    DB_USER="$(printf '%s' "$DB_USER_B64" | base64 -d)"
    DB_PASSWORD="$(printf '%s' "$DB_PASSWORD_B64" | base64 -d)"

    # Create database/user/password and grant privileges (idempotent)
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
      --set=db_name="$DB_NAME" \
      --set=db_user="$DB_USER" \
      --set=db_password="$DB_PASSWORD" <<'SQL'
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'db_user') THEN
        EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password');
      ELSE
        EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_password');
      END IF;
    END
    $$;

    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name') THEN
        EXECUTE format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user');
      END IF;
    END
    $$;

    DO $$
    BEGIN
      EXECUTE format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'db_name', :'db_user');
    END
    $$;
    SQL

    echo "Runappi startup complete."
  EOF

  lifecycle {
    prevent_destroy = true
  }
}

# -------------------------------------------------------
# Outputs
# -------------------------------------------------------

output "vm_external_ip" {
  description = "External IP of the Runappi VM — point your Cloudflare DNS A record here"
  value       = google_compute_instance.runappi.network_interface[0].access_config[0].nat_ip
}

output "storage_bucket_name" {
  description = "Cold storage bucket name"
  value       = google_storage_bucket.runappi_cold.name
}

output "service_account_email" {
  description = "VM service account — no manual key needed, attached directly to the VM"
  value       = google_service_account.runappi_vm.email
}

output "database_url_local" {
  description = "Local PostgreSQL URL (use from VM or via SSH tunnel)"
  sensitive   = true
  value       = "postgresql://${var.db_user}:${var.db_password}@localhost:5432/${var.db_name}"
}
