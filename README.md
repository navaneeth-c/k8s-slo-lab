# k8s-slo-lab

Run a real SLO end to end on a laptop: an availability target, an error budget, multi-window burn-rate alerts, and — the part most examples skip — a one-command way to **break the service and watch the alert actually fire**.

Most SLO examples ship alert rules nobody has ever seen trigger. The rules in this repo were each tested against an induced outage, and two of them were wrong the first time. Those bugs, and why they were invisible on paper, are written up in [Debugging Notes](#debugging-notes).

```bash
make up      # kind cluster + Prometheus/Grafana + podinfo, ~4 min
make break   # scale to zero, watch PodinfoUnavailable go pending -> firing
make fix     # scale back up, watch it clear
make burn    # drive 5xx traffic, watch the fast-burn SLO alert fire
make down    # delete the cluster
```

Prereqs: Docker, `kind`, `helm`, `kubectl`. No cloud account, no credentials.

The workload under test is [stefanprodan/podinfo](https://github.com/stefanprodan/podinfo) — deliberately boring, because the app is not the point. The SLO loop around it is.

---

## What's in here

| Path | What it is |
|---|---|
| `charts/podinfo/` | Helm chart — autoscaling, probes, env-specific overrides |
| `observability/alerts/` | The SLO rules: availability + multi-window burn rate |
| `observability/servicemonitor.yaml` | Prometheus Operator wiring |
| `observability/dashboards/` | RED dashboard, auto-loaded by Grafana's sidecar |
| `.github/workflows/ci-cd.yaml` | Lint → staging → manual gate → prod, with rollback |
| `scripts/`, `Makefile` | The demo harness |

---

## SLO, SLI, and error budget

**SLO:** 99.9% availability (non-5xx), p99 < 200ms, rolling 30-day window.

```promql
# Availability SLI
sum(rate(http_requests_total{job="podinfo", status!~"5.."}[5m]))
/ sum(rate(http_requests_total{job="podinfo"}[5m]))

# Latency SLI (p99)
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job="podinfo"}[5m])) by (le))
```

Error budget is 0.1% of requests over 30 days. At ~5,000 req/min that's ~216M requests/month, so roughly 216K failed requests of budget to spend.

### Why two burn-rate windows, not one

Burn rate is `observed error ratio / 0.001`. A sustained rate of 1 spends the budget in exactly 30 days; 14.4 spends it in ~2 days; 6 spends it in ~5 days.

| Alert | Window | Threshold | Severity | Catches |
|---|---|---|---|---|
| `PodinfoSLOFastBurn` | 1h, gated on 5m | 14.4× | critical | Hard breakage, fast |
| `PodinfoSLOSlowBurn` | 6h, gated on 30m | 6× | warning | The slow bleed |

Either window alone is a bad alert. The fast one is twitchy — a short sharp spike pages for something already over. The slow one is far too slow to be your only signal. Together they cover both shapes.

Each alert is additionally gated on a **short** window that must also be burning (5m for fast, 30m for slow). This is the half people usually leave out, and it matters: a 1h window has a long memory. Without the short-window gate, a resolved ten-minute outage keeps paging for the better part of an hour after it's fixed.

See [`observability/alerts/burn-rate-alert.yaml`](observability/alerts/burn-rate-alert.yaml).

---

## Debugging Notes

Three bugs that only surfaced by running this against a live cluster. All three looked correct in review.

### 1. The availability alert didn't fire during an actual outage

The obvious rule for "is it up" is `up{job="podinfo"} == 0`. Scaled the deployment to zero to test it, expected a page in ~2 minutes. Nothing.

`up` only exists for targets service discovery actually **found**. Scale to zero means zero endpoints, so the ServiceMonitor discovers nothing, and the `up` series doesn't go to 0 — it *disappears*. `== 0` only catches "a target exists but the scrape failed," e.g. a Ready pod with a hung app. It misses "no healthy pods exist," which is both the more common outage and literally what the SLO is about.

Fixed to `absent(up{job="podinfo"} == 1)`, which catches both. This is what `make break` demonstrates — it's a real failure mode of a rule that reads fine.

### 2. ServiceMonitor silently scoped to the wrong namespace

First deploy, Prometheus's targets page had zero entries for podinfo. No error anywhere — just nothing.

`ServiceMonitor.spec.selector` without an explicit `namespaceSelector` only matches Services in its **own** namespace. Mine was in `monitoring`; podinfo's Service is in `default`. Added `namespaceSelector.matchNames: [default, prod]`. The silence is the dangerous part: a misscoped ServiceMonitor looks identical to a correctly-scoped one with nothing to scrape.

### 3. A metrics port that never existed

The chart originally split `http` (9898) from a separate `http-metrics` (9797), on the assumption podinfo exposes metrics on a dedicated port. Once the namespace fix landed, Prometheus found the target and every scrape returned `connection refused`.

Port-forwarded 9898 directly, hit `/metrics`, got a real response. Nothing was ever listening on 9797. Removed the phantom port — metrics come off the same port as everything else.

---

## Design decisions

- **`ServiceMonitor` and `PrometheusRule`s are applied standalone, not baked into the chart.** The chart installs fine on a cluster with no Prometheus Operator present. "Deploy the app" and "this specific stack happens to be watching it" shouldn't be one operation.

- **`values-prod.yaml` overrides only what actually differs** — replicas, resources, HPA thresholds. The diff between the two files *is* the production decision, rather than a duplicated config with one field changed.

- **CI's staging and prod stages run against real ephemeral `kind` clusters** spun up inside the runner, not stub steps. An actual `helm upgrade --install`, an actual rollout check, an actual rollback path. A real prod target swaps in a persistent cluster via a kubeconfig secret; nothing else in the pipeline changes.

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
         prod: --atomic deploy, explicit rollback on failure
```

One thing that can't live in YAML: the approval gate needs a `production` GitHub Environment with a required-reviewers rule — **Settings → Environments → New environment → `production` → Required reviewers**. The workflow already targets `environment: production`, but it won't actually pause until that rule exists.

---

## Roadmap

- k6 load stage in CI, so staging is verified under load rather than by rollout status alone.
- `kubeconform` / `helm unittest` in the lint job — validate rendered manifests, not just chart syntax.
- Terraform for the underlying node pool, so cluster setup is as codified as the app layer.
- Latency burn-rate alerts. Availability has full multi-window coverage; the p99 SLO currently has an SLI but no alert.

---

## License

MIT — see [LICENSE](LICENSE).
