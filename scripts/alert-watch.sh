#!/usr/bin/env bash
# Watches a Prometheus alert until it reaches a target state, printing every
# state transition with a timestamp.
#
# Usage: ./alert-watch.sh <alert-name> <firing|inactive> [timeout-seconds]
#
# Polls the Prometheus HTTP API through a temporary port-forward. The point is
# to make the alert lifecycle visible — inactive -> pending -> firing -> and
# back — rather than asking the reader to trust that the rule works.
set -euo pipefail

ALERT="${1:?usage: alert-watch.sh <alert-name> <firing|inactive> [timeout]}"
WANT="${2:?usage: alert-watch.sh <alert-name> <firing|inactive> [timeout]}"
TIMEOUT="${3:-300}"

PROM_SVC="kube-prometheus-stack-prometheus"
PROM_NS="monitoring"
LOCAL_PORT="${PROM_PORT:-9090}"

kubectl -n "${PROM_NS}" port-forward "svc/${PROM_SVC}" "${LOCAL_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

# Wait for the port-forward to actually accept connections before polling.
for _ in $(seq 1 20); do
  if curl -sf "http://localhost:${LOCAL_PORT}/-/ready" >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "Watching alert '${ALERT}' for state '${WANT}' (timeout ${TIMEOUT}s)..."

last=""
deadline=$(( $(date +%s) + TIMEOUT ))

while [[ $(date +%s) -lt ${deadline} ]]; do
  # An alert rule that is not firing has no entries in .alerts, so a missing
  # alert and a resolved alert both read as "inactive" here — which is what
  # we want, since both mean "not currently a problem."
  state=$(curl -sf "http://localhost:${LOCAL_PORT}/api/v1/rules" \
    | python3 -c '
import json, sys
alert = sys.argv[1]
data = json.load(sys.stdin)
for group in data["data"]["groups"]:
    for rule in group["rules"]:
        if rule.get("name") == alert:
            print(rule.get("state", "unknown"))
            sys.exit(0)
print("notfound")
' "${ALERT}" 2>/dev/null || echo "unreachable")

  if [[ "${state}" != "${last}" ]]; then
    printf '%s  %s -> %s\n' "$(date +%H:%M:%S)" "${ALERT}" "${state}"
    last="${state}"
  fi

  if [[ "${WANT}" == "firing"   && "${state}" == "firing"   ]]; then
    echo "Alert reached 'firing'."; exit 0
  fi
  if [[ "${WANT}" == "inactive" && "${state}" == "inactive" ]]; then
    echo "Alert cleared."; exit 0
  fi

  sleep 5
done

echo "Timed out after ${TIMEOUT}s — last observed state: ${last:-none}" >&2
exit 1
