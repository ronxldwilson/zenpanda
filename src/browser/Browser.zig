// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const App = @import("../App.zig");
const CDP = @import("../cdp/CDP.zig");
const Notification = @import("../Notification.zig");

const js = @import("js/js.zig");
const Page = @import("Page.zig");
const Session = @import("Session.zig");
const HttpClient = @import("HttpClient.zig");

const ArenaPool = App.ArenaPool;
const Allocator = std.mem.Allocator;

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser supports multiple concurrent sessions.
const Browser = @This();

env: *js.Env,
app: *App,
allocator: Allocator,
arena_pool: *ArenaPool,
http_client: HttpClient,
owns_env: bool,

// used by sessions to allocate pages.
page_pool: std.heap.MemoryPool(Page),
session_pool: std.heap.MemoryPool(Session),
active_sessions: std.ArrayList(*Session),

// Pool for FinalizerCallback.Identity structs — the records V8 weak-callback
// parameters point at. Scoped to the Browser (i.e. the V8 Isolate's lifetime)
// rather than the Session: V8 can run a weak finalizer arbitrarily late, any
// time up until the Isolate is torn down, so these must outlive every Session.
// Freed in deinit *after* env.deinit() tears down the Isolate — the point past
// which no finalizer can fire.
fc_identity_pool: std.heap.MemoryPool(js.FinalizerCallback.Identity),

// Monotonic frame-ID generator scoped to this Browser (one per CDP
// connection). Lives here, not on Session, because CDP target IDs
// (encoded as `FID-{d:0>10}`) must be unique for the lifetime of the
// connection -- a Session-scoped counter would re-issue the same
// `FID-0000000001` for every fresh BrowserContext on the connection,
// which Playwright rejects with `Duplicate target FID-...` (issue
// #2472).
frame_id_gen: u32 = 0,

pub const InitOpts = struct {
    env: js.Env.InitOpts = .{},
    shared_env: bool = false,
};

// Allocate the next frame ID. Wrapping `+%` keeps this safe past 2^32
// allocations on a single connection (which would take days of
// continuous navigation; in practice we wrap the connection long
// before that). Callers must format with `FID-{d:0>10}` to match the
// existing CDP target-ID encoding (`src/cdp/id.zig`).
pub fn nextFrameId(self: *Browser) u32 {
    const id = self.frame_id_gen +% 1;
    self.frame_id_gen = id;
    return id;
}

pub fn init(self: *Browser, app: *App, opts: InitOpts, cdp: ?*CDP) !void {
    const allocator = app.allocator;

    var env_ptr: *js.Env = undefined;
    var owns = false;
    if (opts.shared_env) {
        env_ptr = try app.getOrCreateSharedEnv();
    } else {
        const owned = try allocator.create(js.Env);
        errdefer allocator.destroy(owned);
        owned.* = try js.Env.init(app, opts.env);
        env_ptr = owned;
        owns = true;
    }

    self.* = .{
        .app = app,
        .env = env_ptr,
        .owns_env = owns,
        .allocator = allocator,
        .arena_pool = &app.arena_pool,
        .http_client = undefined,
        .page_pool = std.heap.MemoryPool(Page).init(allocator),
        .session_pool = std.heap.MemoryPool(Session).init(allocator),
        .active_sessions = .empty,
        .fc_identity_pool = .init(allocator),
    };
    try self.http_client.init(allocator, &app.network, cdp);
}

pub fn deinit(self: *Browser) void {
    for (self.active_sessions.items) |session| {
        session.deinit();
        self.session_pool.destroy(session);
    }
    self.active_sessions.deinit(self.allocator);
    if (self.owns_env) {
        self.env.deinit();
        self.allocator.destroy(self.env);
    }
    self.fc_identity_pool.deinit();
    self.page_pool.deinit();
    self.session_pool.deinit();
    self.http_client.deinit();
}

pub fn reset(self: *Browser) void {
    for (self.active_sessions.items) |session| {
        session.deinit();
        self.session_pool.destroy(session);
    }
    self.active_sessions.clearRetainingCapacity();
    self.frame_id_gen = 0;
}

pub fn newSession(self: *Browser, notification: *Notification) !*Session {
    const session = try self.session_pool.create();
    errdefer self.session_pool.destroy(session);
    try Session.init(session, self, notification);
    try self.active_sessions.append(self.allocator, session);
    return session;
}

pub fn closeSession(self: *Browser, session: *Session) void {
    for (self.active_sessions.items, 0..) |s, i| {
        if (s == session) {
            _ = self.active_sessions.swapRemove(i);
            break;
        }
    }
    session.deinit();
    self.session_pool.destroy(session);
}

pub fn runMicrotasks(self: *Browser) void {
    self.env.runMicrotasks();
}

pub fn runMacrotasks(self: *Browser) !void {
    try self.env.runMacrotasks();
    self.env.pumpMessageLoop();

    // either of the above could have queued more microtasks
    self.env.runMicrotasks();
}

pub fn hasBackgroundTasks(self: *Browser) bool {
    return self.env.hasBackgroundTasks();
}

pub fn waitForBackgroundTasks(self: *Browser) void {
    self.env.waitForBackgroundTasks();
}

pub fn msToNextMacrotask(self: *Browser) ?u64 {
    return self.env.msToNextMacrotask();
}

pub fn msTo(self: *Browser) bool {
    return self.env.hasBackgroundTasks();
}

pub fn runIdleTasks(self: *const Browser) void {
    self.env.runIdleTasks();
}
