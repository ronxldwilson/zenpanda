#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

RESULTS_FILE="multi_sweep_results.txt"
> "$RESULTS_FILE"

START_URL="https://demo-browser.lightpanda.io/amiibo/"
PAGES_EACH=5

echo "================================================================" | tee -a "$RESULTS_FILE"
echo "  MULTI-CLIENT CONCURRENCY BENCHMARK" | tee -a "$RESULTS_FILE"
echo "  ZenPanda (BrowserPool) vs Lightpanda (single-session)" | tee -a "$RESULTS_FILE"
echo "  $(date)" | tee -a "$RESULTS_FILE"
echo "  Site: $START_URL" | tee -a "$RESULTS_FILE"
echo "  Pages per client: $PAGES_EACH" | tee -a "$RESULTS_FILE"
echo "================================================================" | tee -a "$RESULTS_FILE"

for CLIENTS in 1 2 5 10 20 30 50; do
    echo "" | tee -a "$RESULTS_FILE"
    echo "################################################################" | tee -a "$RESULTS_FILE"
    echo "  $CLIENTS concurrent clients x $PAGES_EACH pages each" | tee -a "$RESULTS_FILE"
    echo "################################################################" | tee -a "$RESULTS_FILE"

    # Restart containers fresh
    docker rm -f zenpanda-test lightpanda-test 2>/dev/null || true
    docker run --rm -d --name zenpanda-test --platform linux/arm64 -p 9222:9222 zenpanda:dev >/dev/null
    docker run --rm -d --name lightpanda-test --platform linux/arm64 -p 9223:9222 lightpanda/browser:latest >/dev/null
    sleep 3

    echo "" | tee -a "$RESULTS_FILE"
    ./multitest --clients "$CLIENTS" --pages "$PAGES_EACH" --cdp ws://127.0.0.1:9222 --container zenpanda-test --label "ZenPanda ($CLIENTS clients)" --url "$START_URL" 2>&1 | tee -a "$RESULTS_FILE"

    sleep 3

    echo "" | tee -a "$RESULTS_FILE"
    ./multitest --clients "$CLIENTS" --pages "$PAGES_EACH" --cdp ws://127.0.0.1:9223 --container lightpanda-test --label "Lightpanda ($CLIENTS clients)" --url "$START_URL" 2>&1 | tee -a "$RESULTS_FILE"

    sleep 3
done

echo "" | tee -a "$RESULTS_FILE"
echo "================================================================" | tee -a "$RESULTS_FILE"
echo "  SWEEP COMPLETE" | tee -a "$RESULTS_FILE"
echo "================================================================" | tee -a "$RESULTS_FILE"
echo ""
echo "Results saved to $RESULTS_FILE"
