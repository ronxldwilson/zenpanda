# 500-Client Performance Regression After Upstream Sync

**Status:** Resolved
**Date:** 2026-05-27
**Affects:** zenpanda:dev (post upstream sync of 36 commits)

## Summary

After syncing 36 upstream commits from lightpanda-io/browser, ZenPanda's 500-client concurrency performance regressed significantly. The 1-50 client range was healthy (100% success), but 500 concurrent clients showed a ~2x drop vs the pre-sync image. Two fixes resolved the issue: TCP backlog scaling and more aggressive accept draining.

## Benchmark data

All runs use the same setup: local amiibo site via Cloudflare tunnel, Docker arm64 containers on Mac mini, `bench/upstream_bench.sh --quick`.

### Old image (ronxldwilson/zenpanda:latest, May 23)

| Clients | Success | Connected | Throughput |
|---------|---------|-----------|------------|
| 1       | 100%    | 1/1       | 0.54 p/s   |
| 50      | **100%** | 50/50    | 13.51 p/s  |
| 500     | **44.9%** | **479/500** | **8.44 p/s** |

### Post-sync (before 500-client fix)

| Clients | Success | Connected | Throughput |
|---------|---------|-----------|------------|
| 1       | 100%    | 1/1       | 0.56 p/s   |
| 50      | **100%** | 50/50    | 16.12 p/s  |
| 500     | 19.6%   | 342/500   | 3.42 p/s   |

### Post-fix (backlog scaling + accept drain)

| Clients | Success | Connected | Throughput |
|---------|---------|-----------|------------|
| 50      | **100%** | 50/50    | 11.06 p/s  |
| 500     | **77.6%** | **500/500** | **16.67 p/s** |

### Lightpanda baseline

| Clients | Success | Connected | Throughput |
|---------|---------|-----------|------------|
| 500     | 39.2%   | 345/500   | 15.70 p/s  |

## Fixes applied

### Phase 1: CacheLayer + tick optimization (commit `b7faaf0e`)

1. **CacheLayer** (`src/network/layer/CacheLayer.zig`) — Upstream commit `c34f1295` deferred cache hits through `runNextTick()`, adding up to 200ms poll-block latency per cached resource. Restored synchronous `serveFromCache()`.
2. **HttpClient.tick** (`src/browser/HttpClient.zig`) — Zero poll timeout when NextTick items were just drained, preventing idle blocking.
3. **Session.deinit** (`src/browser/Session.zig`) — Restored `memoryPressureNotification(.moderate)` that upstream removed when moving `fc_identity_pool` to Browser.

These fixes restored 1-50 client performance to match or beat the old image.

### Phase 2: Connection accept scaling

1. **Config.zig** — `maxPendingConnections()` now returns `@max(cdp_max_pending_connections, cdp_max_connections)`. When the Dockerfile passes `--cdp-max-connections 512`, the TCP backlog automatically scales to 512 (was stuck at the default 128). With 500 simultaneous SYN packets and only 128 backlog, the kernel dropped connections.
2. **Network.zig** — Added a second `acceptConnections()` call at the end of each main loop iteration. The Network thread's loop processes completions, CDP events, and tick callbacks between accept opportunities. With 500 sessions, this processing takes long enough to overflow the backlog. The extra accept drains pending connections after the heavy work, cutting the gap.

## Root cause analysis

The 500-client regression had two layers:

- **Primary** (Phase 1): CacheLayer NextTick deferral added 200ms latency per cached resource per tick, compounding across all sessions.
- **Secondary** (Phase 2): TCP backlog overflow. The Dockerfile set `--cdp-max-connections 512` but the backlog remained at the default 128. With upstream adding more per-iteration work (NextTick drain, CDP event processing, tick callbacks), the Network thread's main loop took longer per iteration, leaving less time to drain the accept queue. 500 simultaneous WS dials overflowed the 128-slot backlog, causing `connection reset by peer` errors.
