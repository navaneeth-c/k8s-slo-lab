#!/usr/bin/env bash
# Drives traffic at podinfo so the RED dashboard and the SLO recording rules
# have real data to work with.
#
# Usage:
#   ./load.sh              # healthy traffic (200s)
#   ./load.sh errors       # 5xx traffic, to burn error budget on purpose
#   ./load.sh errors 600   # ...for 600 seconds
#
# Runs in-cluster so it does not depend on a port-forward staying up. podinfo
# serves /status/{code}, which is what makes deliberate 5xx generation possible
# without breaking the app.
set -euo pipefail

MODE="${1:-healthy}"
DURATION="${2:-300}"
NAMESPACE="${NAMESPACE:-default}"

if [[ "${MODE}" == "errors" ]]; then
  PATH_TO_HIT="/status/500"
  JOB_NAME="podinfo-load-errors"
  echo "Driving 5xx traffic at podinfo for ${DURATION}s — this burns error budget on purpose."
else
  PATH_TO_HIT="/"
  JOB_NAME="podinfo-load"
  echo "Driving healthy traffic at podinfo for ${DURATION}s..."
fi

kubectl -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1

kubectl -n "${NAMESPACE}" create job "${JOB_NAME}" --image=curlimages/curl:8.10.1 -- \
  /bin/sh -c "end=\$(( \$(date +%s) + ${DURATION} )); \
              while [ \$(date +%s) -lt \$end ]; do \
                curl -s -o /dev/null http://podinfo:9898${PATH_TO_HIT}; \
              done; echo done"

echo "Load job '${JOB_NAME}' started in namespace '${NAMESPACE}'."
echo "Follow it with: kubectl -n ${NAMESPACE} logs -f job/${JOB_NAME}"
