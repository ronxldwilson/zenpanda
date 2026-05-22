#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

RESULTS_FILE="sweep_results.txt"
> "$RESULTS_FILE"

START_URL="https://demo-browser.lightpanda.io/amiibo/"
WORKERS=10

echo "================================================================" | tee -a "$RESULTS_FILE"
echo "  CRAWLER BENCHMARK SWEEP: ZenPanda vs Lightpanda" | tee -a "$RESULTS_FILE"
echo "  $(date)" | tee -a "$RESULTS_FILE"
echo "  Site: $START_URL" | tee -a "$RESULTS_FILE"
echo "  Workers: $WORKERS" | tee -a "$RESULTS_FILE"
echo "================================================================" | tee -a "$RESULTS_FILE"

for N in 50 100 150 200 250 300 350 400 450 500; do
    echo "" | tee -a "$RESULTS_FILE"
    echo "################################################################" | tee -a "$RESULTS_FILE"
    echo "  CRAWL: $N pages, $WORKERS workers" | tee -a "$RESULTS_FILE"
    echo "################################################################" | tee -a "$RESULTS_FILE"

    # Restart containers fresh
    docker rm -f zenpanda-test lightpanda-test 2>/dev/null || true
    docker run --rm -d --name zenpanda-test --platform linux/arm64 -p 9222:9222 zenpanda:dev >/dev/null
    docker run --rm -d --name lightpanda-test --platform linux/arm64 -p 9223:9222 lightpanda/browser:latest >/dev/null
    sleep 3

    echo "" | tee -a "$RESULTS_FILE"
    ./loadtest -c "$WORKERS" -n "$N" --cdp ws://127.0.0.1:9222 --container zenpanda-test --label "ZenPanda (n=$N)" --url "$START_URL" 2>&1 | tee -a "$RESULTS_FILE"

    sleep 3

    echo "" | tee -a "$RESULTS_FILE"
    ./loadtest -c "$WORKERS" -n "$N" --cdp ws://127.0.0.1:9223 --container lightpanda-test --label "Lightpanda (n=$N)" --url "$START_URL" 2>&1 | tee -a "$RESULTS_FILE"

    sleep 3
done

echo "" | tee -a "$RESULTS_FILE"
echo "================================================================" | tee -a "$RESULTS_FILE"
echo "  SWEEP COMPLETE" | tee -a "$RESULTS_FILE"
echo "================================================================" | tee -a "$RESULTS_FILE"
echo ""
echo "Results saved to $RESULTS_FILE"
