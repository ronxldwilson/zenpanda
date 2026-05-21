// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");

const Config = @import("Config.zig");
const Snapshot = @import("browser/js/Snapshot.zig");
const Platform = @import("browser/js/Platform.zig");
const js = @import("browser/js/js.zig");
const Telemetry = @import("telemetry/telemetry.zig").Telemetry;

const Storage = @import("storage/Storage.zig");
const Network = @import("network/Network.zig");
pub const ArenaPool = @import("ArenaPool.zig");
pub const BrowserPool = @import("BrowserPool.zig");
pub const SharedCache = @import("SharedCache.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

const App = @This();

network: Network,
config: *const Config,
storage: Storage,
platform: Platform,
snapshot: Snapshot,
telemetry: Telemetry,
allocator: Allocator,
arena_pool: ArenaPool,
app_dir_path: ?[]const u8,
v8_mutex: std.Thread.Mutex = .{},
shared_env: ?js.Env = null,
browser_pool: ?BrowserPool = null,
shared_cache: ?SharedCache = null,

pub fn init(allocator: Allocator, config: *const Config) !*App {
    const platform = try Platform.init();
    errdefer platform.deinit();

    const snapshot = try Snapshot.load();
    errdefer snapshot.deinit();

    var storage = try Storage.init(allocator, config);
    errdefer storage.deinit(allocator);

    const app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .config = config,
        .allocator = allocator,
        .platform = platform,
        .snapshot = snapshot,
        .storage = storage,
        .network = undefined,
        .app_dir_path = undefined,
        .telemetry = undefined,
        .arena_pool = undefined,
    };
    app.network = try Network.init(allocator, app, config);
    errdefer app.network.deinit();

    app.app_dir_path = getAndMakeAppDir(allocator);

    app.telemetry = try Telemetry.init(app, config.mode);
    errdefer app.telemetry.deinit(allocator);

    app.arena_pool = ArenaPool.init(allocator, .{});
    errdefer app.arena_pool.deinit();

    return app;
}

pub fn shutdown(self: *const App) bool {
    return self.network.shutdown.load(.acquire);
}

pub fn getOrCreateSharedEnv(self: *App) !*js.Env {
    if (self.shared_env) |*env| return env;
    self.shared_env = try js.Env.init(self, .{});
    return &self.shared_env.?;
}

pub fn initBrowserPool(self: *App, config: BrowserPool.PoolConfig) !void {
    self.browser_pool = BrowserPool.init(self, config);
    try self.browser_pool.?.warmUp();
}

pub fn deinitBrowserPool(self: *App) void {
    if (self.browser_pool) |*pool| {
        pool.deinit();
        self.browser_pool = null;
    }
}

pub fn initSharedCache(self: *App, max_bytes: usize) void {
    self.shared_cache = SharedCache.init(self.allocator, max_bytes);
}

pub fn deinitSharedCache(self: *App) void {
    if (self.shared_cache) |*cache| {
        cache.deinit();
        self.shared_cache = null;
    }
}

pub fn deinit(self: *App) void {
    const allocator = self.allocator;
    if (self.app_dir_path) |app_dir_path| {
        allocator.free(app_dir_path);
        self.app_dir_path = null;
    }
    self.deinitBrowserPool();
    self.deinitSharedCache();
    self.telemetry.deinit(allocator);
    self.network.deinit();
    if (self.shared_env) |*env| {
        env.deinit();
        self.shared_env = null;
    }
    self.snapshot.deinit();
    self.platform.deinit();
    self.arena_pool.deinit();
    self.storage.deinit(allocator);

    allocator.destroy(self);
}

fn getAndMakeAppDir(allocator: Allocator) ?[]const u8 {
    if (@import("builtin").is_test) {
        return allocator.dupe(u8, "/tmp") catch unreachable;
    }
    const app_dir_path = std.fs.getAppDataDir(allocator, "lightpanda") catch |err| {
        log.warn(.app, "get data dir", .{ .err = err });
        return null;
    };

    std.fs.cwd().makePath(app_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => return app_dir_path,
        else => {
            allocator.free(app_dir_path);
            log.warn(.app, "create data dir", .{ .err = err, .path = app_dir_path });
            return null;
        },
    };
    return app_dir_path;
}
