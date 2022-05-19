variable "project_id" {
  type = string
}

variable "project_number" {
  type = string
}

variable "basename" {
  type = string
}

variable "domain" {
  type = string
}

variable "location" {
  type = string
}

variable "yesorno" {
  type = string
}

locals {
  basename     = replace(var.domain, ".", "-")
  bucket       = var.domain
  clouddnszone = "${local.basename}-zone"
}


# Enabling services in your GCP project
variable "gcp_service_list" {
  description = "The list of apis necessary for the project"
  type        = list(string)
  default = [
    "domains.googleapis.com",
    "storage.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "appengine.googleapis.com",
  ]
}

resource "google_project_service" "all" {
  for_each                   = toset(var.gcp_service_list)
  project                    = var.project_number
  service                    = each.key
  disable_dependent_services = false
  disable_on_destroy         = false
}


resource "google_dns_managed_zone" "dnszone" {
  project     = var.project_id
  name        = local.clouddnszone
  dns_name    = "${var.domain}."
  description = "A DNS Zone for managing ${var.domain}"
}


resource "null_resource" "dnsconfigure" {

    provisioner "local-exec" {
        command = <<-EOT
        gcloud beta domains registrations configure dns ${var.domain} --cloud-dns-zone=${local.clouddnszone}
        EOT
    }

    depends_on = [
        google_project_service.all,
        google_dns_managed_zone.dnszone
    ]
}


resource "google_compute_managed_ssl_certificate" "cert" {
  name        = "${local.basename}-cert"
  description = "Cert for ${local.basename}-microsite"
  project     = var.project_id

  managed {
    domains = [var.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}


# Creating External IP
resource "google_compute_global_address" "ip" {
  project    = var.project_id
  name       = "${local.basename}-ip"
  ip_version = "IPV4"
}

# Creating Bucket
resource "google_storage_bucket" "http_bucket" {
  name     = local.bucket
  project  = var.project_id
  location = var.location

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}


resource "google_storage_bucket_iam_binding" "policy" {
  bucket = google_storage_bucket.http_bucket.name
  role   = "roles/storage.objectViewer"
  members = [
    "allUsers",
  ]
  depends_on = [google_storage_bucket.http_bucket]
}


# Copying site to the bucket
resource "google_storage_bucket_object" "archive" {
  name   = "index.html"
  bucket = google_storage_bucket.http_bucket.name
  source = "code/${var.yesorno}/index.html"
  depends_on = [
    google_project_service.all,
    google_storage_bucket.http_bucket,
  ]
}

# Standing up Load Balancer
resource "google_compute_backend_bucket" "be" {
  project     = var.project_id
  name        = "${local.basename}-be"
  bucket_name = google_storage_bucket.http_bucket.name
  depends_on = [google_storage_bucket.http_bucket]
}

resource "google_compute_url_map" "lb" {
  project         = var.project_id
  name            = "${local.basename}-lb"
  default_service = google_compute_backend_bucket.be.id
   depends_on = [google_compute_backend_bucket.be]
}

# Enabling HTTP
resource "google_compute_target_http_proxy" "lb-proxy" {
  project = var.project_id
  name    = "${var.basename}-lb-proxy"
  url_map = google_compute_url_map.lb.id
  depends_on = [google_compute_url_map.lb]
}

resource "google_compute_forwarding_rule" "http-lb-forwarding-rule" {
  project               = var.project_id
  name                  = "${var.basename}-http-lb-forwarding-rule"
  provider              = google-beta
  region                = "none"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.lb-proxy.id
  ip_address            = google_compute_global_address.ip.id
  depends_on = [google_compute_target_http_proxy.lb-proxy]
}



# Enabling HTTPS
resource "google_compute_target_https_proxy" "ssl-lb-proxy" {
  project          = var.project_id
  name             = "${var.basename}-ssl-lb-proxy"
  url_map          = google_compute_url_map.lb.id
  ssl_certificates = [google_compute_managed_ssl_certificate.cert.id]
  depends_on = [google_compute_url_map.lb,google_compute_managed_ssl_certificate.cert ]
}

resource "google_compute_forwarding_rule" "https-lb-forwarding-rule" {
  project               = var.project_id
  name                  = "${var.basename}-https-lb-forwarding-rule"
  provider              = google-beta
  region                = "none"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "443"
  target                = google_compute_target_https_proxy.ssl-lb-proxy.id
  ip_address            = google_compute_global_address.ip.id
  depends_on = [google_compute_target_https_proxy.ssl-lb-proxy]
}



# Setting DNS A Record
resource "google_dns_record_set" "a" {
  project      = var.project_id
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.dnszone.name
  type         = "A"
  ttl          = 60


  rrdatas = [google_compute_global_address.ip.address]
  depends_on = [google_compute_global_address.ip]
}


output "http_link" {
  value       = "http://${var.domain}"
  description = "The unsecured version of the site."
}

output "https_link" {
  value       = "https://${var.domain}"
  description = "The secured version of the site."
}