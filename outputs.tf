output "helm_version" {
  description = "Helm release installed."
  value       = var.helm_version
}

output "helm_path" {
  description = "Path of the helm command on each host."
  value       = "/usr/local/bin/helm"
}
