# Facts give each host's architecture, which picks the Helm build.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  arch = { x86_64 = "amd64", aarch64 = "arm64" }
  home = "/opt/helm/${var.helm_version}"
  dir  = "/var/lib/conn3x-helm"
  helm = "/usr/local/bin/helm --kubeconfig ${var.kubeconfig}"

  wait_api = "for _ in $(seq 60); do k3s kubectl get --raw=/readyz >/dev/null 2>&1 && break; sleep 5; done"
  crds_up  = "for _ in $(seq 36); do k3s kubectl wait --for=condition=Established crd/helmcharts.helm.cattle.io crd/helmchartconfigs.helm.cattle.io --timeout=5s >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1"

  # Releases belong to a cluster, not a host, so one host runs them.
  release_host = length(var.releases) > 0 ? { for k in [coalesce(var.release_host, sort(keys(var.hosts))[0])] : k => var.hosts[k] } : {}

  # What decides whether a release is as asked: the chart, every values file
  # and Helm's own latest revision. The revision is how an upgrade or an
  # uninstall done by hand shows up in a plan. A file on the host counts by
  # its content, so a secret file can change without its value reaching state.
  fingerprint = { for name, r in var.releases : name => "{ cat ${local.dir}/${name}/${r.version}/*.tgz ${local.dir}/${name}/values.yaml ${join(" ", r.values_files)} && ${local.helm} history ${name} -n ${r.namespace} --max 1 -o json; } 2>/dev/null | sha256sum" }
}

circuit "helm" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "tools" {
    for_each = toset(["curl", "tar", "gzip"])
    package {
      name = item.value
    }
  }

  step "download" {
    download {
      url    = "https://get.helm.sh/helm-${var.helm_version}-linux-${local.arch[data.conn3x_host.facts[each.key].arch]}.tar.gz"
      sha256 = var.checksums[local.arch[data.conn3x_host.facts[each.key].arch]]
      dest   = "/opt/helm/helm-${var.helm_version}.tar.gz"
    }
  }

  step "unpack" {
    archive {
      src     = "/opt/helm/helm-${var.helm_version}.tar.gz"
      dest    = local.home
      creates = "${local.home}/linux-${local.arch[data.conn3x_host.facts[each.key].arch]}/helm"
    }
  }

  step "link" {
    link {
      path   = "/usr/local/bin/helm"
      target = "${local.home}/linux-${local.arch[data.conn3x_host.facts[each.key].arch]}/helm"
    }
  }
}

circuit "helm_releases" {
  hosts = local.release_host

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # k3s can exit just after creating these CRDs, which leaves them never
  # established. It then exits a minute into every later start, failing whatever
  # Helm is doing, and restarting doesn't help. Nothing can be stored in a CRD
  # that isn't established, so deleting them loses nothing, and k3s creates them
  # again. Other clusters have no k3s command and skip this.
  step "k3s_settled" {
    depends_on = [conn3x_link.helm__link]
    command {
      command = "command -v k3s >/dev/null || exit 0; ${local.wait_api}; ( ${local.crds_up} ) || { for _ in $(seq 24); do k3s kubectl delete crd helmcharts.helm.cattle.io helmchartconfigs.helm.cattle.io --ignore-not-found --timeout=20s >/dev/null 2>&1 && break; sleep 5; done; ${local.wait_api}; ${local.crds_up}; }"
    }
  }

  # A version pins a name, and a repository can publish new bytes under it.
  # Checking in a temporary directory means a chart that fails never lands
  # where the release step looks.
  step "chart" {
    for_each = var.releases
    command {
      command = "t=$(mktemp -d) && trap 'rm -rf \"$t\"' EXIT && /usr/local/bin/helm pull ${item.value.chart} ${item.value.repository == null ? "" : "--repo ${item.value.repository}"} --version ${item.value.version} -d \"$t\" && ${item.value.sha256 == null ? "true" : "echo \"${item.value.sha256}  $(ls \"$t\"/*.tgz)\" | sha256sum -c - >/dev/null"} && mkdir -p -m 0700 ${local.dir}/${item.key}/${item.value.version} && mv \"$t\"/*.tgz ${local.dir}/${item.key}/${item.value.version}/"
      unless  = item.value.sha256 == null ? "ls ${local.dir}/${item.key}/${item.value.version}/*.tgz" : "echo \"${item.value.sha256}  $(ls ${local.dir}/${item.key}/${item.value.version}/*.tgz)\" | sha256sum -c -"
    }
  }

  step "values" {
    for_each = var.releases
    file {
      path    = "${local.dir}/${item.key}/values.yaml"
      content = item.value.values
      mode    = "0600"
    }
  }

  # Helm's output goes to a root-only log, not to the step: Conn3x keeps a
  # step's output in state, and a chart's notes can print values from a file
  # that was meant to stay out of it. An unless guard is checked at plan
  # time, before the values step has run, so the trigger makes the apply
  # check it again.
  step "release" {
    for_each = var.releases
    command {
      command  = "for _ in $(seq 60); do ${local.helm} list >/dev/null 2>&1 && break; sleep 5; done; ${local.helm} upgrade --install ${item.key} ${local.dir}/${item.key}/${item.value.version}/*.tgz -n ${item.value.namespace} --create-namespace -f ${local.dir}/${item.key}/values.yaml ${join(" ", [for f in item.value.values_files : "-f ${f}"])} --wait --timeout 15m > ${local.dir}/${item.key}/helm.log 2>&1 || { echo 'Helm failed. See ${local.dir}/${item.key}/helm.log on the host.' >&2; exit 1; }; ${local.fingerprint[item.key]} > ${local.dir}/${item.key}/applied"
      unless   = "[ \"$(${local.fingerprint[item.key]})\" = \"$(cat ${local.dir}/${item.key}/applied)\" ]"
      triggers = { values = conn3x_file.helm_releases__values["${each.key}/${item.key}"].revision }
    }
  }
}
