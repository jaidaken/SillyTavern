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

const net = @import("../platform/net.zig");
const generate = @import("./generate.zig");
const dom_event = @import("../platform/dom_event.zig");
const textgen = @import("./textgen_types.zig");
const secret_mask = @import("../platform/secret_mask.zig");
const char_data = @import("../cast/char_data.zig");
const regions = @import("../shell/regions.zig");
const notifications = @import("../notify/notifications.zig");
const server_events = @import("../platform/server_events.zig");

const alloc = @import("../cast/character_store.zig").page_gpa;
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

/// Once the user edits the Server URL field it is theirs, not the renderer's. The field used to bind
/// `value` straight to the mined URL, so any re-render (a boot settings load, a status probe, a live
/// event) rewrote the box and discarded what was being typed. That was a real data-loss bug and the
/// cause of the CONN-* interaction flake: whichever of the async settings load and the user's typing
/// finished last won. `url_dirty` flips on the first keystroke and from then on `urlFieldValue`
/// returns the typed text, so a re-render's diff is a no-op and never clobbers it. Same principle the
/// composer draft relies on, made explicit for a field that must also prefill.
var url_dirty: bool = false;
var url_typed_buf: [1024]u8 = undefined;
var url_typed_len: usize = 0;

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
/// THE STATES NAME WHAT IS DOWN, because there are two different machines in this path and telling a
/// user the wrong one sends them to fix something that is not broken. A request goes browser ->
/// SillyTavern -> the text-generation server, so a failure is one of:
///
/// - `app_down`: SillyTavern itself did not answer (a 502/504 from whatever proxies it, or a dead
///   socket). Nothing downstream was even asked. The page usually recovers on its own.
/// - `backend_down`: SillyTavern answered, and reports that the text-generation server did not. That
///   is the one a user fixes, by starting the server or correcting its URL.
/// - `err`: SillyTavern answered with an HTTP error of its own. The code is the whole story and is
///   kept in `state_code`.
///
/// These two were once called `asleep` and `offline`, which named neither machine, and both printed
/// the same remedy for opposite problems.
pub const ConnState = enum { none, configured, connected, backend_down, app_down, err };

var state: ConnState = .none;
var state_code: u16 = 0;

/// The state as a DATA value for the markup to key off (`data-conn-state`). Never a class name: the
/// tailwind scan reads `.zx` only, so appearance keyed on a Zig-built class would never be generated.
pub fn stateName() []const u8 {
    return @tagName(state);
}

/// The state IN WORDS, for the dot's accessible name and the panel's standing line. A dot that
/// carries its meaning only in colour tells a screen reader, and a red-green reader, nothing (WD38).
///
/// This is the LONG form, for the connections panel, where there is room to name the model and to
/// say what to do about a bad state. The top bar's chip uses `statusWord` instead.
pub fn statusWords(buf: *[status_words_len]u8) []const u8 {
    return switch (state) {
        .none => "No backend configured. Enter a server URL below and press Connect.",
        .configured => blk: {
            const c = conn orelse break :blk "No backend configured. Enter a server URL below and press Connect.";
            if (c.api_server.len == 0) {
                break :blk std.fmt.bufPrint(buf, "No server URL set for {s}. Enter one below and press Connect.", .{c.api_type}) catch "No server URL set. Enter one below and press Connect.";
            }
            break :blk std.fmt.bufPrint(buf, "{s} at {s} - not checked yet. Press Connect.", .{ c.api_type, c.api_server }) catch "Configured, not checked yet. Press Connect.";
        },
        .connected => blk: {
            const c = conn orelse break :blk "Connected";
            break :blk std.fmt.bufPrint(buf, "Connected to {s} - {s}", .{ c.api_type, statusModel() }) catch "Connected";
        },
        // Names the address, because "no response" is only actionable next to the thing that did not
        // respond: a typo in the URL and a server that is not running look identical without it.
        .backend_down => blk: {
            const c = conn orelse break :blk "The text-generation server did not respond.";
            break :blk std.fmt.bufPrint(buf, "No response from {s}. Check the server is running and that this address is reachable from SillyTavern.", .{c.api_server}) catch "The text-generation server did not respond. Check it is running.";
        },
        // The app itself, not the model behind it. The browser retries the live channel on its own,
        // so the honest instruction is to wait rather than to go and fix something.
        .app_down => blk: {
            if (state_code == 0) break :blk "SillyTavern is not responding. It may be restarting - this page reconnects on its own.";
            break :blk std.fmt.bufPrint(buf, "SillyTavern is not responding (HTTP {d}). It may be restarting - this page reconnects on its own.", .{state_code}) catch "SillyTavern is not responding. It may be restarting.";
        },
        .err => std.fmt.bufPrint(buf, "The connection check failed with HTTP {d}. {s}", .{ state_code, codeHint(state_code) }) catch "The connection check failed.",
    };
}

/// Room for the longest line above with a server URL and a backend type interpolated into it. A
/// bufPrint that does not fit falls back to the same sentence without the specifics, so an
/// unusually long URL degrades the message rather than truncating it mid-word.
pub const status_words_len = 256;

/// What an HTTP code from the check actually tells the user to go and do. Only the codes with a
/// distinct remedy are named; anything else gets the code alone, which is honest about knowing no
/// more than that.
fn codeHint(code: u16) []const u8 {
    return switch (code) {
        401, 403 => "The server rejected the credentials - check the API key.",
        404 => "Nothing answered at that path - check the server URL.",
        408, 504 => "The server took too long to answer.",
        429 => "The server is rate limiting - try again shortly.",
        500...503, 505...599 => "The server reported an internal error.",
        else => "",
    };
}

/// The SHORT form, for the top bar's status chip. The chip is a glance beside a coloured dot, not a
/// readout, so it says the state in one or two words and leaves the model name and the remedy to the
/// panel's standing line. This chip is also why the backend up/down TOASTS are gone: a state that is
/// permanently on screen does not need an interruption to announce it.
pub fn statusWord() []const u8 {
    return switch (state) {
        .none => "No backend",
        .configured => "Not connected",
        .connected => "Online",
        // Two words that name the machine, so the chip alone distinguishes "your model is not
        // running" from "the app you are looking at is having a moment".
        .backend_down => "No answer",
        .app_down => "App down",
        .err => "Error",
    };
}

/// What the topbar prints beside the dot: the model the backend reported, falling back to the type
/// so the button still names the backend before any probe has answered.
pub fn statusModel() []const u8 {
    if (pending_model_len > 0) return displayModel(pending_model_buf[0..pending_model_len]);
    const c = conn orelse return "";
    return c.api_type;
}

/// The model id as a NAME. A backend reports the id it was launched with, which for llama.cpp is the
/// absolute path of the weights file: `/mnt/data/AI/models/Wicked-Oblivion-12B.i1-Q4_K_M.gguf`. The
/// directory says where a file sits on a machine that is not necessarily this one, and every id ends
/// in the same format suffix, so neither answers "which model am I talking to" - they only push the
/// part that does off the edge of the chip.
///
/// Display only. `probedModel` keeps the id whole, because the tokenizer resolver matches on it
/// (char_api.zig:147) and a trimmed id would resolve to a different tokenizer, or to none.
fn displayModel(raw: []const u8) []const u8 {
    var name = raw;
    if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| name = name[i + 1 ..];
    if (std.mem.endsWith(u8, name, ".gguf")) name = name[0 .. name.len - ".gguf".len];
    return if (name.len > 0) name else raw;
}

/// What the chip in the top bar reads. A working backend names the MODEL, because "Online" answers a
/// question nobody asks twice while "which model am I talking to" is asked constantly; the dot beside
/// it already carries the healthy/unhealthy signal in colour. Any state that is not connected has no
/// model worth naming, so it falls back to the state word, which is then the whole message.
pub fn chipText() []const u8 {
    if (state != .connected) return statusWord();
    const model = statusModel();
    return if (model.len > 0) model else statusWord();
}

fn setState(s: ConnState) void {
    setStateCode(s, 0);
}

fn setStateErr(code: u16) void {
    setStateCode(.err, code);
}

/// The one place the state changes, and the one place it is logged. Logged on TRANSITION only: the
/// poll re-probes every few seconds and a line per probe would bury the moment something changed
/// under a hundred lines saying it had not. The line carries what a user would have to ask for next
/// anyway - which backend, at which address, and the code that decided it.
fn setStateCode(s: ConnState, code: u16) void {
    const changed = state != s or state_code != code;
    state = s;
    state_code = code;
    if (changed) logState();
    regions.bumpShell();
}

fn logState() void {
    const c = conn orelse {
        log.info("backend {s}: none configured", .{@tagName(state)});
        return;
    };
    switch (state) {
        .connected => log.info("backend connected: {s} at {s}, model {s}", .{ c.api_type, c.api_server, statusModel() }),
        .backend_down => log.warn("backend unreachable: {s} at {s} did not answer (SillyTavern reached it, the server did not reply)", .{ c.api_type, c.api_server }),
        .app_down => log.warn("SillyTavern unreachable: HTTP {d} before the request reached it", .{state_code}),
        .err => log.warn("backend check failed: HTTP {d} for {s} at {s}", .{ state_code, c.api_type, c.api_server }),
        .configured, .none => log.info("backend {s}: {s} at {s}", .{ @tagName(state), c.api_type, c.api_server }),
    }
}

/// Remember the model a status probe reported, so the topbar can name it. Shared by the boot
/// pre-flight and the interactive connect, which both read `result` off the same endpoint.
fn storeProbedModel(model: []const u8) void {
    const n = @min(model.len, pending_model_buf.len);
    @memcpy(pending_model_buf[0..n], model[0..n]);
    pending_model_len = n;
}

// ---- the standalone status poll (P1-E) -------------------------------------------------------

/// How often the standalone poll re-probes. This is the PRE-live-channel form and becomes the
/// fallback once the server pushes state, so it is built to be stood down (`stopPoll`) rather than
/// to own the status forever.
const default_poll_ms: u32 = 20000;
var poll_ms: u32 = default_poll_ms;

/// The cadence while the backend is NOT answering. A backend that is down is the state a user is
/// waiting to see END, so the probe that notices the recovery runs four times as often as the one
/// that re-confirms a connection nobody is watching. Both yield to `?pollms=`, which the browser gate
/// sets and which must stay the only cadence when it is present.
const down_poll_ms: u32 = 5000;
var poll_ms_forced: bool = false;

/// The interval the NEXT tick waits. Read per tick rather than stored, so a state change takes effect
/// on the following tick instead of needing the loop to be torn down and re-armed.
fn currentPollMs() u32 {
    if (poll_ms_forced) return poll_ms;
    return if (state == .connected) poll_ms else down_poll_ms;
}

/// Armed, not a timer handle: ziex exposes setTimeout with NO clearTimeout, so a poll is stopped by
/// refusing to reschedule (the reveal.zig/reading_prefs.zig pattern). The pending tick still fires
/// once and returns without arming another, which is why stopPoll cannot leave a loop running.
var poll_armed: bool = false;

/// Whether there is any reason for the client to keep probing. Autoconnect off does NOT mean blind:
/// a connection already established is still watched, so a backend that dies is reported the same
/// either way. What off withholds is the RECONNECT, so once the probe finds it gone the poll stops
/// and nothing hunts for its return until Connect is pressed.
fn pollWanted() bool {
    return autoConnect() or state == .connected;
}

/// Begin polling. Idempotent BY DESIGN: a second call while armed must not start a second timer, or
/// every settings load would double the probe rate for the life of the page.
pub fn startPoll() void {
    if (zx.platform.role != .client) return;
    // The live channel owns the status while it is up. The settings load arms the poll every time it
    // runs, so without this the two would both probe and every settings change would re-arm it.
    if (server_events.streamLive()) return;
    if (poll_armed) return;
    if (conn == null) return;
    if (!pollWanted()) return;
    poll_armed = true;
    schedulePoll();
}

/// Stand the poll down. The live channel calls this when it takes over; the pending tick observes
/// the flag and stops.
pub fn stopPoll() void {
    poll_armed = false;
}

pub fn pollArmed() bool {
    return poll_armed;
}

/// The server pushed the backend's state, so nothing here probed for it. `{"status":"online"|
/// "asleep"}`; an unrecognised status is left alone rather than guessed at.
///
/// The push is a STATE, not a connection: it carries no model name, so a chip resolved from this
/// alone can only fall back to naming the backend type. With autoconnect on, an online push is
/// therefore followed by one client probe, which is what turns "the backend is up" into "you are
/// talking to mistral-7b" without anyone opening the panel.
pub fn applyServerStatus(payload: []const u8) void {
    if (std.mem.indexOf(u8, payload, "\"online\"") != null) {
        setState(.connected);
        if (autoConnect()) checkStatus();
    } else if (std.mem.indexOf(u8, payload, "\"asleep\"") != null) {
        // The server's own word for it is "asleep", but what it MEANS is that SillyTavern probed the
        // text-generation server and got nothing. SillyTavern is plainly up - it just said so.
        setState(.backend_down);
    }
}

// ---- autoconnect ------------------------------------------------------------------------------

/// Whether the client finishes the connection ITSELF the moment the backend answers.
///
/// ON (the default): every status probe adopts what it finds, so a backend that comes up is named,
/// with its model, in the chip with no interaction at all - and one that goes down and returns
/// recovers on its own from asleep, offline or an error code.
/// OFF: a LIVE connection is still watched, so a backend that dies is still reported; what never
/// happens is the RECONNECT. Once it is gone the client stops hunting and waits for Connect.
///
/// It writes NO settings. The connection it adopts is the one already in the settings blob, so there
/// is nothing to save; a URL typed into the panel and not submitted is never picked up by this path.
const autoconnect_key = "st-conn-autoconnect";

/// Null until the first read, which is what pulls the stored preference. Lazy for the same reason
/// the system card's section is: most sessions never touch it, so it costs nothing until asked.
var autoconnect: ?bool = null;

pub fn autoConnect() bool {
    if (autoconnect) |v| return v;
    // Absent storage reads as ON: the feature is the behaviour a user expects from a status chip
    // that watches the backend, and a stored "false" is the only thing that should switch it off.
    const v = storedFlag(autoconnect_key) orelse true;
    autoconnect = v;
    return v;
}

/// The toggle's onchange. Turning it ON probes immediately rather than waiting for the next tick:
/// the click means "connect now", and a five-second wait after it reads as the switch not working.
pub fn setAutoConnect(v: bool) void {
    autoconnect = v;
    storeFlag(autoconnect_key, v);
    if (v) {
        checkStatus();
        startPoll();
    }
    regions.bumpShell();
}

pub fn autoConnectAttr() []const u8 {
    return if (autoConnect()) "true" else "";
}

fn storedFlag(key: []const u8) ?bool {
    if (zx.platform.role != .client) return null;
    const ls = js.global.get(js.Object, "localStorage") catch return null;
    defer ls.deinit();
    const raw = ls.callAlloc(?js.String, alloc, "getItem", .{js.string(key)}) catch return null;
    const value = raw orelse return null;
    defer alloc.free(value);
    return std.mem.eql(u8, value, "1");
}

fn storeFlag(key: []const u8, v: bool) void {
    if (zx.platform.role != .client) return;
    const ls = js.global.get(js.Object, "localStorage") catch return;
    defer ls.deinit();
    ls.call(void, "setItem", .{ js.string(key), js.string(if (v) "1" else "0") }) catch {
        log.warn("localStorage write refused: {s}", .{key});
    };
}

fn schedulePoll() void {
    if (!poll_armed) return;
    if (zx.client.setTimeout(pollTick, currentPollMs()) == null) {
        // No timer slot. Disarm rather than report a poll that is not running.
        poll_armed = false;
        log.warn("no timer slot for the status poll: the dot will not refresh on its own", .{});
    }
}

fn pollTick() void {
    if (!poll_armed) return;
    // The reason to poll went away since this tick was armed (autoconnect switched off, and the
    // probe that fired meanwhile found the backend gone). Stop here rather than reschedule: there is
    // no clearTimeout to cancel the pending tick with, so refusing to re-arm IS the stop.
    if (!pollWanted()) {
        poll_armed = false;
        return;
    }
    // A hidden tab probes NOTHING. Read at the tick rather than binding visibilitychange: the state
    // is only interesting at the moment a probe would fire.
    if (!documentHidden()) checkStatus();
    schedulePoll();
}

fn documentHidden() bool {
    if (zx.platform.role != .client) return false;
    const doc = js.global.get(js.Object, "document") catch return false;
    defer doc.deinit();
    return doc.get(bool, "hidden") catch false;
}

/// `?pollms=` shortens the interval for the browser gate, which cannot spend 20s per probe. Absent
/// on a real load, so the shipped cadence is the default.
fn readPollInterval() void {
    if (zx.platform.role != .client) return;
    const loc = js.global.get(js.Object, "location") catch return;
    defer loc.deinit();
    const search = loc.getAlloc(js.String, alloc, "search") catch return;
    defer alloc.free(search);
    const raw = char_data.queryValue(search, "pollms") orelse return;
    const parsed = std.fmt.parseInt(u32, raw, 10) catch return;
    if (parsed >= 100) {
        poll_ms = parsed;
        poll_ms_forced = true;
    }
}

/// A send stream came back 502/504, so the edge answered before SillyTavern was reached. Reported by
/// stream_drive at the seal: the failure is the connection's to hold, not the streamer's to paint.
///
/// This one DOES toast, where the ambient probe does not. The status chip can say the app is not
/// answering, but it cannot say that the message you just sent got no reply, and the eye is on the
/// conversation at that moment, not on the top bar. So the toast names the SEND that failed rather
/// than repeating the state the chip is already showing.
pub fn onStreamUnreachable() void {
    setStateCode(.app_down, 502);
    notifications.push(.err, "Send failed: SillyTavern did not respond. Your message was not delivered.", notifications.error_ttl_ms);
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

/// The value the Server URL field renders. The mined URL while the field is pristine, so the box
/// opens on what send actually uses; the typed text once the user has edited it, so a re-render can
/// never overwrite an in-progress URL with the mined one. `url_typed_buf` is stable module memory, so
/// the returned slice outlives the render without an allocation.
pub fn urlFieldValue() []const u8 {
    return if (url_dirty) url_typed_buf[0..url_typed_len] else activeServerUrl();
}

/// The field's oninput. Captures the typed value and marks the field dirty, so `urlFieldValue` stops
/// tracking the mined URL. A value longer than the buffer is truncated for storage only; Connect
/// still reads the live DOM value, so an over-long URL is never sent truncated.
pub fn onUrlInput(e: *zx.client.Event.Stateful) void {
    if (zx.platform.role != .client) return;
    const target = dom_event.statefulTarget(e) orelse return;
    const raw = target.getAlloc(js.String, alloc, "value") catch return;
    defer {
        @memset(raw, 0);
        alloc.free(raw);
    }
    const n = @min(raw.len, url_typed_buf.len);
    @memcpy(url_typed_buf[0..n], raw[0..n]);
    url_typed_len = n;
    url_dirty = true;
}

/// The type the selector renders and Connect persists. Falls back to the table default only when
/// nothing has been mined or picked, so the panel opens on the live configured backend.
pub fn selectedType() []const u8 {
    return if (selected_len == 0) textgen.default_type else selected_buf[0..selected_len];
}

fn storeSelected(t: []const u8) void {
    const n = @min(t.len, selected_buf.len);
    // copyForwards, not @memcpy: applyConnection reaches here as storeSelected(selectedType()),
    // whose slice IS selected_buf, and @memcpy forbids overlap (UB, and a panic in a safe build).
    std.mem.copyForwards(u8, selected_buf[0..n], t[0..n]);
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
            error.UnsupportedApi => log.info("send: unsupported backend, send disabled this phase", .{}),
            error.MissingConnection => log.info("send: no backend configured", .{}),
            else => log.warn("send: connection parse failed: {s}", .{@errorName(err)}),
        }
        setState(.none);
        return;
    };
    // The mined type wins over the table default even when the table does not offer it: the selector
    // showing "Select..." is honest about an unoffered backend, where showing llamacpp would not be.
    // The openai family is not a textgen type: keep its selector out of the textgen dropdown and skip
    // the textgen status probe (the chat server is polled elsewhere this phase).
    if (conn) |c| {
        if (c.family == .textgen) {
            if (c.api_type.len > 0) storeSelected(c.api_type);
            updateConnState();
            readPollInterval();
            checkStatus();
            startPoll();
            return;
        }
    }
    updateConnState();
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

// The boot pre-flight's answer. State changes drive the topbar status indicator; no toasts.
fn onBootStatusDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    if (conn == null) return;
    // A 502/504 comes from whatever sits in front of SillyTavern, and a 0 is a request that never
    // completed at all: either way the app was not reached, so nothing was learned about the model.
    if (status == 0 or status == 502 or status == 504) {
        setStateCode(.app_down, status);
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
        // SillyTavern answered fine and reports the text-generation server did not: `{online:false}`
        // is its deliberate way of saying "unreachable" without a 500 on every poll.
        if (offline) {
            setState(.backend_down);
            return;
        }
        setState(.connected);
        return;
    }
    setStateErr(status);
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

/// The INTERACTIVE Connect button's answer, which toasts where the ambient probe stays silent: the
/// user pressed a button and is owed the outcome, and a failure here is an event, not the standing
/// state the chip reports. Success stays quiet, being the "backend up" the chip already shows.
fn onProbeDone(tag: u64, status: u16, res: ?*zx.Fetch.Response) void {
    _ = tag;
    connecting = false;
    // The press failed before SillyTavern was reached, so nothing was learned about the URL just
    // typed. Saying so is the difference between "try again" and "your address is wrong".
    if (status == 0 or status == 502 or status == 504) {
        setConnStatus("SillyTavern did not respond, so the address was never checked. Try again shortly.");
        setStateCode(.app_down, status);
        notifications.push(.warning, "SillyTavern did not respond - the connection was not checked", notifications.error_ttl_ms);
        return;
    }
    if (status < 200 or status >= 300) {
        setConnStatusFmt("Check failed with HTTP {d}. {s}", .{ status, codeHint(status) });
        setStateErr(status);
        notifications.pushFmt(.err, notifications.error_ttl_ms, "Connection check failed: HTTP {d}", .{status});
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
    // The address was reached and answered nothing: the one failure a user can act on, so it names
    // the address rather than the state.
    if (offline) {
        setConnStatusFmt("No response from {s}. Check the server is running at that address.", .{pending_url});
        setState(.backend_down);
        notifications.push(.warning, "No response from the text-generation server", notifications.error_ttl_ms);
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
        // Reachable but NOT adopted, so the next send still has nothing to talk to: a state the
        // chip cannot express, which is why this one keeps its toast.
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
    // Sized like the standing line, which these sentences now match in length: a message that did
    // not fit used to be dropped in silence, leaving the panel claiming nothing had happened.
    var buf: [status_words_len]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch {
        log.warn("status line did not fit its buffer: {s}", .{fmt});
        return;
    };
    reflectText(id, text);
}
