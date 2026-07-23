//! The backend connection domain: the active connection mined from the settings blob, the boot
//! status pre-flight, the interactive connect + server-persist flow, and the API-key field's
//! write-only lifecycle. Split out of char_api (the data layer) so neither file is a god-file;
//! char_api's send loop reads active() here. The pure parse lives in generate.zig and the type table
//! in textgen_types.zig, both under `zig build test`; this module is browser-verified (ZX5).
//!
//! The API key is WRITE-ONLY by design. `/api/secrets/find` returns plaintext but 403s unless
//! `allowKeysExposure` is set (src/endpoints/secrets.js:577), so no plaintext round-trip exists on a
//! default install and this module never asks for one. Presence is read from `/api/secrets/read`,
//! whose value this module re-masks locally before it reaches the DOM.

const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const net = @import("./net.zig");
const generate = @import("./generate.zig");
const dom_event = @import("./dom_event.zig");
const textgen = @import("./textgen_types.zig");
const secret_mask = @import("./secret_mask.zig");
const regions = @import("./regions.zig");
const notifications = @import("./notifications.zig");

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

/// The type the panel's selector shows. Copied into a fixed buffer, never aliased: the mined slice
/// belongs to `conn`, which setFrom frees on the next settings load.
var selected_buf: [64]u8 = undefined;
var selected_len: usize = 0;

pub fn active() ?generate.Connection {
    return conn;
}

/// The last model the backend reported from a status probe (stock online_status). The tokenizer
/// resolver uses it as the fallback when the settings blob configured no explicit model name. Empty
/// until a probe has run this session.
pub fn probedModel() []const u8 {
    return pending_model_buf[0..pending_model_len];
}

// ---- the connection state (the topbar readout) ----------------------------------------------

/// What the backend is doing, as one value with one owner. Every site that learns something about
/// the backend sets this and re-renders the Shell; none of them writes DOM text any more. The old
/// design had six call sites poking `#send-status` directly, which is why the readout could only
/// live in one place and why nothing else could ask what the state was.
pub const ConnState = enum { none, configured, connected, asleep, offline, err };

var state: ConnState = .none;
var state_code: u16 = 0;

pub fn connState() ConnState {
    return state;
}

/// The state as a DATA value for the markup to key off (`data-conn-state`). Never a class name: the
/// tailwind scan reads `.zx` only, so appearance keyed on a Zig-built class would never be generated.
pub fn stateName() []const u8 {
    return @tagName(state);
}

/// The state IN WORDS, for the dot's accessible name and the panel's standing line. A dot that
/// carries its meaning only in colour tells a screen reader, and a red-green reader, nothing (WD38).
pub fn statusWords(buf: *[96]u8) []const u8 {
    return switch (state) {
        .none => "No backend configured",
        .configured => blk: {
            const c = conn orelse break :blk "No backend configured";
            if (c.api_server.len == 0) break :blk "Backend not connected";
            break :blk std.fmt.bufPrint(buf, "Backend: {s}", .{c.api_type}) catch "Backend configured";
        },
        .connected => std.fmt.bufPrint(buf, "Connected: {s}", .{statusModel()}) catch "Connected",
        .asleep => "Backend asleep - unlock at silly",
        .offline => "Backend offline - unlock at silly",
        .err => std.fmt.bufPrint(buf, "Backend error {d}", .{state_code}) catch "Backend error",
    };
}

/// What the topbar prints beside the dot: the model the backend reported, falling back to the type
/// so the button still names the backend before any probe has answered.
pub fn statusModel() []const u8 {
    if (pending_model_len > 0) return pending_model_buf[0..pending_model_len];
    const c = conn orelse return "";
    return c.api_type;
}

fn setState(s: ConnState) void {
    state = s;
    state_code = 0;
    regions.bumpShell();
}

fn setStateErr(code: u16) void {
    state = .err;
    state_code = code;
    regions.bumpShell();
}

/// Remember the model a status probe reported, so the topbar can name it. Shared by the boot
/// pre-flight and the interactive connect, which both read `result` off the same endpoint.
fn storeProbedModel(model: []const u8) void {
    const n = @min(model.len, pending_model_buf.len);
    @memcpy(pending_model_buf[0..n], model[0..n]);
    pending_model_len = n;
}

/// A send stream came back 502/504, so the edge answered before SillyTavern was reached. Reported by
/// stream_drive at the seal: the failure is the connection's to hold, not the streamer's to paint.
pub fn onStreamUnreachable() void {
    setState(.asleep);
    notifications.push(.warning, "Backend asleep - unlock at silly", notifications.error_ttl_ms);
}

/// Mutate the live connection in place, for the config panel's samplers. Handed a pointer rather
/// than a setter per field so the sampler model stays in samplers.zig; the URLs are this module's
/// and the callback never touches them. A no-op when no backend is configured.
pub fn withActive(f: *const fn (*generate.Connection) void) void {
    if (conn) |*c| f(c);
}

/// The configured server URL, for prefilling the connections panel input so it shows what send
/// actually uses (mined from the settings blob), not a hardcoded default. Empty when none is set.
pub fn activeServerUrl() []const u8 {
    return if (conn) |c| c.api_server else "";
}

/// The type the selector renders and Connect persists. Falls back to the table default only when
/// nothing has been mined or picked, so the panel opens on the live configured backend.
pub fn selectedType() []const u8 {
    return if (selected_len == 0) textgen.default_type else selected_buf[0..selected_len];
}

fn storeSelected(t: []const u8) void {
    const n = @min(t.len, selected_buf.len);
    @memcpy(selected_buf[0..n], t[0..n]);
    selected_len = n;
}

/// The dropdown's onchange. Re-points the key field at the new type's secret and re-reads its state,
/// so one backend's key presence is never shown under another's name. The dropdown rerenders after
/// this returns; the state repaint rides the read's callback.
pub fn onTypeChange(value: []const u8) void {
    if (!textgen.isKnown(value)) return;
    if (std.mem.eql(u8, value, selectedType())) return;
    storeSelected(value);
    key_state = .{};
    setKeyStatus("");
    loadSecretState();
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
        setState(.none);
        return;
    };
    // The mined type wins over the table default even when the table does not offer it: the selector
    // showing "Select..." is honest about an unoffered backend, where showing llamacpp would not be.
    if (conn) |c| {
        if (c.api_type.len > 0) storeSelected(c.api_type);
    }
    updateConnState();
    checkStatus();
}

/// The pre-probe state: what the settings blob says, before the backend has been asked anything.
fn updateConnState() void {
    setState(if (conn == null) .none else .configured);
}

fn checkStatus() void {
    const c = conn orelse return;
    if (c.api_server.len == 0) return;
    const body = statusBody(c.api_server, c.api_type) orelse return;
    defer alloc.free(body);
    net.request("/api/backends/text-completions/status", body, 0, onBootStatusDone, .{});
}

// The boot pre-flight's answer. Notifications fire only on the states the user can DO something
// about; a healthy boot says nothing, because a toast on every load is noise nobody reads.
fn onBootStatusDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (conn == null) return;
    if (status == 0 or status == 502 or status == 504) {
        setState(.asleep);
        notifications.push(.warning, "Backend asleep - unlock at silly", notifications.error_ttl_ms);
        return;
    }
    if (status >= 200 and status < 300) {
        // ONE parse for both fields. Reading the body twice returns nothing the second time, which
        // showed up as the topbar naming the configured type instead of the model the probe reported.
        var offline = false;
        if (res) |r| {
            if (r.json(struct { result: []const u8 = "", online: ?bool = null })) |parsed| {
                defer parsed.deinit();
                if (parsed.value.online) |up| offline = !up;
                if (parsed.value.result.len > 0) storeProbedModel(parsed.value.result);
            } else |_| {}
        }
        if (offline) {
            setState(.offline);
            notifications.push(.warning, "Backend offline - unlock at silly", notifications.error_ttl_ms);
            return;
        }
        setState(.connected);
        return;
    }
    setStateErr(status);
    notifications.pushFmt(.err, notifications.error_ttl_ms, "Backend error {d}", .{status});
}

// ---- interactive connect (the connections panel) --------------------------------------------

/// Read the server URL from the panel input, probe the selected backend type, and on a reachable 200
/// persist the connection to the shared SillyTavern settings. Reflects progress into #conn-status.
pub fn connect() void {
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
    const body = statusBody(url, selectedType()) orelse {
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
        setState(.asleep);
        notifications.push(.warning, "Backend asleep - unlock at silly", notifications.error_ttl_ms);
        return;
    }
    if (status < 200 or status >= 300) {
        setConnStatusFmt("Connect failed: {d}", .{status});
        setStateErr(status);
        notifications.pushFmt(.err, notifications.error_ttl_ms, "Connect failed: {d}", .{status});
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
        setState(.offline);
        notifications.push(.warning, "Backend offline - unlock at silly", notifications.error_ttl_ms);
        return;
    }
    // Stash the model, then persist. "Connected" shows only once the save lands (onPersistDone), so a
    // caller waiting on it knows the connection was adopted, not merely probed.
    storeProbedModel(model);
    setConnStatus("Saving...");
    persistConnection(selectedType(), pending_url);
}

fn persistConnection(api_type: []const u8, url: []const u8) void {
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .api_type = api_type,
        .api_server = url,
    }, .{}) catch return;
    defer alloc.free(body);
    net.request("/api/settings/set-connection", body, 0, onPersistDone, .{});
}

fn onPersistDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (status < 200 or status >= 300) {
        setConnStatusFmt("Save failed: {d}", .{status});
        setStateErr(status);
        notifications.pushFmt(.err, notifications.error_ttl_ms, "Connection save failed: {d}", .{status});
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
    if (!adopted) applyConnection(selectedType(), pending_url);
    // A successful Connect has PROBED the backend, so the state is connected, not merely configured.
    setState(.connected);
    // "Connected" is the post-save signal: the connection is now adopted and send will use it.
    if (pending_model_len > 0) setConnStatusFmt("Connected: {s}", .{pending_model_buf[0..pending_model_len]}) else setConnStatus("Connected");
    notifications.pushFmt(.success, notifications.default_ttl_ms, "Connected: {s}", .{statusModel()});
}

/// Build an active connection from a type and URL with backend-neutral sampler defaults. The full
/// samplers stay in the settings blob server-side and reload on the next boot.
fn applyConnection(api_type: []const u8, api_server: []const u8) void {
    const t = alloc.dupe(u8, api_type) catch return;
    const s = alloc.dupe(u8, api_server) catch {
        alloc.free(t);
        return;
    };
    // The interactive Connect just probed the backend, so adopt its reported model (stock online_status)
    // as the tokenizer hint; an empty probe leaves it "" and the resolver falls to the llama default.
    const m = alloc.dupe(u8, pending_model_buf[0..pending_model_len]) catch {
        alloc.free(t);
        alloc.free(s);
        return;
    };
    // Preserve the padding mined from the settings blob across an interactive reconnect; the next boot
    // re-mines it. Default to the classic 64 when nothing has been mined yet.
    const padding: i64 = if (conn) |c| c.token_padding else 64;
    if (conn) |c| generate.freeConnection(alloc, c);
    conn = .{
        .api_type = t,
        .api_server = s,
        .model = m,
        .token_padding = padding,
        .max_context = 8192,
        .max_tokens = 512,
        .temperature = 1.0,
        .top_p = 1.0,
        .top_k = 0,
        .min_p = 0.0,
        .rep_pen = 1.0,
    };
    storeSelected(api_type);
}

// ---- the API key (write-only) ---------------------------------------------------------------

/// What the panel knows about the selected type's stored key. Never the key itself: `masked` holds a
/// locally re-masked tail, and the plaintext exists only inside saveKey's zeroed scratch buffers.
const KeyState = struct {
    requested: bool = false,
    loaded: bool = false,
    has: bool = false,
    // Sized to the mask, not to a key: too small to hold one even if the mask ever regressed.
    masked_buf: [secret_mask.width]u8 = undefined,
    masked_len: usize = 0,
    id_buf: [48]u8 = undefined,
    id_len: usize = 0,
};

var key_state: KeyState = .{};

/// True when the selected type authenticates with a key at all. Ollama does not, so its field is
/// never rendered rather than rendered dead.
pub fn keyFieldVisible() bool {
    return textgen.secretKeyFor(selectedType()) != null;
}

/// The key-presence line. Empty until the read lands, so the panel never claims "No key set" about a
/// backend it has not asked about yet.
pub fn keyStatusText(allocator: std.mem.Allocator) []const u8 {
    if (!key_state.loaded) return "";
    if (!key_state.has) return "No key set";
    if (key_state.masked_len == 0) return "Key set";
    return std.fmt.allocPrint(allocator, "Key set ({s})", .{key_state.masked_buf[0..key_state.masked_len]}) catch "Key set";
}

/// Fire the key-state read once per selected type. Called from the panel's client render, so a
/// session that never opens the panel never asks the server for secret state at all.
pub fn ensureSecretState() void {
    if (zx.platform.role != .client) return;
    if (key_state.requested) return;
    loadSecretState();
}

fn loadSecretState() void {
    if (zx.platform.role != .client) return;
    if (textgen.secretKeyFor(selectedType()) == null) return;
    key_state.requested = true;
    net.request("/api/secrets/read", "{}", 0, onSecretStateDone, .{});
}

fn onSecretStateDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    key_state.loaded = true;
    key_state.has = false;
    key_state.masked_len = 0;
    key_state.id_len = 0;
    defer zx.client.rerender();
    if (status < 200 or status >= 300) {
        log.warn("secret state read returned {d}", .{status});
        return;
    }
    const r = res orelse return;
    const key = textgen.secretKeyFor(selectedType()) orelse return;
    const parsed = r.json(std.json.Value) catch {
        log.warn("secret state read: response is not json", .{});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const entry = parsed.value.object.get(key) orelse return;
    if (entry != .array) return;
    adoptSecretState(entry.array.items);
}

/// Adopt the active secret for the selected key, falling back to the first when the server marks
/// none active (its own delete path reactivates index 0, so an inactive-only list is transient).
fn adoptSecretState(items: []const std.json.Value) void {
    var chosen: ?std.json.ObjectMap = null;
    for (items) |item| {
        if (item != .object) continue;
        if (chosen == null) chosen = item.object;
        const flag = item.object.get("active") orelse continue;
        if (flag == .bool and flag.bool) {
            chosen = item.object;
            break;
        }
    }
    const obj = chosen orelse return;
    key_state.has = true;
    if (obj.get("value")) |v| {
        if (v == .string) storeMasked(v.string);
    }
    if (obj.get("id")) |v| {
        if (v == .string) {
            const n = @min(v.string.len, key_state.id_buf.len);
            @memcpy(key_state.id_buf[0..n], v.string[0..n]);
            key_state.id_len = n;
        }
    }
}

/// Re-mask locally. `/api/secrets/read` returns the RAW value when allowKeysExposure is on
/// (secrets.js getMaskedValue), so masking here keeps a live key out of the DOM under either config.
/// The mask itself lives in secret_mask.zig, where `zig build test` proves it browser-free.
fn storeMasked(value: []const u8) void {
    key_state.masked_len = secret_mask.mask(value, &key_state.masked_buf).len;
}

/// Write the key field's value to the server's secret store. The value is never logged and never
/// echoed back: the field is cleared and the masked presence re-read instead.
pub fn saveKey() void {
    if (zx.platform.role != .client) return;
    const key = textgen.secretKeyFor(selectedType()) orelse return;
    const value = readKeyInput() orelse {
        setKeyStatus("Enter an API key");
        return;
    };
    defer {
        @memset(value, 0);
        alloc.free(value);
    }
    const body = std.json.Stringify.valueAlloc(alloc, .{
        .key = key,
        .value = value,
        .label = "SillyTavern client",
    }, .{}) catch return;
    defer {
        @memset(body, 0);
        alloc.free(body);
    }
    setKeyStatus("Saving key...");
    net.request("/api/secrets/write", body, 0, onKeyWriteDone, .{});
}

fn onKeyWriteDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (status < 200 or status >= 300) {
        setKeyStatusFmt("Key save failed: {d}", .{status});
        notifications.pushFmt(.err, notifications.error_ttl_ms, "API key save failed: {d}", .{status});
        return;
    }
    clearKeyInput();
    setKeyStatus("Key saved");
    notifications.push(.success, "API key saved", notifications.default_ttl_ms);
    key_state.requested = false;
    loadSecretState();
}

/// Delete the selected type's stored key. With no id the server deletes whichever secret is active
/// (secrets.js deleteSecret), which is the one the panel reported.
pub fn clearKey() void {
    if (zx.platform.role != .client) return;
    const key = textgen.secretKeyFor(selectedType()) orelse return;
    if (!key_state.has) return;
    const body = if (key_state.id_len > 0)
        std.json.Stringify.valueAlloc(alloc, .{
            .key = key,
            .id = key_state.id_buf[0..key_state.id_len],
        }, .{}) catch return
    else
        std.json.Stringify.valueAlloc(alloc, .{ .key = key }, .{}) catch return;
    defer alloc.free(body);
    setKeyStatus("Removing key...");
    net.request("/api/secrets/delete", body, 0, onKeyDeleteDone, .{});
}

fn onKeyDeleteDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    _ = res;
    if (status < 200 or status >= 300) {
        setKeyStatusFmt("Key removal failed: {d}", .{status});
        notifications.pushFmt(.err, notifications.error_ttl_ms, "API key removal failed: {d}", .{status});
        return;
    }
    setKeyStatus("Key removed");
    notifications.push(.success, "API key removed", notifications.default_ttl_ms);
    key_state.requested = false;
    loadSecretState();
}

// ---- helpers -------------------------------------------------------------------------------

fn statusBody(api_server: []const u8, api_type: []const u8) ?[]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .api_server = api_server,
        .api_type = api_type,
    }, .{}) catch null;
}

fn readUrlInput() ?[]u8 {
    return readInput("llama-url");
}

fn readKeyInput() ?[]u8 {
    return readInput("conn-api-key");
}

fn readInput(id: []const u8) ?[]u8 {
    if (zx.platform.role != .client) return null;
    const el = dom_event.elementById(alloc, id) orelse return null;
    defer el.deinit();
    const raw = el.ref.getAlloc(js.String, alloc, "value") catch return null;
    defer {
        @memset(raw, 0);
        alloc.free(raw);
    }
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return alloc.dupe(u8, trimmed) catch null;
}

fn clearKeyInput() void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(alloc, "conn-api-key") orelse return;
    defer el.deinit();
    el.ref.set("value", js.string("")) catch {};
}

fn setConnStatus(text: []const u8) void {
    reflectText("conn-status", text);
}

fn setKeyStatus(text: []const u8) void {
    reflectText("conn-key-status", text);
}

fn reflectText(id: []const u8, text: []const u8) void {
    if (zx.platform.role != .client) return;
    const el = dom_event.elementById(alloc, id) orelse return;
    defer el.deinit();
    el.ref.set("textContent", js.string(text)) catch {};
}

fn setConnStatusFmt(comptime fmt: []const u8, args: anytype) void {
    fmtInto("conn-status", fmt, args);
}

fn setKeyStatusFmt(comptime fmt: []const u8, args: anytype) void {
    fmtInto("conn-key-status", fmt, args);
}

fn fmtInto(id: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (zx.platform.role != .client) return;
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    reflectText(id, text);
}
