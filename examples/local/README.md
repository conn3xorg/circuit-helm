# Local example

Builds a one-node k3s cluster with [circuit-k3s](https://github.com/conn3xorg/circuit-k3s) in a throwaway Rocky Linux 10 container, installs Helm, and releases the small [podinfo](https://github.com/stefanprodan/podinfo) chart with one plain value and one values file that stays out of state. You need Conn3x and Podman.

k3s runs containers of its own, so the host container runs privileged, and rootless Podman can't give it the cpuset cgroup k3s needs. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply -var 'values=ui: { message: first }'
conn3x plan -var 'values=ui: { message: first }'
```

The second plan says `No changes.` Now ask the running pods what they say, change the value, and ask again:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 sh -s first < check.sh
conn3x apply -var 'values=ui: { message: second }'
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 sh -s second < check.sh
```

To watch a secret get refused, try `conn3x plan -var 'values=adminPassword: hunter2'`.

The container can't load kernel modules, so its host needs `br_netfilter` and `overlay` loaded. A Podman machine has both. On Linux, run `sudo modprobe -a br_netfilter overlay` first.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` stops the container, which removes it and its volume, then deletes the key and the state.
