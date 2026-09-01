# k8s-slo-lab

Run a real SLO end to end on a laptop: an availability target, an error budget, multi-window burn-rate alerts, and — the part most examples skip — a one-command way to **break the service and watch the alert actually fire**.

[![CI](https://github.com/navaneeth-c/k8s-slo-lab/actions/workflows/ci-cd.yaml/badge.svg?branch=main)](https://github.com/navaneeth-c/k8s-slo-lab/actions/workflows/ci-cd.yaml)

Most SLO examples ship alert rules nobody has ever seen trigger. The rules in this repo were each tested against an induced outage, and two of them were wrong the first time. Those bugs, and why they were invisible on paper, are written up in [Debugging Notes](#debugging-notes). This repo is a public rebuild of a private original where that debugging happened; the git history here is the rebuild's, not the journey's.

```bash
make up      # kind cluster + Prometheus/Grafana + podinfo, ~4 min
make break   # scale to zero, watch PodinfoUnavailable go pending -> firing
make fix     # scale back up, watch it clear
make burn    # drive 5xx traffic, watch the fast-burn SLO alert fire
make down    # delete the cluster

make test-rules   # promtool unit tests for the alert rules (no cluster needed)
```

Prereqs: Docker, `kind`, `helm` (3 or 4 — the deploy script detects which rollback flag your version speaks), `kubectl`, `python3`, `curl`. No cloud account, no credentials.

What `make break` prints, from an actual run (abridged — the kubectl/make echo lines are trimmed):

```
kubectl -n default scale deployment/podinfo --replicas=0
Watching alert 'PodinfoUnavailable' for state 'firing' (timeout 300s)...
19:41:46  PodinfoUnavailable -> inactive
19:42:37  PodinfoUnavailable -> pending
19:44:37  PodinfoUnavailable -> firing
```

`pending` about 50 seconds after the pods go away, then `firing` exactly two
minutes later — the rule's `for: 2m`. `make burn` does the same for the SLO
fast-burn alert, driving deliberate 5xx traffic until the error ratio clears
14.4x the budget rate.

The workload under test is [stefanprodan/podinfo](https://github.com/stefanprodan/podinfo) — deliberately boring, because the app is not the point. The SLO loop around it is.

---

## What's in here

| Path | What it is |
|---|---|
| `charts/podinfo/` | Helm chart — autoscaling, probes, env-specific overrides |
| `observability/alerts/` | The SLO rules: availability + multi-window burn rate |
| `observability/alerts/tests/` | `promtool` unit tests pinning the alert behavior |
| `observability/servicemonitor.yaml` | Prometheus Operator wiring |
| `observability/dashboards/` | RED dashboard, auto-loaded by Grafana's sidecar |
| `.github/workflows/ci-cd.yaml` | Lint → staging → manual gate → prod, with rollback |
| `scripts/`, `Makefile` | The demo harness |

---

## SLO, SLI, and error budget

**SLO:** 99.9% availability (non-5xx), p99 < 200ms, rolling 30-day window.

```promql
# Availability SLI — error ratio per namespace, PROBE TRAFFIC EXCLUDED.
# Source metric matters: podinfo's http_requests_total has only a `status`
# label and counts /healthz, /readyz and /metrics hits, so at idle the SLI
# would be measuring the kubelet. The duration histogram's count carries
# {method, path, status}, which makes the exclusion possible.
sum by (namespace) (rate(http_request_duration_seconds_count{job="podinfo", status=~"5..", path!~"/healthz|/readyz|/metrics"}[5m]))
/
sum by (namespace) (rate(http_request_duration_seconds_count{job="podinfo", path!~"/healthz|/readyz|/metrics"}[5m]))

# Latency SLI (p99), same exclusion
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job="podinfo", path!~"/healthz|/readyz|/metrics"}[5m])))
```

A side effect worth knowing: with probes excluded, an idle namespace has a 0/0 SLI. That's `NaN`, and `NaN` fails every threshold comparison — so the burn alerts structurally cannot fire on a namespace receiving no traffic, which replaces the usual minimum-traffic guard clause.

Error budget is 0.1% of requests over 30 days. At a nominal 5,000 req/min — a number picked for the arithmetic; nothing in this repo generates or measures that rate — that's ~216M requests/month, so roughly 216K failed requests of budget to spend.

### Why two burn-rate windows, not one

Burn rate is `observed error ratio / 0.001`. A sustained rate of 1 spends the budget in exactly 30 days; 14.4 spends it in ~2 days; 6 spends it in ~5 days.

| Alert | Window | Threshold | Severity | Catches |
|---|---|---|---|---|
| `PodinfoSLOFastBurn` | 1h, gated on 5m | 14.4× | critical | Hard breakage, fast |
| `PodinfoSLOSlowBurn` | 6h, gated on 30m | 6× | warning | The slow bleed |

Either window alone is a bad alert. The fast one is twitchy — a short sharp spike pages for something already over. The slow one is far too slow to be your only signal. Together they cover both shapes.

Each alert is additionally gated on a **short** window that must also be burning (5m for fast, 30m for slow). This is the half people usually leave out, and it matters: a 1h window has a long memory. Without the short-window gate, a resolved ten-minute outage keeps paging for the better part of an hour after it's fixed.

These rules are unit-tested with `promtool` (`make test-rules`, also in CI): the fixtures pin that 1.5% fires and 1.3% doesn't, that the short-window gate suppresses paging once an outage is over, that probe traffic can't burn budget, and that a prod-only outage is detected. See [`observability/alerts/tests/`](observability/alerts/tests/).

---

## Debugging Notes

Three bugs that only surfaced by running this against a live cluster. All three looked correct in review.

### 1. The availability alert didn't fire during an actual outage

The obvious rule for "is it up" is `up{job="podinfo"} == 0`. Scaled the deployment to zero to test it, expected a page in ~2 minutes. Nothing.

`up` only exists for targets service discovery actually **found**. Scale to zero means zero endpoints, so the ServiceMonitor discovers nothing, and the `up` series doesn't go to 0 — it *disappears*. `== 0` only catches "a target exists but the scrape failed," e.g. a Ready pod with a hung app. It misses "no healthy pods exist," which is both the more common outage and literally what the SLO is about.

Fixed to `absent(up{job="podinfo"} == 1)`, which catches both. This is what `make break` demonstrates — it's a real failure mode of a rule that reads fine.

The fix then turned out to have a blind spot of its own: a single cluster-wide `absent()` stays quiet during a prod-only outage as long as the dev namespace is healthy, and it strips every label off the alert. The current rules are one per namespace, gated on `present_over_time` so a namespace that was never deployed can't alert — and both behaviors are pinned by unit tests, which is what would have caught the first version.

### 2. ServiceMonitor silently scoped to the wrong namespace

First deploy, Prometheus's targets page had zero entries for podinfo. No error anywhere — just nothing.

`ServiceMonitor.spec.selector` without an explicit `namespaceSelector` only matches Services in its **own** namespace. Mine was in `monitoring`; podinfo's Service is in `default`. Added `namespaceSelector.matchNames: [default, prod]`. The silence is the dangerous part: a misscoped ServiceMonitor looks identical to a correctly-scoped one with nothing to scrape.

### 3. A metrics port that was never enabled

The chart originally split `http` (9898) from a separate `http-metrics` (9797), copied from the upstream podinfo chart's layout. Once the namespace fix landed, Prometheus found the target and every scrape returned `connection refused`.

Port-forwarded 9898 directly, hit `/metrics`, got a real response — nothing was listening on 9797. The root cause is less flattering than a phantom port: podinfo *does* support a dedicated metrics port (`--port-metrics`), but it defaults to disabled, and the chart carried the port number over without the flag that turns it on. Removed the second port; metrics come off the main port unless that flag is set.

---

## Design decisions

- **`ServiceMonitor` and `PrometheusRule`s are applied standalone, not baked into the chart.** The chart installs fine on a cluster with no Prometheus Operator present. "Deploy the app" and "this specific stack happens to be watching it" shouldn't be one operation.

- **`values-prod.yaml` overrides only what actually differs** — resources and HPA thresholds. (An earlier revision also carried a `replicaCount` override that rendered nothing, since the HPA owns replicas whenever autoscaling is on; deleted once a review caught it.) The diff between the two files *is* the production decision, rather than a duplicated config with one field changed.

- **CI's staging and prod stages run against real ephemeral `kind` clusters** spun up inside the runner, not stub steps. An actual `helm upgrade --install` and an actual rollout check, with `--atomic` as the rollback mechanism; the explicit rollback step behind it is a belt-and-braces fallback that has yet to be exercised by a real failure. A real prod target swaps in a persistent cluster via a kubeconfig secret; nothing else in the pipeline changes.

- **Prometheus's ServiceMonitor selector is relaxed** (`serviceMonitorSelectorNilUsesHelmValues: false`) so it watches any ServiceMonitor in the cluster. Fine for a single-team lab; a real multi-tenant cluster should scope this per namespace so one team's bad ServiceMonitor can't affect another's.

- **Local deploys use `--rollback-on-failure`** (Helm 4's rename of `--atomic`); CI stays on `--atomic` since it pins Helm 3.15. Same guarantee either way.

---

## CI/CD

```
push ──> lint + template (both value sets)
              │
              ▼
         staging: ephemeral kind cluster, helm upgrade --install, rollout check
              │
              ▼
         ⏸  manual approval gate
              │
              ▼
         prod: --atomic deploy (auto-rollback on failure)
```

One thing that can't live in YAML: the approval gate needs a `production` GitHub Environment with a required-reviewers rule — **Settings → Environments → New environment → `production` → Required reviewers**. The workflow already targets `environment: production`, but it won't actually pause until that rule exists.

---

## Known limitations

- **The p99 latency SLO has an SLI but no alert.** Availability has full multi-window coverage; latency burn-rate rules are the next real gap.
- **Alertmanager has no receiver configured** — alerts land in its UI, not a pager. Fine for a lab; a delivery route is deliberately out of scope.
- **Actions are pinned to major tags, not SHAs**, and there's no NetworkPolicy or dedicated ServiceAccount in the chart yet. Tracked in issues.

An earlier revision of this section listed six defects found in an adversarial self-review (a cluster-wide availability alert that couldn't see a prod-only outage, an SLI that counted kubelet probes, a dashboard grouping by a label that didn't exist, an inert ConfigMap key, an unkillable load job, and no rule validation in CI). All six are now fixed, and the alert-rule fixes carry `promtool` unit tests so they stay fixed.

## Roadmap

- Latency burn-rate alerts, completing the SLO the README already states.
- k6 load stage in CI, so staging is verified under load rather than by rollout status alone.
- `kubeconform` / `helm unittest` in the lint job — validate rendered manifests, not just chart syntax.
- Terraform for the underlying node pool, so cluster setup is as codified as the app layer.
- A recorded `make break` demo (asciinema) and a Grafana screenshot in this README.

---

## License

MIT — see [LICENSE](LICENSE).
