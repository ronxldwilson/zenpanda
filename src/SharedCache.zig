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
