variable "hosts" {
  type        = any
  description = "Hosts to install Helm on: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "helm_version" {
  type        = string
  default     = "v4.3.1"
  description = "Helm release to install, with its v. Change checksums with it."

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.helm_version))
    error_message = "helm_version is a release tag such as \"v4.3.1\"."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the Helm tarball for each architecture, from get.helm.sh/helm-VERSION-linux-ARCH.tar.gz.sha256sum."
  default = {
    amd64 = "0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b"
    arm64 = "8cf8f66ecbc252ac8f7f06cca68aba88508ddfde3a6a34feb1678ad1694b4f88"
  }
}

variable "releases" {
  type = map(object({
    chart        = string
    repository   = optional(string)
    version      = string
    sha256       = optional(string)
    namespace    = optional(string, "default")
    values       = optional(string, "{}")
    values_files = optional(list(string), [])
  }))
  default     = {}
  description = "Chart releases to install, by release name. chart is a name in repository, or an oci:// reference with no repository. version is exact. values is YAML, usually from yamlencode, and reaches state, so anything secret goes in values_files: absolute paths of values files already on the host."

  validation {
    condition = alltrue([for name, r in var.releases :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name))
      && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", r.namespace))
      && can(regex("^(oci://)?[A-Za-z0-9][-A-Za-z0-9_./:]*$", r.chart))
    ])
    error_message = "Release names and namespaces are lowercase letters, digits and dashes. chart is a chart name or an oci:// reference."
  }

  validation {
    condition     = alltrue([for r in var.releases : can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+[-+.0-9A-Za-z]*$", r.version))])
    error_message = "version must be one exact chart version, such as \"6.17.0\", not a range."
  }

  # Credentials in a URL would reach state and the host's process list.
  validation {
    condition     = alltrue([for r in var.releases : r.repository == null || can(regex("^https://[-A-Za-z0-9_./:]+$", coalesce(r.repository, "-")))])
    error_message = "repository is an https:// URL with no user or password in it."
  }

  validation {
    condition     = alltrue([for r in var.releases : r.sha256 == null || can(regex("^[0-9a-f]{64}$", coalesce(r.sha256, "-")))])
    error_message = "sha256 is 64 lowercase hex digits."
  }

  validation {
    condition     = alltrue(flatten([for r in var.releases : [for f in r.values_files : can(regex("^/[-A-Za-z0-9_./]+$", f))]]))
    error_message = "values_files are absolute paths on the host, in letters, digits, dashes, dots, underscores and slashes."
  }

  validation {
    condition     = alltrue([for r in var.releases : can(yamldecode(r.values))])
    error_message = "values must be valid YAML."
  }

  # Only keys holding a string count: automountServiceAccountToken = false
  # isn't a secret. The second regex lets through keys that name a secret
  # rather than hold one, such as existingSecret or secretName.
  validation {
    condition = !issensitive(jsonencode(var.releases)) && length(flatten([for r in var.releases : [
      for m in regexall("\"([^\"]+)\":\"[^\"]+\"", try(jsonencode(yamldecode(r.values)), "")) : m[0]
      if can(regex("(?i)(password|passwd|secret|token|api_?key|private_?key|credential)", m[0])) && !can(regex("(?i)(^existing|name$|ref$)", m[0]))
    ]])) == 0
    error_message = "A value looks like a secret or is marked sensitive, and values reach Conn3x state. Put it in a file on the host and name that file in values_files. If the chart takes an existing Kubernetes secret, that also works."
  }
}

variable "release_host" {
  type        = string
  default     = null
  description = "Which of hosts runs Helm for the releases. When null, the first name in sorted order. It needs a kubeconfig at the path in kubeconfig."
}

variable "kubeconfig" {
  type        = string
  default     = "/etc/rancher/k3s/k3s.yaml"
  description = "Path on the release host of the kubeconfig Helm uses. The default is where k3s writes its own."

  validation {
    condition     = can(regex("^/[-A-Za-z0-9_./]+$", var.kubeconfig))
    error_message = "kubeconfig is an absolute path."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}
