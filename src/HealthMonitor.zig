const std = @import("std");
const lp = @import("lightpanda");

const App = @import("App.zig");
const BrowserPool = App.BrowserPool;

const log = lp.log;
const Allocator = std.mem.Allocator;

const HealthMonitor = @This();

app: *App,
thread: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(false),

pub fn init(app: *App) HealthMonitor {
    return .{ .app = app };
}

pub fn start(self: *HealthMonitor, interval_ms: u64) !void {
    if (self.running.load(.acquire)) return;
    self.running.store(true, .release);
    self.thread = try std.Thread.spawn(.{}, monitorLoop, .{ self, interval_ms });
}

pub fn stop(self: *HealthMonitor) void {
    self.running.store(false, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
}

pub fn getStatus(self: *HealthMonitor) Status {
    var status = Status{
        .alive = true,
        .pool_total = 0,
        .pool_idle = 0,
        .heap_used = 0,
        .cache_entries = 0,
        .cache_bytes = 0,
    };

    if (self.app.browser_pool) |*pool| {
        const pool_stats = pool.stats();
        status.pool_total = pool_stats.total;
        status.pool_idle = pool_stats.idle;
    }

    if (self.app.shared_cache) |*cache| {
        const cache_stats = cache.stats();
        status.cache_entries = cache_stats.entries;
        status.cache_bytes = cache_stats.total_bytes;
    }

    return status;
}

pub const Status = struct {
    alive: bool,
    pool_total: usize,
    pool_idle: usize,
    heap_used: usize,
    cache_entries: u32,
    cache_bytes: usize,
};

fn monitorLoop(self: *HealthMonitor, interval_ms: u64) void {
    while (self.running.load(.acquire)) {
        if (self.app.shutdown()) {
            self.running.store(false, .release);
            return;
        }

        if (self.app.browser_pool) |*pool| {
            pool.checkMemoryPressure();
        }

        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }
}

const base = @import("testing.zig");

test "HealthMonitor: init returns valid status" {
    var monitor = HealthMonitor.init(base.test_app);

    const status = monitor.getStatus();
    try std.testing.expect(status.alive);
    try std.testing.expectEqual(@as(usize, 0), status.pool_total);
    try std.testing.expectEqual(@as(usize, 0), status.pool_idle);
    try std.testing.expectEqual(@as(u32, 0), status.cache_entries);
    try std.testing.expectEqual(@as(usize, 0), status.cache_bytes);
}

test "HealthMonitor: status reflects pool state" {
    base.test_app.browser_pool = BrowserPool.init(base.test_app, .{ .min_warm = 0, .max_total = 4 });
    defer {
        base.test_app.browser_pool.?.deinit();
        base.test_app.browser_pool = null;
    }

    var monitor = HealthMonitor.init(base.test_app);

    const b = try base.test_app.browser_pool.?.acquire(null);

    const status = monitor.getStatus();
    try std.testing.expectEqual(@as(usize, 1), status.pool_total);
    try std.testing.expectEqual(@as(usize, 0), status.pool_idle);

    base.test_app.browser_pool.?.release(b);
}

test "HealthMonitor: status reflects cache state" {
    const SharedCache = App.SharedCache;
    base.test_app.shared_cache = SharedCache.init(base.test_app.allocator, 4096);
    defer {
        base.test_app.shared_cache.?.deinit();
        base.test_app.shared_cache = null;
    }

    try base.test_app.shared_cache.?.put("test-key", "test-value", .css);

    var monitor = HealthMonitor.init(base.test_app);
    const status = monitor.getStatus();
    try std.testing.expectEqual(@as(u32, 1), status.cache_entries);
    try std.testing.expect(status.cache_bytes > 0);
}

test "HealthMonitor: start and stop" {
    var monitor = HealthMonitor.init(base.test_app);
    try monitor.start(100);
    try std.testing.expect(monitor.running.load(.acquire));

    monitor.stop();
    try std.testing.expect(!monitor.running.load(.acquire));
    try std.testing.expectEqual(null, monitor.thread);
}

test "HealthMonitor: double start is no-op" {
    var monitor = HealthMonitor.init(base.test_app);
    try monitor.start(100);
    try monitor.start(100);
    try std.testing.expect(monitor.running.load(.acquire));
    monitor.stop();
}
