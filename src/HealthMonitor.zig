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
