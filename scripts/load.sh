#!/usr/bin/env bash
# Drives traffic at podinfo so the RED dashboard and the SLO recording rules
# have real data to work with.
#
# Usage:
#   ./load.sh              # healthy traffic (200s), 300s
#   ./load.sh errors       # 5xx traffic, to burn error budget on purpose
#   ./load.sh errors 600   # ...for 600 seconds
#
# Runs in-cluster as a real Job manifest (not `kubectl create job`) so it can
# carry resource limits — an unbounded curl loop on a laptop cluster can starve
# the very workload and Prometheus it's supposed to be measuring — plus a TTL
# so finished jobs clean themselves up, and an activeDeadline as a backstop.
set -euo pipefail

MODE="${1:-healthy}"
DURATION="${2:-300}"
NAMESPACE="${NAMESPACE:-default}"

[[ "${DURATION}" =~ ^[0-9]+$ ]] || { echo "duration must be an integer (seconds), got: ${DURATION}" >&2; exit 1; }

if [[ "${MODE}" == "errors" ]]; then
  PATH_TO_HIT="/status/500"
  JOB_NAME="podinfo-load-errors"
  echo "Driving 5xx traffic at podinfo for ${DURATION}s — this burns error budget on purpose."
elif [[ "${MODE}" == "healthy" ]]; then
  PATH_TO_HIT="/"
  JOB_NAME="podinfo-load"
  echo "Driving healthy traffic at podinfo for ${DURATION}s..."
else
  echo "usage: load.sh [healthy|errors] [duration-seconds]" >&2; exit 1
fi

kubectl -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1

kubectl -n "${NAMESPACE}" apply -f - <<MANIFEST
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $(( DURATION + 60 ))
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl:8.10.1
          command: ["/bin/sh", "-c"]
          args:
            - |
              end=\$(( \$(date +%s) + ${DURATION} ))
              while [ \$(date +%s) -lt \$end ]; do
                curl -s --max-time 2 -o /dev/null http://podinfo:9898${PATH_TO_HIT} || true
              done
              echo done
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits:   { cpu: 200m, memory: 64Mi }
MANIFEST

echo "Load job '${JOB_NAME}' running in namespace '${NAMESPACE}' (TTL cleans it up 5m after it finishes)."
echo "Follow it with: kubectl -n ${NAMESPACE} logs -f job/${JOB_NAME}"
