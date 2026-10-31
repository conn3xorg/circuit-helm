# circuit-helm

A Conn3x circuit that installs [Helm](https://helm.sh) at a version you pin, checks its SHA-256, and can keep chart releases where you asked: repository, chart, exact version and values, all in your configuration.

Say you've got a k3s server and a couple of charts you want on it. Run Helm by hand and six months later nobody remembers which values went in. Here the values live in your configuration, a change to them is an upgrade on the next apply, and an upgrade or uninstall someone did by hand shows up in the next plan.

## Usage

Only the binary:

```hcl
module "helm" {
  source = "github.com/conn3xorg/circuit-helm?ref=v0.1.1"

  hosts                = { web1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"
}
```

With a release, on a cluster built by [circuit-k3s](https://github.com/conn3xorg/circuit-k3s):

```hcl
module "k3s" {
  source = "github.com/conn3xorg/circuit-k3s?ref=v0.1.4"

  servers              = { cp1 = "203.0.113.10" }
  token                = var.k3s_token
  ssh_private_key_file = "~/.ssh/id_ed25519"
}

module "helm" {
  source     = "github.com/conn3xorg/circuit-helm?ref=v0.1.1"
  depends_on = [module.k3s]

  hosts                = { cp1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  releases = {
    podinfo = {
      chart      = "podinfo"
      repository = "https://stefanprodan.github.io/podinfo"
      version    = "6.17.0"
      sha256     = "d3d67f460f9f94bb6d10950315fc0953799efc0ee60332e3c475e755e99c0e04"
      namespace  = "podinfo"
      values     = yamlencode({ replicaCount = 2, ui = { message = "hello" } })
    }
  }
}

variable "k3s_token" {
  type      = string
  ephemeral = true
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

For a chart in an OCI registry, set `chart = "oci://ghcr.io/stefanprodan/charts/podinfo"` and leave out `repository`.

To try it on a throwaway container first, see [examples/local](examples/local).

### Secrets in values

`values` reach Conn3x state, so this circuit won't take a secret there. A plan stops if a string value sits under a key containing `password`, `passwd`, `secret`, `token`, `api_key`, `private_key` or `credential`, or if the value is marked sensitive. Keys that name a secret rather than hold one, such as `existingSecret` or `secretName`, are fine.

It's a check on key names, so it can't catch a password under a key called `auth`. Read your values before you commit them.

You've got two ways to hand a chart a real secret. If the chart takes an existing Kubernetes secret, use that. Otherwise, write a values file on the host with a write-only `file` step and name it in `values_files`. Conn3x then keeps only the file's path and a keyed hash:

```hcl
variable "grafana_admin_password" {
  type      = string
  ephemeral = true
}

circuit "grafana_secret" {
  hosts = { cp1 = "203.0.113.10" }

  ssh {
    user             = "root"
    private_key_file = "~/.ssh/id_ed25519"
  }

  step "values" {
    file {
      path       = "/etc/grafana-secret-values.yaml"
      content_wo = yamlencode({ adminPassword = var.grafana_admin_password })
    }
  }
}

module "helm" {
  # ...
  depends_on = [conn3x_file.grafana_secret__values]

  releases = {
    grafana = {
      # ...
      values_files = ["/etc/grafana-secret-values.yaml"]
    }
  }
}
```

Two things to know. Helm keeps every release's values in a Kubernetes secret in the release's namespace, so anyone who can read those can read yours: out of state isn't out of the cluster. And a plan looks at the file before the write-only step runs, so a new secret reaches the release on the apply after the one that wrote it.

## What it does

On every host in `hosts`:

1. Installs `curl`, `tar` and `gzip`.
2. Downloads Helm from `get.helm.sh`, checks its SHA-256, unpacks it under `/opt/helm/VERSION` and links `/usr/local/bin/helm` to it. A `helm` already at that path gets replaced.

If you've listed releases, on one host (`release_host`, or the first name in sorted order):

3. On a k3s server, waits for every CRD to be established. If one stays stuck, the apply fails and points to [Troubleshooting](https://github.com/conn3xorg/circuit-k3s#troubleshooting) in circuit-k3s. It never deletes a CRD.
4. Pulls each chart to `/var/lib/conn3x-helm/RELEASE/VERSION`, checking `sha256` if you gave one before the file lands there.
5. Writes `values` to `/var/lib/conn3x-helm/RELEASE/values.yaml`, mode `0600`.
6. Runs `helm upgrade --install --wait`, with up to 15 minutes for the release to become ready.

Helm's output goes to `/var/lib/conn3x-helm/RELEASE/helm.log` on the host instead of to Conn3x, because a step's output is kept in state and a chart's notes can print values. When a release fails, that log is where to look.

### Drift

Each plan compares a hash of the chart, the values files and Helm's latest revision with the hash from the last apply. So you'll see a planned change after someone runs `helm upgrade` or `helm uninstall` by hand, or edits a file in `values_files`, and the apply puts your configuration back. It doesn't look at the Kubernetes objects themselves: a `kubectl edit` on a deployment isn't noticed.

While the cluster is down, a plan can't read Helm's revision and shows the release as changed. A plan right after a reboot can do this too, until the API is back.

### What it doesn't do

- It doesn't log in to private repositories or registries. Credentials in a `repository` URL are refused, since they'd reach state and the process list.
- It doesn't order releases among themselves. When one needs another first, use two modules with `depends_on`.
- It doesn't uninstall. Taking a release out of `releases` leaves it running, and `helm uninstall` removes it.
- It doesn't remove old Helm versions or charts from `/opt/helm` and `/var/lib/conn3x-helm`.

### Upgrading Helm

Set `helm_version` and `checksums` together. Take each checksum from `https://get.helm.sh/helm-VERSION-linux-ARCH.tar.gz.sha256sum`.

### Kustomize

You don't need a separate circuit for kustomize. k3s's `kubectl` has it built in, so one `command` step applies an overlay that's already on the host, and does nothing when the cluster matches it:

```hcl
step "overlay" {
  command {
    command = "k3s kubectl apply -k /srv/overlays/prod"
    unless  = "k3s kubectl diff -k /srv/overlays/prod"
  }
}
```

We ran those two commands by hand on k3s v1.37.1, whose `kubectl` embeds kustomize v5.8.1, but not as a Conn3x step. `kubectl diff` exits 1 when the overlay has changed and 0 once it's applied. A standalone binary only adds `kustomize edit`, `cfg` and `fn`.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to install Helm on: names to addresses, or to host objects with an `address` and optional `host_key`, `user`, `port`, `private_key_file` and `jump_hosts`. |
| `helm_version` | string | `"v4.3.1"` | Helm release, with its `v`. |
| `checksums` | map(string) | The v4.3.1 checksums | SHA-256 of the tarball, for `amd64` and `arm64`. |
| `releases` | map(object) | `{}` | Chart releases by release name. See below. |
| `release_host` | string | `null` | Which of `hosts` runs Helm for the releases. When null, the first name in sorted order. |
| `kubeconfig` | string | `"/etc/rancher/k3s/k3s.yaml"` | Path on the release host of the kubeconfig Helm uses. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |

Each release takes:

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `chart` | string | Required | Chart name in `repository`, or an `oci://` reference. |
| `repository` | string | `null` | Chart repository, an `https://` URL with no credentials. |
| `version` | string | Required | One exact chart version. Ranges are refused. |
| `sha256` | string | `null` | SHA-256 of the chart's `.tgz`. Worth setting: a repository can publish new bytes under an old version. |
| `namespace` | string | `"default"` | Namespace, created if it's missing. |
| `values` | string | `"{}"` | YAML, usually from `yamlencode`. Reaches state, so secrets are refused here. |
| `values_files` | list(string) | `[]` | Absolute paths of values files already on the host, applied after `values`. |

## Outputs

| Name | Description |
| --- | --- |
| `helm_version` | Helm release installed. |
| `helm_path` | Path of the `helm` command on each host. |

## Requirements

Requires Conn3x v0.6.10 or later, circuit-k3s v0.1.4 or later if that's what built your cluster, and outbound HTTPS to `get.helm.sh` and your chart repositories. Releases need a Kubernetes cluster and a kubeconfig on the release host. Helm doesn't need it to be k3s, but every release test here ran on k3s.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each in a container on amd64 and checks that the plan after it has no changes. It asks the running pods for a value through their service, changes the value and asks again, checks that a values file stayed out of state, and checks that a secret-looking value is refused. A container shows that the install works. It doesn't show that a release survives a reboot. The same four containers also passed by hand on arm64, along with an upgrade done by hand showing up in a plan, a wrong chart `sha256` stopping the apply, an `oci://` chart with no `sha256`, and the binary on its own with no releases, the last two on Debian 13.

The rest was run by hand on 2 vCPU, 4 GB droplets with one node each: Ubuntu 24.04, and Rocky Linux 10. On both, the value change showed in the pods, the secret wasn't in state, and after a reboot the plan had no changes and the pods still gave the right answer.

v0.1.0 deleted k3s's Helm CRDs when they weren't established after about three minutes. On a cluster that was only slow, that would have deleted every HelmChart in it, so upgrade from v0.1.0. v0.1.1 only waits. CI runs it with circuit-k3s v0.1.4; the droplet runs above were on v0.1.0.

Not run: Helm 3, a cluster that isn't k3s, more than one host, a real secret chart such as Grafana (the example above is a sketch of the route that podinfo tested), arm64 on a real host.

## License

MPL-2.0. See [LICENSE](LICENSE). Helm is Apache-2.0.
