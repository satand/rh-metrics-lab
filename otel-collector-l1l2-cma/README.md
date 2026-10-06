# Dual-layer collector + OpenShift CMA/KEDA autoscaling

Experiment to autoscale the two OpenTelemetry Collector layers (**L1 `otel-edge`**,
**L2 `otel-agg`**) with the OpenShift **Custom Metrics Autoscaler (CMA)** operator (KEDA),
driven by the collectors' **internal `otelcol_*` metrics in User Workload Monitoring** —
not CPU and not raw container memory.

Self-contained variant of `../otel-collector-l1l2/` (same namespace `otel-l1l2-ns`, same CR
names). Apply **EITHER** `otel-collector-l1l2/` **OR** this `-cma` variant, **not both**.

## Why these signals (not CPU, not container-memory)
- A metrics gateway's load is **cardinality ≈ number of monitored app instances** (each app
  pushes a fixed series set every `step`). Request *rate* changes values, not point volume.
- The collector is Go → **lazy GC**, so `container_memory_working_set_bytes` rises but rarely
  falls → good only as an OOM guardrail, **not** as an up/down trigger.
- KEDA lets us react to the collector's **own saturation** signals, scaling **before** it
  drops data (`memory_limiter` → `refused`) or OOMs.

## 3-level trigger model (read via Thanos Querier, auth `keda-prom-creds-uwm`)
| Level | Metric (UWM) | Type / threshold | Role |
|---|---|---|---|
| **1 PRIMARY** capacity | `rate(otelcol_receiver_accepted_metric_points_total[2m])` | `AverageValue`, **demo** `20` pts/s per replica (production `~2000`; see note) | tracks cardinality; **recedes → also scales DOWN** |
| **2 EMERGENCY** backpressure / anti-drop | L1: `otelcol_exporter_in_flight_requests` (worker-ceiling proxy, per replica) + `rate(refused)`; L2: `rate(refused)` | `AverageValue` `8` (in-flight) + `Value` `>1` (refused) | react to L1 egress saturation / any shedding → fast scale-up |
| **3 GUARDRAIL** OOM | `sum(otelcol_process_memory_rss_bytes)` | `AverageValue`, ~0.8·limit per replica | dormant at rest (RSS floor ~114 MB); ramps under real load — see "Forcing…" to demo it fire |

> Why **in-flight**, not queue depth: `otelcol_exporter_queue_size/capacity/utilization` are **not**
> exposed by the `loadbalancing` `helper_exporter` in this build (verified even at collector telemetry
> `level: detailed`), so L1 backpressure uses `otelcol_exporter_in_flight_requests` (present at
> `level: basic`). Threshold `8` ≈ just under `sending_queue.num_consumers` (default 10).

> **Throughput threshold is scale-dependent.** `accepted_metric_points` is *series volume*
> (cardinality), **not** invocation rate, and push cadence here is `step=10s`. Measured band:
> ~`14` pts/s @1 app pod → ~`110–220` pts/s @8–16 app pods. Since the `AverageValue` target is
> **per-replica** (`desired=ceil(total/T)`), the production `2000` would need `>4000` total
> (~290 app pods) to ever leave `min=2` → the demo would never scale. So we set **T=20** (both
> `04`/`05`), which makes the app-pod ramp `1→16` (`REPLICAS_UP=16`) drive the collectors `2→6`
> and back to `2` on scale-down. **Reset to ~2000 for a real cluster.**

L2 has **no egress queue** (the `prometheus` exporter is a **pull** server) → no backpressure trigger there.

## How metrics become desired replicas (the counting rules)
KEDA builds **one HPA per ScaledObject**; **each trigger = one external metric** (`s0-prometheus`,
`s1-prometheus`, …, in file order). The HPA evaluates **every** metric independently, computes a
`desired` for each, and then acts on the **MAX**. Consequences:
- **Scale-UP**: a **single** trigger over its target is enough (it wins the max).
- **Scale-DOWN**: **all** metrics must be under target (the max must drop) *and* the
  `scaleDown.stabilizationWindowSeconds` (+ KEDA `cooldownPeriod`) must have elapsed → down is slow, up is fast.

Per-metric `desired` depends on **`metricType`** (threshold semantics differ):
- **`Value`** → `desired = ceil(metricValue / threshold)`. `threshold` is a **TOTAL budget**;
  independent of how many replicas exist. Query returns a total; "N events ⇒ N workers".
- **`AverageValue`** → `desired = ceil(totalValue / threshold)`. `threshold` is a **PER-REPLICA**
  target, so the query **must return the SUM across pods** (HPA compares per-replica load → target).
- (`Utilization` = vs requests/limits, CPU/mem — **not used** here on purpose.)

Mapping in *our* triggers and why:
| Trigger | Type | Query shape | Effect |
|---|---|---|---|
| throughput (`accepted`) | AverageValue | `sum(rate(...))` | scales with cardinality; **recedes → enables scale-DOWN** |
| refused | Value | `sum(rate(...))`, thr `1` | any sustained shedding → `ceil(refused/1)` jump, clamped to max |
| in-flight (L1 only) | AverageValue | `sum(...{exporter="loadbalancing"})`, thr `8` | fires when a replica's export workers near `num_consumers` (~10) |
| memory (OOM guardrail) | AverageValue | `sum(otelcol_process_memory_rss_bytes)`, thr ~0.8·limit | dormant at rest; ramps on load-driven RSS (low-target demo variant pins to max — see Forcing) |

> ⚠️ **Memory guardrail (both layers)** — the Go collector holds a **baseline RSS floor ≈ 114 MB** per
> pod that lazy GC never frees. The **committed default** is `AverageValue` over `sum(...)` at ~**0.8·limit**:
> that sits ABOVE the floor → **dormant at rest** (collectors fall back to `minReplicaCount`) and ramps
> only when *load-driven* buffering grows RSS → stable & calm.
> Two traps we verified, so don't do them as the resting config:
> - Making it "trip at rest" with a **low `Value`/`max` target**: with KEDA this drove L2 to
>   `maxReplicaCount` and the scale-down wobbled via the stabilization window — good only as a **transient
>   demo knob** (see "Forcing the EMERGENCY / GUARDRAIL triggers"), then revert to `AverageValue`/`sum`.
> - **Lowering the cgroup `limits.memory`** to force an 80%-trip: parks RSS >80% of the hard limit →
>   **OOMKill** risk and makes `memory_limiter` **shed** (contaminates `refused`). Keep the real limit
>   generous; trigger memory by *load* (or the transient knob), never by shrinking the container limit.

Check what the autoscaler wants right now:
```
oc get hpa -n otel-l1l2-ns                    # TARGETS = current/target per trigger (avg vs abs)
oc get scaledobject -n otel-l1l2-ns           # per-trigger "Is Active" = last value was != 0
```

## Target = the CR via `/scale` (CONFIRMED on this cluster)
`opentelemetrycollectors.opentelemetry.io` exposes the `scale` subresource, so the
`ScaledObject` targets the `OpenTelemetryCollector` CR (KEDA writes `spec.replicas`, the
operator propagates to the Deployment — no pinning fight). If ever absent: point
`scaleTargetRef` at the operator-created Deployment `otel-{edge,agg}-collector` instead.

## Prerequisites (VERIFIED on this cluster)
- Operators: **OpenTelemetry Operator** v0.158 (ns `openshift-opentelemetry-operator`),
  **Custom Metrics Autoscaler** v2.19 = KEDA (ns `openshift-keda`), cert-manager. UWM enabled.
- KEDA is provisioned by the operator's default **`KedaController`** (`openshift-keda`) — the
  stack (`keda-operator`, `keda-metrics-apiserver`, `keda-admission`) is Ready right after the
  operator install. A `ClusterAutoscaler` CR is **not** required here (that was the legacy
  pre-KEDA path); our scalers use `type: prometheus` with an explicit `serverAddress`.
- Collector image `registry.redhat.io/rhosdt/opentelemetry-collector-rhel9` (contrib-based;
  has `prometheus`; `loadbalancing` expected — confirm on first apply).
- **Service naming**: operator auto-creates `<crname>-collector-headless` (pod IPs); L1's
  `loadbalancing` resolver targets `otel-agg-collector-headless...:4317`. No `headlessService` flag.

## Validate KEDA → Thanos Querier (do this before trusting the autoscaler)
1. `otelcol_*` present (UWM must scrape the collectors' self-metrics):
   `oc get servicemonitor -n otel-l1l2-ns` → there is a `*-monitoring-collector` SM. Then query
   the **Thanos Querier** (same endpoint the console *Observe → Metrics* uses):
   ```
   TOKEN=$(oc create token keda-prometheus-uwm -n otel-l1l2-ns)
   oc -n openshift-monitoring port-forward svc/thanos-querier 9091:9091 &
   curl -sk -H "Authorization: Bearer $TOKEN" 'https://localhost:9091/api/v1/query' \
     --data-urlencode 'query=sum(rate(otelcol_receiver_accepted_metric_points_total{namespace="otel-l1l2-ns"}[2m]))'
   ```
2. The scaler must use the **Thanos Querier** `serverAddress`, NOT `prometheus-user-workload:9091`:
   that service only proxies `/metrics` and `/federate` via kube-rbac-proxy, so `/api/v1/query`
   returns **404** (this was the original failure). Thanos Querier federates User Workload metrics
   and exposes the query API.
3. Auth: SA `keda-prometheus-uwm` bound to the built-in **`cluster-monitoring-view`**
   (`03-auth-uwm.yaml`). Watch `oc describe scaledobject/hpa` for `FailedGetExternalMetric`.

## Deploy order
KEDA is **already running** (the CMA operator auto-creates a `KedaController` in
`openshift-keda`, which deploys `keda-operator`, `keda-metrics-apiserver`, `keda-admission`,
and serves `external.metrics.k8s.io`). No `ClusterAutoscaler` CR is needed for the
`type: prometheus` scalers (the `keda-operator` polls the UWM Prometheus directly).
```
oc apply -k otel-collector-l1l2-cma/
# ScaledObjects become effective immediately; KEDA starts polling and creates the HPAs.
```

## Drive + observe (scripts/)
The load knob is **app replica count = cardinality**. Each Micrometer pod emits only when
invoked, so the scripts also send gRPC traffic (via a port-forwarded Service) with **many
discrete calls** so kube-proxy spreads them over every app pod (defeats sticky-per-connection).

```
# terminal 1: watch replicas + HPA target/current
scripts/watch-scaling.sh

# terminal 2: run the scenario scale-up -> hold -> scale-down -> idle
scripts/load-drive.sh cycle

# one-shots / tuning via env:
REPLICAS_UP=10 RATE_MS=100 PARALLEL=4 scripts/load-drive.sh up
scripts/load-drive.sh down          # scale app to REPLICAS_MIN (keep emitting)
scripts/load-drive.sh idle          # stop traffic + min replicas -> collector drains, scales DOWN
```
Watch the Micrometer replicas drive `otelcol_..._accepted_metric_points` up/down on UWM and the
two collectors follow (up on capacity/emergency, down after `cooldownPeriod` once rate recedes).

## Forcing the EMERGENCY / GUARDRAIL triggers (lab-only, then revert)
The **primary** throughput signal is what a normal load test exercises; the emergency triggers
need real saturation, so here is how to make each one fire **deterministically**:

- **`refused` (s2) — easy & reliable.** Temporarily make the **edge** `memory_limiter` shed at the
  lab's tiny volume by dropping its soft ceiling below the collector's RSS (~130 MB):
  ```
  oc patch otelcol otel-edge -n otel-l1l2-ns --type=json -p '[
    {"op":"replace","path":"/spec/config/processors/memory_limiter/limit_percentage","value":2},
    {"op":"replace","path":"/spec/config/processors/memory_limiter/spike_limit_percentage","value":1}]'
  ```
  With `limit_percentage: 2` the threshold is `0.02×1Gi≈21 MB` < RSS → every push is refused →
  `otelcol_receiver_refused_metric_points` climbs while `accepted` drops to ~0 → `desired=ceil(refused/1)`
  (clamped to max) drives the edge **2→6 via s2 alone** (`accepted` near 0 proves it is the
  emergency signal, not capacity). Watch the HPA event `reason: external metric s2-prometheus … above target`.
  **Revert** (restores 80/25): `oc apply -f otel-collector-l1l2-cma/01-collector-edge.yaml`.

- **`in_flight` (s1) — NOT practically demoable at this scale** (verified): it is an
  instantaneous concurrency gauge, so it needs *sustained* egress stall. Attempts that failed here:
  (a) a `NetworkPolicy` dropping edge→agg:4317 — ineffective because the operator already manages
  its own collector NetworkPolicies and ingress is the **union** of all policies; (b) CPU-starving
  L2 to `1m` — single small warm-HTTP/2 gRPC calls still complete sub-ms at lab volume, so
  concurrency never builds. It stays a **latent prod tripwire** (kept safe with `ignoreNullValues:'true'`).

- **GUARDRAIL OOM / memory (s2 on L2).** The committed guardrail is **dormant** (`AverageValue`/`sum`
  @~0.8·1Gi). To **demonstrate it firing** (and the "L1 on throughput vs L2 on memory" contrast) temporarily
  flip the L2 memory trigger to a **low `Value`/`max` target** at runtime, then **revert**:
  ```
  # FIRE: make the guardrail trip at rest on the ~114 MB baseline RSS (Value/max, 50 MB target)
  oc patch scaledobject otel-agg-scaler -n otel-l1l2-ns --type=json -p '[
    {"op":"replace","path":"/spec/triggers/2/metricType","value":"Value"},
    {"op":"replace","path":"/spec/triggers/2/metadata/query","value":"max(otelcol_process_memory_rss_bytes{namespace=\"otel-l1l2-ns\",pod=~\"otel-agg-collector-.*\"})"},
    {"op":"replace","path":"/spec/triggers/2/metadata/threshold","value":"50000000"}]'
  # observe: agg HPA event "New size: N; reason: external metric s2-prometheus … above target"
  #          while edge stays at min (its accepted 15 < 20)  -> two layers, two metrics
  # REVERT to the committed dormant form:
  oc apply -f otel-collector-l1l2-cma/05-so-otel-agg.yaml
  ```
  What we observed: L2 jumped to **`maxReplicaCount` (6)** purely on memory, with `accepted≈0` (so it is the
  memory tripwire, not capacity). **Caveat (verified):** KEDA treats this external `Value` memory metric in a
  replica-sensitive way + the 180 s scale-down stabilization makes it **pin near max / wobble on the way
  down** — so use it only as a *transient* demo and **revert**; do **not** leave a low memory target as the
  resting config, and never reach this by shrinking the container limit (OOM + `memory_limiter` shedding).

## Acceptance
- Collectors scale up on load and **down** after load is removed (thanks to the receding
  `accepted_metric_points` signal).
- Autoscaling must **not** reintroduce duplication:
  `max by(service_name)(count by(service_name,instance)(rpc_server_duration_milliseconds_count)) == 1`.

## Notes
- Cumulative temporality keeps L2 scale-down safe.
- `memory_limiter` `limit_percentage` uses the cgroup limit → keep `spec.resources.limits.memory` set.
- Teardown: `oc delete -k otel-collector-l1l2-cma/` (KEDA itself stays, managed by its operator).
