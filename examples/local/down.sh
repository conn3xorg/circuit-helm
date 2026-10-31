#!/usr/bin/env sh
# Stops the container, which takes its volume with it since up.sh starts it
# with --rm, and removes everything up.sh and Conn3x created here.
set -eu
cd "$(dirname "$0")"
${PODMAN:-podman} stop --ignore "${NAME:-circuit-helm}" >/dev/null 2>&1 || true
rm -rf id_ed25519 id_ed25519.pub known_hosts .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
echo "Removed."
