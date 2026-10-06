#!/usr/bin/env bash
# ============================================================================
# watch-scaling.sh — observe CMA/KEDA autoscaling of the dual-layer collectors.
# Prints, every INTERVAL seconds: collector desired vs ready replicas, the KEDA
# HPA current/target, and scale events. Combine with scripts/load-drive.sh cycle.
#
# Env: NS (otel-l1l2-ns), INTERVAL (10), CR_LIST ("otel-edge otel-agg")
# Optional (heavier, needs UWM bearer token): PROM=1 to also print the trigger
#   metric value by port-forwarding the UWM Prometheus (see hint at the bottom).
# ============================================================================
set -uo pipefail

NS="${NS:-otel-l1l2-ns}"
CR_LIST="${CR_LIST:-otel-edge otel-agg}"
INTERVAL="${INTERVAL:-10}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: 'oc' not found"; exit 2; }

cr_args=(); for c in $CR_LIST; do cr_args+=("$c"); done

trap 'exit 130' INT TERM

while true; do
  printf '\n===== %s =====\n' "$(date +%H:%M:%S)"

  echo "-- collector replicas (desired via CR spec, ready via /scale status) --"
  oc get otelcol "${cr_args[@]}" -n "$NS" \
    -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.scale.replicas' 2>/dev/null \
    || echo "  (collector not found in ns $NS)"

  echo "-- KEDA HPA (name / target metric current->desired) --"
  oc get hpa -n "$NS" -o custom-columns='NAME:.metadata.name,REF:.spec.scaleTargetRef.name,METRIC:.status.currentMetrics[*].external.current.value,DESIRED:.status.desiredReplicas,MAX:.spec.maxReplicas' 2>/dev/null \
    || echo "  (no HPA yet)"

  echo "-- recent autoscaling events --"
  oc get events -n "$NS" --sort-by='.lastTimestamp' 2>/dev/null \
    | grep -Ei 'schedul(e|ing)|scale|keda|failedget|externalmetric' | tail -n 6 || true

  sleep "$INTERVAL"
done

# Metric peek (manual). Query the Thanos Querier (federates UWM) with the KEDA SA token.
# NOTE: do NOT query prometheus-user-workload:9091 directly - it only proxies /metrics and
#   /federate via kube-rbac-proxy, so /api/v1/query returns 404. Use the Querier instead:
#   TOKEN=$(oc create token keda-prometheus-uwm -n otel-l1l2-ns)
#   oc -n openshift-monitoring port-forward svc/thanos-querier 9091:9091 &
#   curl -sk -H "Authorization: Bearer $TOKEN" 'https://localhost:9091/api/v1/query' \
#     --data-urlencode 'query=sum(rate(otelcol_receiver_accepted_metric_points_total{namespace="otel-l1l2-ns"}[2m]))'
