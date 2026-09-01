#!/usr/bin/env bash
# Unit-tests the alert rules with promtool.
#
# The rules live inside PrometheusRule custom resources, which promtool can't
# read directly — it wants plain {groups: [...]} rule files. This extracts the
# .spec from each CR (ruby ships on macOS and the ubuntu runners; JSON is valid
# YAML) into tests/.extracted/, then runs the test suite against them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERTS="${SCRIPT_DIR}/../observability/alerts"
OUT="${ALERTS}/tests/.extracted"

command -v promtool >/dev/null || { echo "promtool not found (brew install prometheus / see CI for the download step)" >&2; exit 1; }

mkdir -p "${OUT}"
for f in availability-alert burn-rate-alert; do
  ruby -ryaml -rjson -e 'puts JSON.pretty_generate(YAML.load_file(ARGV[0])["spec"])' \
    "${ALERTS}/${f}.yaml" > "${OUT}/${f}.yaml"
done

promtool check rules "${OUT}"/*.yaml
promtool test rules "${ALERTS}/tests/slo-rules.test.yaml"
