#!/usr/bin/env bash
#
# upstream_bench.sh — Full benchmark suite for ZenPanda upstream sync validation.
#
# Spins up a local amiibo site via Cloudflare tunnel, starts Docker containers
# for ZenPanda and Lightpanda, and sweeps through concurrency levels up to 500.
#
# Usage:
#   ./bench/upstream_bench.sh                    # full sweep (1..500 clients)
#   ./bench/upstream_bench.sh --quick            # quick check (1, 10, 50 only)
#   ./bench/upstream_bench.sh --clients 500      # single concurrency level
#
# Prerequisites:
#   - Docker with zenpanda:dev image built (see build-linux.sh)
#   - cloudflared installed (brew install cloudflare/cloudflare/cloudflared)
#   - Go 1.24+ (for building multitest if binary is stale)
#   - Python 3 (for local HTTP server)
#   - ../demo/public/amiibo/ directory with static site files
#     (clone https://github.com/lightpanda-io/demo to ../demo)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEMO_DIR="$(cd "$REPO_DIR/../demo/public/amiibo" 2>/dev/null && pwd || echo "")"

# Ports — avoid 9222 which the production singleleaf stack may use
ZP_PORT=9232
LP_PORT=9233
HTTP_PORT=8877

PAGES_EACH=5
RESULTS_FILE="$SCRIPT_DIR/upstream_sync_results.txt"
CLEANUP_PIDS=()

# ── Argument parsing ──────────────────────────────────────────────────
MODE="full"
SINGLE_CLIENTS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)    MODE="quick"; shift ;;
        --clients)  MODE="single"; SINGLE_CLIENTS="$2"; shift 2 ;;
        --help|-h)
            sed -n '3,/^$/s/^# //p' "$0"
            exit 0 ;;
        *)          echo "Unknown flag: $1"; exit 1 ;;
    esac
done

case "$MODE" in
    full)   CLIENT_LEVELS=(1 5 10 20 50 200 500) ;;
    quick)  CLIENT_LEVELS=(1 10 50) ;;
    single) CLIENT_LEVELS=("$SINGLE_CLIENTS") ;;
esac

# ── Helpers ───────────────────────────────────────────────────────────
info()  { printf "\033[36m==> %s\033[0m\n" "$*"; }
warn()  { printf "\033[33m==> %s\033[0m\n" "$*"; }
die()   { printf "\033[31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }

cleanup() {
    info "Cleaning up..."
    for pid in "${CLEANUP_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    docker rm -f zenpanda-test lightpanda-test 2>/dev/null || true
}
trap cleanup EXIT

# ── Preflight checks ─────────────────────────────────────────────────
command -v docker       >/dev/null || die "docker not found"
command -v cloudflared  >/dev/null || die "cloudflared not found (brew install cloudflare/cloudflare/cloudflared)"
command -v python3      >/dev/null || die "python3 not found"

docker image inspect zenpanda:dev >/dev/null 2>&1 \
    || die "zenpanda:dev image not found. Run: ./build-linux.sh aarch64 && docker build -f Dockerfile.package -t zenpanda:dev ."

docker image inspect lightpanda/browser:latest >/dev/null 2>&1 \
    || { info "Pulling lightpanda/browser:latest..."; docker pull lightpanda/browser:latest; }

if [[ -z "$DEMO_DIR" || ! -f "$DEMO_DIR/index.html" ]]; then
    die "Demo site not found at ../demo/public/amiibo/. Clone: git clone https://github.com/lightpanda-io/demo ../demo"
fi

# ── Build multitest if needed ─────────────────────────────────────────
if [[ ! -f "$SCRIPT_DIR/multitest" ]] || \
   [[ "$SCRIPT_DIR/multitest.go" -nt "$SCRIPT_DIR/multitest" ]]; then
    info "Building multitest..."
    (cd "$SCRIPT_DIR" && go build -o multitest multitest.go)
fi

# ── Start local HTTP server ──────────────────────────────────────────
info "Starting local HTTP server on port $HTTP_PORT..."
python3 -m http.server "$HTTP_PORT" --directory "$DEMO_DIR" &>/dev/null &
CLEANUP_PIDS+=($!)
sleep 1

curl -sf "http://127.0.0.1:$HTTP_PORT/index.html" >/dev/null \
    || die "Local HTTP server failed to start"

# ── Start Cloudflare tunnel ──────────────────────────────────────────
info "Starting Cloudflare tunnel..."
TUNNEL_LOG=$(mktemp)
cloudflared tunnel --url "http://127.0.0.1:$HTTP_PORT" &>"$TUNNEL_LOG" &
CLEANUP_PIDS+=($!)

TUNNEL_URL=""
for i in $(seq 1 30); do
    TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1) || true
    if [[ -n "$TUNNEL_URL" ]]; then break; fi
    sleep 1
done
rm -f "$TUNNEL_LOG"

[[ -n "$TUNNEL_URL" ]] || die "Cloudflare tunnel failed to start after 30s"
info "Tunnel URL: $TUNNEL_URL"

curl -sf "$TUNNEL_URL/index.html" >/dev/null \
    || die "Tunnel is not serving the amiibo site"

# ── Run benchmark sweep ──────────────────────────────────────────────
> "$RESULTS_FILE"

{
    echo "================================================================"
    echo "  UPSTREAM SYNC BENCHMARK - $(date)"
    echo "  ZenPanda (post-sync) vs Lightpanda (upstream latest)"
    echo "  Site: $TUNNEL_URL (local amiibo via Cloudflare tunnel)"
    echo "  Pages per client: $PAGES_EACH"
    echo "  Client levels: ${CLIENT_LEVELS[*]}"
    echo "================================================================"
} | tee -a "$RESULTS_FILE"

for CLIENTS in "${CLIENT_LEVELS[@]}"; do
    echo "" | tee -a "$RESULTS_FILE"
    echo "### $CLIENTS concurrent clients ###" | tee -a "$RESULTS_FILE"
    echo "" | tee -a "$RESULTS_FILE"

    # Restart containers fresh for each level
    docker rm -f zenpanda-test lightpanda-test 2>/dev/null || true
    docker run --rm -d --name zenpanda-test --platform linux/arm64 \
        -p "$ZP_PORT:9222" zenpanda:dev >/dev/null
    docker run --rm -d --name lightpanda-test --platform linux/arm64 \
        -p "$LP_PORT:9222" lightpanda/browser:latest >/dev/null
    sleep 3

    # Verify containers are ready
    curl -sf "http://127.0.0.1:$ZP_PORT/json/version" >/dev/null \
        || { warn "ZenPanda container not ready, skipping $CLIENTS clients"; continue; }
    curl -sf "http://127.0.0.1:$LP_PORT/json/version" >/dev/null \
        || { warn "Lightpanda container not ready, skipping $CLIENTS clients"; continue; }

    # ZenPanda
    "$SCRIPT_DIR/multitest" \
        --clients "$CLIENTS" \
        --pages "$PAGES_EACH" \
        --cdp "ws://127.0.0.1:$ZP_PORT" \
        --container zenpanda-test \
        --label "ZenPanda ($CLIENTS clients)" \
        --url "$TUNNEL_URL/index.html" \
        2>&1 | tee -a "$RESULTS_FILE"

    sleep 2

    # Lightpanda
    "$SCRIPT_DIR/multitest" \
        --clients "$CLIENTS" \
        --pages "$PAGES_EACH" \
        --cdp "ws://127.0.0.1:$LP_PORT" \
        --container lightpanda-test \
        --label "Lightpanda ($CLIENTS clients)" \
        --url "$TUNNEL_URL/index.html" \
        2>&1 | tee -a "$RESULTS_FILE"

    sleep 2
done

echo "" | tee -a "$RESULTS_FILE"
echo "================================================================" | tee -a "$RESULTS_FILE"
echo "  SWEEP COMPLETE" | tee -a "$RESULTS_FILE"
echo "================================================================" | tee -a "$RESULTS_FILE"

info "Results saved to $RESULTS_FILE"
