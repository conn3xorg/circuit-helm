variable "port" {
  type    = number
  default = 2222
}

variable "token" {
  type      = string
  ephemeral = true
  default   = "example-token-change-me"
}

variable "values" {
  type    = string
  default = "ui: { message: hello from conn3x }"
}

variable "secret" {
  type      = string
  ephemeral = true
  default   = "example-secret-change-me"
}

module "k3s" {
  source = "github.com/conn3xorg/circuit-k3s?ref=v0.1.4"

  servers              = { server1 = "127.0.0.1" }
  token                = var.token
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"
}

# A values file that stays out of state: the content is write-only, and the
# helm module only ever sees its path.
circuit "secret_values" {
  hosts = { server1 = "127.0.0.1" }

  ssh {
    user             = "root"
    port             = var.port
    private_key_file = "./id_ed25519"
    known_hosts_file = "./known_hosts"
  }

  step "file" {
    depends_on = [module.k3s]
    file {
      path       = "/etc/podinfo-secret-values.yaml"
      content_wo = "ui:\n  logo: ${var.secret}\n"
    }
  }
}

module "helm" {
  source     = "../.."
  depends_on = [conn3x_file.secret_values__file]

  hosts = { server1 = "127.0.0.1" }

  releases = {
    podinfo = {
      chart        = "podinfo"
      repository   = "https://stefanprodan.github.io/podinfo"
      version      = "6.17.0"
      sha256       = "d3d67f460f9f94bb6d10950315fc0953799efc0ee60332e3c475e755e99c0e04"
      namespace    = "podinfo"
      values       = var.values
      values_files = ["/etc/podinfo-secret-values.yaml"]
    }
  }

  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"
}
