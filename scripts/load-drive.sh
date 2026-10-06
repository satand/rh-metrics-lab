#!/usr/bin/env bash
# ============================================================================
# load-drive.sh — drive the collector autoscaling by changing MONITORED LOAD.
#
# The load knob is CARDINALITY = number of Micrometer app pods. Each app pod emits
# metrics ONLY when invoked (the app is invocation-driven), so this script:
#   1) opens a port-forward to the app Service,
#   2) runs MANY *discrete* grpcurl calls (new TCP connection each) so kube-proxy
#      spreads them over EVERY app pod (defeats sticky-per-connection), and
#   3) scales the app Deployment replicas up / down.
# More app pods -> more series -> higher otelcol_* on the collectors -> CMA/KEDA scales up.
# Removing pods + stopping traffic -> accepted/refused recede -> KEDA scales DOWN.
#
# Usage:
#   scripts/load-drive.sh cycle            # up -> hold -> down -> hold -> idle (scenario)
#   scripts/load-drive.sh up               # scale app to REPLICAS_UP (start port-forward+traffic)
#   scripts/load-drive.sh down             # scale app to REPLICAS_MIN (keep traffic running)
#   scripts/load-drive.sh idle             # stop traffic + scale to REPLICAS_MIN (let collectors drain)
#   scripts/load-drive.sh status
# Env (override as needed):
#   APP_NS APP_DEPLOY APP_SVC LOCAL_PORT REMOTE_PORT PROTO PROTO_DIR METHOD
#   REPLICAS_MIN REPLICAS_UP PARALLEL RATE_MS HOLD_UP HOLD_DOWN
# Requires: oc (logged in), grpcurl. Assumes app points at L1 (dual) and the CMA stack is up.
# ============================================================================
set -uo pipefail

# --- repo root (so the .proto import-path resolves regardless of CWD) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NS="${APP_NS:-app-ns}"
APP_DEPLOY="${APP_DEPLOY:-sample-micrometer-app}"
APP_SVC="${APP_SVC:-sample-micrometer-app-service}"
LOCAL_PORT="${LOCAL_PORT:-9555}"
REMOTE_PORT="${REMOTE_PORT:-9555}"
PROTO_DIR="${PROTO_DIR:-app-micrometer/reference-app/src/main/proto}"
PROTO="${PROTO:-rpc_ping.proto}"
METHOD="${METHOD:-micrometerdemo.AdService/GetAds}"

REPLICAS_MIN="${REPLICAS_MIN:-1}"
REPLICAS_UP="${REPLICAS_UP:-16}"  # cardinality ceiling; tuned so accepted_total drives collectors 2->6
PARALLEL="${PARALLEL:-4}"          # concurrent grpcurl loops (more -> better spread + rate)
RATE_MS="${RATE_MS:-100}"          # per-worker sleep between calls (~PARALLEL*1000/RATE_MS calls/s)
HOLD_UP="${HOLD_UP:-180}"          # seconds to hold high load (observe scale-UP)
HOLD_DOWN="${HOLD_DOWN:-240}"      # seconds to hold low/idle (observe scale-DOWN)

PF_PID=""
TMPD="$(mktemp -d)"
STOPFILE="$TMPD/stop"
PF_LOG="$TMPD/pf.log"

log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
cleanup(){ [ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1 || true; rm -rf "$TMPD"; }
trap 'log "interrupted"; cleanup; exit 130' INT TERM

check_bins(){ for b in oc grpcurl; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found"; exit 2; }; done; }

one_call(){
  ( cd "$REPO_ROOT" && grpcurl -plaintext \
      -import-path "$PROTO_DIR" -proto "$PROTO" \
      -d '{"count":1}' "localhost:${LOCAL_PORT}" "$METHOD" >/dev/null 2>&1 ) || true
}

start_portforward(){
  [ -n "$PF_PID" ] && return 0
  log "port-forward svc/$APP_SVC ${LOCAL_PORT}:${REMOTE_PORT} (ns $APP_NS)"
  oc port-forward -n "$APP_NS" "svc/$APP_SVC" "${LOCAL_PORT}:${REMOTE_PORT}" >"$PF_LOG" 2>&1 &
  PF_PID=$!
  # wait until the tunnel is actually serving
  for _ in $(seq 1 30); do
    if ( cd "$REPO_ROOT" && grpcurl -plaintext -import-path "$PROTO_DIR" -proto "$PROTO" \
         -d '{"count":1}' "localhost:${LOCAL_PORT}" "$METHOD" >/dev/null 2>&1 ); then
      log "port-forward ready"; return 0
    fi
    sleep 1
  done
  log "WARN: port-forward not answering yet (see $PF_LOG): $(tail -n1 "$PF_LOG" 2>/dev/null)"
}

grpc_worker(){   # background: issue discrete calls until stop-file appears
  while [ ! -f "$STOPFILE" ]; do one_call; sleep "$(awk "BEGIN{print $RATE_MS/1000}")"; done
}

start_traffic(){
  touch_stop_reset; start_portforward
  log "starting $PARALLEL grpcurl worker(s) (every ${RATE_MS}ms each)"
  for i in $(seq 1 "$PARALLEL"); do grpc_worker & done
}

touch_stop_reset(){ rm -f "$STOPFILE" 2>/dev/null || true; }
stop_traffic(){ log "stopping traffic"; touch "$STOPFILE"; sleep "$(( RATE_MS/1000 + 1 ))"; }

scale_app(){ log "scale deploy/$APP_DEPLOY -> $1 replicas"; oc scale "deploy/$APP_DEPLOY" -n "$APP_NS" --replicas="$1" >/dev/null 2>&1 || oc patch deploy "$APP_DEPLOY" -n "$APP_NS" -p "{\"spec\":{\"replicas\":$1}}" >/dev/null; }

status(){
  log "app replicas: $(oc get deploy "$APP_DEPLOY" -n "$APP_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  oc get otelcol otel-edge otel-agg -n otel-l1l2-ns -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.scale.replicas' 2>/dev/null
  oc get hpa -n otel-l1l2-ns 2>/dev/null
}

case "${1:-cycle}" in
  up)     check_bins; start_traffic; scale_app "$REPLICAS_UP"; log "up. keep running in background is NOT persistent after exit; use 'cycle' for a demo" ;;
  down)   check_bins; start_portforward; scale_app "$REPLICAS_MIN"; log "down to $REPLICAS_MIN (traffic still off if started elsewhere)" ;;
  idle)   check_bins; stop_traffic; scale_app "$REPLICAS_MIN"; cleanup; log "idle: traffic stopped, collectors should drain + scale down" ;;
  status) check_bins; status ;;
  cycle)
    check_bins
    log "=== SCENARIO: baseline min=$REPLICAS_MIN ==="
    scale_app "$REPLICAS_MIN"; start_traffic; sleep 5
    log "=== RAMP UP to $REPLICAS_UP; hold ${HOLD_UP}s (watch scale-UP) ==="
    scale_app "$REPLICAS_UP"; sleep "$HOLD_UP"
    log "=== SCALE DOWN to $REPLICAS_MIN; keep emitting so remaining pods stay alive ==="
    scale_app "$REPLICAS_MIN"; sleep "$HOLD_DOWN"
    log "=== IDLE (stop traffic so accepted/recalls recede -> scale-DOWN) ==="
    stop_traffic; sleep "$HOLD_DOWN"
    cleanup
    log "=== done ==="
    ;;
  *) echo "usage: $0 {cycle|up|down|idle|status}"; exit 2 ;;
esac
