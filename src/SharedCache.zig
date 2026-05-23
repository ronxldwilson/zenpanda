const std = @import("std");
const lp = @import("lightpanda");

const Allocator = std.mem.Allocator;
const log = lp.log;

const SharedCache = @This();

allocator: Allocator,
mutex: std.Thread.Mutex = .{},
entries: std.StringHashMapUnmanaged(Entry),
total_bytes: usize = 0,
max_bytes: usize,
hits: u64 = 0,
misses: u64 = 0,

pub const Entry = struct {
    data: []const u8,
    content_type: ContentType,
    size: usize,
};

pub const ContentType = enum {
    css,
    javascript,
    font,
    other,
};

pub fn init(allocator: Allocator, max_bytes: usize) SharedCache {
    return .{
        .allocator = allocator,
        .entries = .empty,
        .max_bytes = max_bytes,
    };
}

pub fn deinit(self: *SharedCache) void {
    var it = self.entries.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.data);
    }
    self.entries.deinit(self.allocator);
}

pub fn get(self: *SharedCache, key: []const u8) ?[]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.entries.get(key)) |entry| {
        self.hits += 1;
        return entry.data;
    }
    self.misses += 1;
    return null;
}

pub fn put(self: *SharedCache, key: []const u8, data: []const u8, content_type: ContentType) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.entries.get(key) != null) return;

    while (self.total_bytes + data.len > self.max_bytes and self.entries.count() > 0) {
        self.evictOneLocked();
    }

    if (data.len > self.max_bytes) return;

    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    const owned_data = try self.allocator.dupe(u8, data);
    errdefer self.allocator.free(owned_data);

    try self.entries.put(self.allocator, owned_key, .{
        .data = owned_data,
        .content_type = content_type,
        .size = data.len,
    });
    self.total_bytes += data.len;
}

pub fn clear(self: *SharedCache) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    var it = self.entries.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.data);
    }
    self.entries.clearRetainingCapacity();
    self.total_bytes = 0;
}

pub fn stats(self: *SharedCache) Stats {
    self.mutex.lock();
    defer self.mutex.unlock();
    return .{
        .entries = self.entries.count(),
        .total_bytes = self.total_bytes,
        .hits = self.hits,
        .misses = self.misses,
    };
}

pub const Stats = struct {
    entries: u32,
    total_bytes: usize,
    hits: u64,
    misses: u64,
};

fn evictOneLocked(self: *SharedCache) void {
    var it = self.entries.iterator();
    if (it.next()) |entry| {
        self.total_bytes -= entry.value_ptr.size;
        self.allocator.free(entry.value_ptr.data);
        const key = entry.key_ptr.*;
        self.entries.removeByPtr(entry.key_ptr);
        self.allocator.free(key);
    }
}

const testing = std.testing;

test "SharedCache: put and get" {
    var cache = SharedCache.init(testing.allocator, 1024);
    defer cache.deinit();

    try cache.put("key1", "hello", .css);
    const result = cache.get("key1");
    try testing.expect(result != null);
    try testing.expectEqualStrings("hello", result.?);
}

test "SharedCache: miss returns null" {
    var cache = SharedCache.init(testing.allocator, 1024);
    defer cache.deinit();

    try testing.expectEqual(null, cache.get("nonexistent"));
}

test "SharedCache: stats track hits and misses" {
    var cache = SharedCache.init(testing.allocator, 1024);
    defer cache.deinit();

    try cache.put("k", "v", .javascript);
    _ = cache.get("k");
    _ = cache.get("k");
    _ = cache.get("missing");

    const s = cache.stats();
    try testing.expectEqual(@as(u32, 1), s.entries);
    try testing.expectEqual(@as(u64, 2), s.hits);
    try testing.expectEqual(@as(u64, 1), s.misses);
    try testing.expectEqual(@as(usize, 1), s.total_bytes);
}

test "SharedCache: eviction under max_bytes" {
    var cache = SharedCache.init(testing.allocator, 10);
    defer cache.deinit();

    try cache.put("a", "12345", .css);
    try cache.put("b", "67890", .css);
    try testing.expectEqual(@as(usize, 10), cache.total_bytes);

    try cache.put("c", "xxxxx", .css);
    const s = cache.stats();
    try testing.expect(s.total_bytes <= 10);
}

test "SharedCache: oversized entry rejected" {
    var cache = SharedCache.init(testing.allocator, 4);
    defer cache.deinit();

    try cache.put("big", "too_large", .other);
    try testing.expectEqual(null, cache.get("big"));
    try testing.expectEqual(@as(u32, 0), cache.stats().entries);
}

test "SharedCache: clear resets state" {
    var cache = SharedCache.init(testing.allocator, 1024);
    defer cache.deinit();

    try cache.put("a", "data", .font);
    cache.clear();

    try testing.expectEqual(null, cache.get("a"));
    try testing.expectEqual(@as(u32, 0), cache.stats().entries);
    try testing.expectEqual(@as(usize, 0), cache.total_bytes);
}

test "SharedCache: duplicate key is no-op" {
    var cache = SharedCache.init(testing.allocator, 1024);
    defer cache.deinit();

    try cache.put("k", "first", .css);
    try cache.put("k", "second", .css);

    try testing.expectEqualStrings("first", cache.get("k").?);
    try testing.expectEqual(@as(u32, 1), cache.stats().entries);
}
