# 500-Client Performance Regression After Upstream Sync

**Status:** Open
**Date:** 2026-05-27
**Affects:** zenpanda:dev (post upstream sync of 36 commits)

## Summary

After syncing 36 upstream commits from lightpanda-io/browser, ZenPanda's 500-client concurrency performance regressed significantly. The 1-50 client range is healthy (100% success), but 500 concurrent clients shows a ~2x drop vs the pre-sync image.

## Benchmark data

All runs use the same setup: local amiibo site via Cloudflare tunnel, Docker arm64 containers on Mac mini, `bench/upstream_bench.sh --quick`.

### Old image (ronxldwilson/zenpanda:latest, May 23)

| Clients | Success | Connected | Throughput |
|---------|---------|-----------|------------|
| 1       | 100%    | 1/1       | 0.54 p/s   |
| 50      | **100%** | 50/50    | 13.51 p/s  |
| 500     | **44.9%** | **479/500** | **8.44 p/s** |

### New image (post-sync + CacheLayer fix)

| Clients | Success | Connected | Throughput |
|---------|---------|-----------|------------|
| 1       | 100%    | 1/1       | 0.56 p/s   |
| 50      | **100%** | 50/50    | 16.12 p/s  |
| 500     | 19.6%   | 342/500   | 3.42 p/s   |

### Lightpanda baseline (same run as old image)

| Clients | Success | Connected | Throughput |
|---------|---------|-----------|------------|
| 500     | 14.1%   | 201/500   | 4.57 p/s   |

## What's already been fixed

Commit `b7faaf0e` addressed the primary regression (CacheLayer deferred serving):

1. **CacheLayer** (`src/network/layer/CacheLayer.zig`) — Upstream commit `c34f1295` deferred cache hits through `runNextTick()`, adding up to 200ms poll-block latency per cached resource. Restored synchronous `serveFromCache()`.
2. **HttpClient.tick** (`src/browser/HttpClient.zig`) — Zero poll timeout when NextTick items were just drained, preventing idle blocking.
3. **Session.deinit** (`src/browser/Session.zig`) — Restored `memoryPressureNotification(.moderate)` that upstream removed when moving `fc_identity_pool` to Browser.

These fixes restored 1-50 client performance to match or beat the old image. But 500-client performance is still degraded.

## Remaining regression at 500 clients

The old image connects 479/500 clients with 44.9% page success. The new image only connects 342/500 with 19.6% success. Error patterns:

- **Old image**: mostly `context canceled` (clients connect but wall time expires) — healthy degradation
- **New image**: mix of `context deadline exceeded` and `connection reset by peer` on WS dial — server can't accept connections fast enough

## Suspect upstream changes

The remaining regression is likely from cumulative per-tick overhead across 500 threads. Each upstream change is small individually, but they compound:

| Change | Commit | Impact |
|--------|--------|--------|
| NextTick queue drain at top of every tick | `01d198de`..`95162f49` | O(1) when empty, but adds branch + field read per tick x 500 threads |
| Synthetic URL handling via NextTick | `253520a9` | data:/blob: URLs now deferred instead of inline — adds tick roundtrip |
| ScriptManager data: URI rerouting | `d37a10fe` | data: script srcs go through HTTP path instead of inline parse |
| CustomElement Reactions machinery | `874e9c38` | Struct init per Frame, scope push/pop per CE-tagged method (near-zero for non-CE sites) |
| `fc_identity_pool` on Browser | `dcf5739d` | MemoryPool init per Browser instead of per Session |
| Frame `childrenIterator` revert | `fec568d8` | Changed back from `firstChild()` loop to iterator |
| Cache eviction support | `6e8563f1` | Adds evict method + lock contention path to FsCache |

## Reproduction

```bash
# Tag old image and run benchmark
docker tag ronxldwilson/zenpanda:latest zenpanda:dev
make bench-quick

# Compare with new image
docker build -f Dockerfile.package -t zenpanda:dev .
make bench-quick
```

## Next steps

- [ ] Profile with `perf` or `dtrace` to find where the 500-client tick loop spends most time
- [ ] Try selectively reverting NextTick-related commits to isolate the biggest contributor
- [ ] Consider reducing `Runner._wait` tick timeout from 200ms to 50ms under high connection count
- [ ] Investigate if the Docker container's TCP backlog (`somaxconn`) is saturating at 500 concurrent WS dials
