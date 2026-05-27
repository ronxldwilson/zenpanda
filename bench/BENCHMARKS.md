# Multi-Client Concurrency Benchmarks

Measures ZenPanda vs upstream Lightpanda under concurrent CDP load. This is the primary regression gate for upstream syncs.

## Quick start

```bash
# Full sweep (1, 5, 10, 20, 50, 200, 500 clients)
make bench

# Quick smoke test (1, 10, 50 clients)
make bench-quick

# Single concurrency level
./bench/upstream_bench.sh --clients 500
```

## Prerequisites

| Dependency | Install | Purpose |
|---|---|---|
| Docker | `brew install docker` | Run ZenPanda/Lightpanda containers |
| cloudflared | `brew install cloudflare/cloudflare/cloudflared` | Tunnel local site to public URL |
| Go 1.24+ | `brew install go` | Build the `multitest` harness |
| Python 3 | pre-installed on macOS | Serve static amiibo site locally |
| Demo repo | `git clone https://github.com/lightpanda-io/demo ../demo` | Static amiibo benchmark site (1879 HTML/JSON files) |
| `zenpanda:dev` image | `./build-linux.sh aarch64 && docker build -f Dockerfile.package -t zenpanda:dev .` | Image under test |
| `lightpanda/browser:latest` | `docker pull lightpanda/browser:latest` | Baseline comparison |

## How it works

1. **Local site** — Serves `../demo/public/amiibo/` (static HTML + JSON) via `python3 -m http.server`
2. **Cloudflare tunnel** — Exposes the local server as `https://xxx.trycloudflare.com` so the headless browsers can fetch it through a real HTTPS stack
3. **Fresh containers** — For each concurrency level, both containers are restarted to eliminate warm-up bias
4. **Simultaneous clients** — `multitest` opens N CDP WebSocket connections at once, each crawling 5 pages
5. **Metrics** — Success rate, throughput (pages/sec), latency percentiles, memory usage

Results are saved to `bench/upstream_sync_results.txt`.

## What to look for after an upstream sync

Run `make bench-quick` after every merge. If any of these degrade, investigate before pushing:

| Metric | Healthy | Regression signal |
|---|---|---|
| Clients connected | 100% at all levels | Any client failing to connect at <=50 |
| Success rate | 100% at <=20, >95% at 50 | Drops below old baseline |
| Throughput | Improves or holds steady | >20% drop at any level |
| Memory | Stable or lower | >2x increase |

At 500 clients, some page failures are expected (network contention). The key metric is **clients connected** (should be 500/500) and **total pages served** (should match or beat the baseline).

## Known regression patterns

### CacheLayer deferred serving (caught 2026-05-27)

**Symptom:** At 500 clients, only ~285/500 connected. Throughput dropped from 8 p/s to 3 p/s.

**Root cause:** Upstream commit `c34f1295` ("serve from cache on next client tick") changed `CacheLayer` to defer cache hits through `runNextTick()` instead of serving synchronously. Each deferred hit added up to 200ms of poll-blocking in `HttpClient.perform()` before the response was delivered, compounding to massive throughput loss at high concurrency.

**Fix:** Restored synchronous `serveFromCache()` + `transfer.deinit()` in `CacheLayer.zig`. Also added zero-poll optimization in `HttpClient.tick()` when NextTick items are pending, and restored `memoryPressureNotification(.moderate)` in `Session.deinit`.

**Files:**
- `src/network/layer/CacheLayer.zig` — synchronous cache serving
- `src/browser/HttpClient.zig` — zero-poll when NextTick drained
- `src/browser/Session.zig` — GC nudge on session teardown

### How to diagnose future regressions

1. **Connection failures** ("context deadline exceeded" on WS dial) — Server accept backlog is full. Look for changes in `HttpClient.tick()`, `perform()` poll timeouts, or anything that slows the per-connection event loop.

2. **Throughput drops** — Page load is slower. Check:
   - Did any synchronous operation become deferred/async? (CacheLayer, ScriptManager, Synthetic URL handling)
   - Did `perform()` poll timeout increase or get harder to break out of?
   - Are new per-tick operations added? (Even cheap ones compound at N clients)

3. **Memory growth** — V8 heap accumulating. Check:
   - Was `memoryPressureNotification` removed from any teardown path?
   - Are new allocations per-tick instead of per-session?

## Architecture notes

Each CDP connection gets its own thread, V8 isolate, and `HttpClient`. The event loop per connection is:

```
CDP.tick() (1s timeout)
  -> Runner._wait() loop (200ms ticks)
    -> HttpClient.tick()
      -> drainNextTickQueue()    -- serve deferred work
      -> drainQueue()            -- start queued HTTP transfers
      -> perform(timeout)        -- poll curl handles + CDP inbox
      -> drainQueue()            -- start transfers freed by completions
      -> drainInbox()            -- dispatch CDP messages
```

At 500 concurrent clients, CPU scheduling between 500 threads determines throughput. Anything that makes a single tick slower (even by microseconds) reduces the time available for other threads, causing cascading delays in connection acceptance and page processing.

## Updating the README

After a benchmark run, update the table in `README.md` under "### Multi-Client Concurrency" with the new numbers. The table should reflect the latest `zenpanda:dev` image vs `lightpanda/browser:latest`.
