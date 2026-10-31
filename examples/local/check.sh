#!/usr/bin/env sh
# Run this on the k3s server, as root, with the message podinfo should say.
# It asks the running pods, through their service, so it sees what the chart
# really deployed rather than what Helm recorded.
set -eu
want=$1
k() { k3s kubectl -n podinfo "$@"; }
k rollout status deploy/podinfo --timeout=5m >/dev/null
ip=$(k get svc podinfo -o jsonpath='{.spec.clusterIP}')
got=
for _ in $(seq 30); do
  got=$(curl -s --max-time 5 "http://$ip:9898/" | sed -n 's/.*"message": *"\([^"]*\)".*/\1/p')
  [ "$got" = "$want" ] && { echo "podinfo says: $got"; exit 0; }
  sleep 5
done
echo "podinfo says '$got', not '$want'" >&2
exit 1
