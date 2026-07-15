//! The backend connection domain: the active connection mined from the settings blob, the boot
//! status pre-flight, and the interactive llama.cpp connect + server-persist flow. Split out of
//! char_api (the data layer) so neither file is a god-file; char_api's send loop reads active() here.
//! The pure parse lives in generate.zig under `zig build test`; this module is browser-verified (ZX5).

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const net = @import("./net.zig");
const generate = @import("./generate.zig");
const dom_event = @import("./dom_event.zig");

const alloc = @import("./character_store.zig").page_gpa;
const log = std.log.scoped(.net);

/// The active backend connection. Null when no textgen backend is configured (send disabled). Set
/// from the settings blob on boot, and from a successful interactive Connect.
var conn: ?generate.Connection = null;

/// The URL a Connect is probing, kept for the persist step once the probe returns 200.
var pending_url: []u8 = &.{};
var connecting: bool = false;

/// The model name from the probe, held for the final "Connected" status the persist step shows.
var pending_model_buf: [96]u8 = undefined;
var pending_model_len: usize = 0;

pub fn active() ?generate.Connection {
    return conn;
}

// ---- from the settings blob (boot) ---------------------------------------------------------

/// Mines the connection out of the settings blob and reflects it into the composer status. Called on
/// each /api/settings/get. Textgen family only this phase.
pub fn setFrom(settings_str: []const u8) void {
    if (conn) |c| {
        generate.freeConnection(alloc, c);
        conn = null;
    }
    conn = generate.extractConnection(alloc, settings_str) catch |err| {
        switch (err) {
            error.UnsupportedApi => log.info("send: non-textgen backend, send disabled this phase", .{}),
            error.MissingConnection => log.info("send: no textgen backend configured", .{}),
            else => log.warn("send: connection parse failed: {s}", .{@errorName(err)}),
        }
        setSendStatus("No backend configured");
        return;
    };
    updateSendStatus();
    checkStatus();
}

fn updateSendStatus() void {
    const c = conn orelse return setSendStatus("No backend configured");
    if (c.api_server.len == 0) return setSendStatus("Backend not connected");
    setSendStatusFmt("Backend: {s}", .{c.api_type});
}

fn checkStatus() void {
    const c = conn orelse return;
    if (c.api_server.len == 0) return;
    const body = statusBody(c.api_server, c.api_type) orelse return;
    defer alloc.free(body);
    net.request("/api/backends/text-completions/status", body, 0, onBootStatusDone, .{});
}

fn onBootStatusDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    const c = conn orelse return;
    if (status == 0 or status == 502 or status == 504) {
        setSendStatus("Backend asleep - unlock at silly");
        return;
    }
    if (status >= 200 and status < 300) {
        if (statusOffline(res)) {
            setSendStatus("Backend offline - unlock at silly");
            return;
        }
        setSendStatusFmt("Connected: {s}", .{c.api_type});
        return;
    }
    setSendStatusFmt("Backend error {d}", .{status});
}

// ---- interactive llama.cpp connect (the connections panel) --------------------------------

/// Read the server URL from the panel input, probe the backend status, and on a reachable 200
/// persist the connection to the shared SillyTavern settings. Reflects progress into #conn-status.
pub fn connectLlama() void {
    if (zx.platform.role != .client) return;
    if (connecting) return;
    const url = readUrlInput() orelse {
        setConnStatus("Enter a server URL");
        return;
    };
    if (pending_url.len > 0) alloc.free(pending_url);
    pending_url = url;
    connecting = true;
    setConnStatus("Connecting...");
    const body = statusBody(url, "llamacpp") orelse {
        connecting = false;
        return;
    };
    defer alloc.free(body);
    net.request("/api/backends/text-completions/status", body, 0, onProbeDone, .{});
}

fn onProbeDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    connecting = false;
    if (status == 0 or status == 502 or status == 504) {
        setConnStatus("Backend asleep - unlock at silly");
        return;
    }
    if (status < 200 or status >= 300) {
        setConnStatusFmt("Connect failed: {d}", .{status});
        return;
    }
    var model_buf: [96]u8 = undefined;
    var model: []const u8 = "";
    var offline = false;
    if (res) |r| {
        if (r.json(struct { result: []const u8 = "", online: ?bool = null })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.online) |up| offline = !up;
            const n = @min(parsed.value.result.len, model_buf.len);
            @memcpy(model_buf[0..n], parsed.value.result[0..n]);
            model = model_buf[0..n];
        } else |_| {}
    }
    if (offline) {
        setConnStatus("Backend offline - unlock at silly");
        return;
    }
    // Stash the model, then persist. "Connected" shows only once the save lands (onPersistDone), so a
    // caller waiting on it knows the connection was adopted, not merely probed.
    pending_model_len = model.len;
    if (model.len > 0) @memcpy(pending_model_buf[0..model.len], model);
    setConnStatus("Saving...");
    persistLlama(pending_url);
}

fn persistLlama(url: []const u8) void {
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .api_type = "llamacpp",
        .api_server = url,
    }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/settings/set-connection", body, 0, onPersistDone, .{});
}

fn onPersistDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (status < 200 or status >= 300) {
        setConnStatusFmt("Save failed: {d}", .{status});
        return;
    }
    // Adopt the persisted connection so send works immediately; the full samplers reload on next boot.
    var adopted = false;
    if (res) |r| {
        if (r.json(struct {
            ok: ?bool = null,
            connection: ?struct { api_type: []const u8 = "", api_server: []const u8 = "" } = null,
        })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.connection) |pc| {
                applyConnection(pc.api_type, pc.api_server);
                adopted = true;
            }
        } else |_| {}
    }
    if (!adopted) applyConnection("llamacpp", pending_url);
    updateSendStatus();
    // "Connected" is the post-save signal: the connection is now adopted and send will use it.
    if (pending_model_len > 0) setConnStatusFmt("Connected: {s}", .{pending_model_buf[0..pending_model_len]}) else setConnStatus("Connected");
}

/// Build an active connection from a type and URL with backend-neutral sampler defaults. The full
/// samplers stay in the settings blob server-side and reload on the next boot.
fn applyConnection(api_type: []const u8, api_server: []const u8) void {
    const t = alloc.dupe(u8, api_type) catch return;
    const s = alloc.dupe(u8, api_server) catch {
        alloc.free(t);
        return;
    };
    if (conn) |c| generate.freeConnection(alloc, c);
    conn = .{
        .api_type = t,
        .api_server = s,
        .max_tokens = 512,
        .temperature = 1.0,
        .top_p = 1.0,
        .top_k = 0,
        .min_p = 0.0,
        .rep_pen = 1.0,
    };
}

// ---- helpers -------------------------------------------------------------------------------

fn statusBody(api_server: []const u8, api_type: []const u8) ?[]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .api_server = api_server,
        .api_type = api_type,
    }, .{}) catch null;
}

fn statusOffline(res: ?*zx.Fetch.Response) bool {
    const r = res orelse return false;
    const parsed = r.json(struct { online: ?bool = null }) catch return false;
    defer parsed.deinit();
    return if (parsed.value.online) |up| !up else false;
}

fn readUrlInput() ?[]u8 {
    if (zx.platform.role != .client) return null;
    const el = dom_event.elementById(alloc, "llama-url") orelse return null;
    defer el.deinit();
    const raw = el.ref.getAlloc(js.String, alloc, "value") catch return null;
    defer alloc.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, trimmed) catch null;
}

fn setSendStatus(text: []const u8) void {
    reflectText("send-status", text);
}

fn setConnStatus(text: []const u8) void {
    reflectText("conn-status", text);
}

fn reflectText(id: []const u8, text: []const u8) void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(alloc, id) orelse return;
    defer el.deinit();
    el.ref.set("textContent", js.string(text)) catch {};
}

fn setSendStatusFmt(comptime fmt: []const u8, args: anytype) void {
    fmtInto("send-status", fmt, args);
}

fn setConnStatusFmt(comptime fmt: []const u8, args: anytype) void {
    fmtInto("conn-status", fmt, args);
}

fn fmtInto(id: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (zx.platform.role != .client) return;
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    reflectText(id, text);
}
