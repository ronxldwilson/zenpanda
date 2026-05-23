const std = @import("std");
const lp = @import("lightpanda");

const App = @import("App.zig");
const Browser = @import("browser/Browser.zig");
const CDP = @import("cdp/CDP.zig");
const js = @import("browser/js/js.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const BrowserPool = @This();

app: *App,
allocator: Allocator,
mutex: std.Thread.Mutex = .{},

idle: std.ArrayList(*Browser),
all: std.ArrayList(*Browser),

config: PoolConfig,

pub const PoolConfig = struct {
    min_warm: usize = 0,
    max_total: usize = 64,
    shared_env: bool = false,
    heap_limit_bytes: usize = 256 * 1024 * 1024,
};

pub fn init(app: *App, config: PoolConfig) BrowserPool {
    return .{
        .app = app,
        .allocator = app.allocator,
        .idle = .empty,
        .all = .empty,
        .config = config,
    };
}

pub fn deinit(self: *BrowserPool) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.all.items) |browser| {
        browser.deinit();
        self.allocator.destroy(browser);
    }
    self.all.deinit(self.allocator);
    self.idle.deinit(self.allocator);
}

pub fn warmUp(self: *BrowserPool) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.idle.items.len < self.config.min_warm and
        self.all.items.len < self.config.max_total)
    {
        const browser = try self.createBrowserLocked();
        try self.idle.append(self.allocator, browser);
    }
}

pub fn acquire(self: *BrowserPool, cdp: ?*CDP) !*Browser {
    self.mutex.lock();
    defer self.mutex.unlock();

    const browser: *Browser = if (self.idle.items.len > 0)
        self.idle.pop().?
    else if (self.all.items.len < self.config.max_total)
        try self.createBrowserLocked()
    else
        return error.PoolExhausted;

    if (cdp) |_| {
        browser.http_client.deinit();
        try browser.http_client.init(self.allocator, &self.app.network, cdp);
    }
    return browser;
}

pub fn release(self: *BrowserPool, browser: *Browser) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    browser.reset();
    browser.env.isolate.lowMemoryNotification();

    if (self.idle.items.len < self.config.min_warm * 2) {
        self.idle.append(self.allocator, browser) catch {
            self.destroyBrowserLocked(browser);
        };
    } else {
        self.destroyBrowserLocked(browser);
    }
}

pub fn checkMemoryPressure(self: *BrowserPool) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var total_heap: usize = 0;
    for (self.all.items) |browser| {
        const heap = browser.env.isolate.getHeapStatistics();
        total_heap += heap.used_heap_size;
    }

    if (total_heap > self.config.heap_limit_bytes) {
        log.warn(.app, "memory pressure", .{
            .total_heap = total_heap,
            .limit = self.config.heap_limit_bytes,
            .idle = self.idle.items.len,
        });
        while (self.idle.items.len > self.config.min_warm) {
            const browser = self.idle.pop();
            self.destroyBrowserLocked(browser);
        }
        for (self.all.items) |browser| {
            browser.env.isolate.memoryPressureNotification(.moderate);
        }
    }
}

pub fn evictIdle(self: *BrowserPool) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.idle.items.len > self.config.min_warm) {
        const browser = self.idle.pop();
        self.destroyBrowserLocked(browser);
    }
}

pub fn stats(self: *BrowserPool) struct { total: usize, idle: usize } {
    self.mutex.lock();
    defer self.mutex.unlock();
    return .{
        .total = self.all.items.len,
        .idle = self.idle.items.len,
    };
}

fn createBrowserLocked(self: *BrowserPool) !*Browser {
    const browser = try self.allocator.create(Browser);
    errdefer self.allocator.destroy(browser);

    try browser.init(self.app, .{
        .env = .{ .with_inspector = true },
        .shared_env = self.config.shared_env,
    }, null);
    errdefer browser.deinit();

    try self.all.append(self.allocator, browser);
    return browser;
}

fn destroyBrowserLocked(self: *BrowserPool, browser: *Browser) void {
    for (self.all.items, 0..) |b, i| {
        if (b == browser) {
            _ = self.all.swapRemove(i);
            break;
        }
    }
    browser.deinit();
    self.allocator.destroy(browser);
}

const base = @import("testing.zig");

test "BrowserPool: init and deinit" {
    var pool = BrowserPool.init(base.test_app, .{ .min_warm = 0, .max_total = 4 });
    defer pool.deinit();

    const s = pool.stats();
    try std.testing.expectEqual(@as(usize, 0), s.total);
    try std.testing.expectEqual(@as(usize, 0), s.idle);
}

test "BrowserPool: acquire and release" {
    var pool = BrowserPool.init(base.test_app, .{ .min_warm = 0, .max_total = 4 });
    defer pool.deinit();

    const browser = try pool.acquire(null);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().total);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().idle);

    pool.release(browser);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().idle);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().total);
}

test "BrowserPool: pool exhaustion" {
    var pool = BrowserPool.init(base.test_app, .{ .min_warm = 0, .max_total = 2 });
    defer pool.deinit();

    const b1 = try pool.acquire(null);
    const b2 = try pool.acquire(null);

    try std.testing.expectError(error.PoolExhausted, pool.acquire(null));

    pool.release(b1);
    pool.release(b2);
}

test "BrowserPool: warmUp pre-creates browsers" {
    var pool = BrowserPool.init(base.test_app, .{ .min_warm = 2, .max_total = 4 });
    defer pool.deinit();

    try pool.warmUp();

    const s = pool.stats();
    try std.testing.expectEqual(@as(usize, 2), s.total);
    try std.testing.expectEqual(@as(usize, 2), s.idle);
}

test "BrowserPool: acquire reuses idle browser" {
    var pool = BrowserPool.init(base.test_app, .{ .min_warm = 1, .max_total = 4 });
    defer pool.deinit();

    const b1 = try pool.acquire(null);
    pool.release(b1);

    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);

    const b2 = try pool.acquire(null);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().idle);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().total);

    pool.release(b2);
}

test "BrowserPool: stats returns correct counts" {
    var pool = BrowserPool.init(base.test_app, .{ .min_warm = 0, .max_total = 8 });
    defer pool.deinit();

    const b1 = try pool.acquire(null);
    const b2 = try pool.acquire(null);
    const b3 = try pool.acquire(null);

    try std.testing.expectEqual(@as(usize, 3), pool.stats().total);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().idle);

    pool.release(b1);
    try std.testing.expectEqual(@as(usize, 2), pool.stats().total);

    pool.release(b2);
    pool.release(b3);
}

test "BrowserPool: evictIdle respects min_warm" {
    var pool = BrowserPool.init(base.test_app, .{ .min_warm = 1, .max_total = 4 });
    defer pool.deinit();

    try pool.warmUp();
    const b1 = try pool.acquire(null);
    pool.release(b1);

    pool.evictIdle();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);

    var pool2 = BrowserPool.init(base.test_app, .{ .min_warm = 0, .max_total = 4 });
    defer pool2.deinit();
    const b2 = try pool2.acquire(null);
    pool2.release(b2);
    pool2.evictIdle();
    try std.testing.expectEqual(@as(usize, 0), pool2.stats().idle);
}

test "BrowserPool: checkMemoryPressure runs without crash" {
    var pool = BrowserPool.init(base.test_app, .{
        .min_warm = 0,
        .max_total = 4,
        .heap_limit_bytes = 1,
    });
    defer pool.deinit();

    const b1 = try pool.acquire(null);
    pool.release(b1);

    pool.checkMemoryPressure();
}

test "BrowserPool: browser env.isolate API surface" {
    var pool = BrowserPool.init(base.test_app, .{ .min_warm = 0, .max_total = 2 });
    defer pool.deinit();

    const browser = try pool.acquire(null);
    defer pool.release(browser);

    const heap = browser.env.isolate.getHeapStatistics();
    try std.testing.expect(heap.used_heap_size > 0);

    browser.env.isolate.lowMemoryNotification();
    browser.env.isolate.memoryPressureNotification(.moderate);
}
