//! `specrail lsp`: a Language Server Protocol server on stdin and stdout, so
//! that editors can move between specs and tests. It keeps the project's files
//! and check's analysis of them in memory, and updates both as documents
//! change, so that requests do not rescan the repository.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;

const check = @import("check.zig");
const cli = @import("cli.zig");
const diag = @import("diag.zig");
const files = @import("files.zig");
const nav = @import("lsp_nav.zig");
const project = @import("project.zig");
const text = @import("lsp_text.zig");

/// Help text for `specrail lsp --help`.
pub const usage =
    \\Usage: specrail lsp
    \\
    \\Run a Language Server Protocol server on stdin and stdout, for editors. The
    \\editor starts it once per workspace. It serves the project of the
    \\workspace's first folder, keeps its index in memory, and offers check's
    \\diagnostics, go to definition, find references and hover.
    \\
    \\Options:
    \\  --stdio   Accepted and ignored: stdin and stdout are the only transport
    \\  --help    Show this help
    \\
;

const parse_error = -32700;
const invalid_request = -32600;
const method_not_found = -32601;
const server_not_initialized = -32002;

/// Where the server is in the protocol's lifecycle.
const State = enum { initialized, shut_down, uninitialized };

/// A document the editor has open.
const Document = struct {
    uri: []const u8,
    text: []const u8,
};

/// A diagnostic as LSP has it.
const Diagnostic = struct {
    range: nav.Range,
    severity: u8,
    source: []const u8 = "specrail",
    message: []const u8,
};

fn field(v: ?json.Value, key: []const u8) ?json.Value {
    const value = v orelse return null;
    if (value != .object) return null;
    return value.object.get(key);
}

fn string(v: ?json.Value) ?[]const u8 {
    const value = v orelse return null;
    return if (value == .string) value.string else null;
}

fn integer(v: ?json.Value) ?i64 {
    const value = v orelse return null;
    return if (value == .integer) value.integer else null;
}

fn element(v: ?json.Value, i: usize) ?json.Value {
    const value = v orelse return null;
    if (value != .array or value.array.items.len <= i) return null;
    return value.array.items[i];
}

/// The server, between messages.
const Server = struct {
    ctx: *cli.Ctx,
    gpa: Allocator,
    state: State = .uninitialized,
    encoding: text.Encoding = .utf16,
    /// The client lets the server ask to hear of changes to files.
    watch: bool = false,
    /// Why there is no project, until the user has been told.
    missing: ?[]const u8 = null,
    /// The absolute path the project is looked for from; owned by `gpa`.
    workspace: ?[]const u8 = null,
    /// The project as it is on disk, in `disk_arena`.
    disk: ?project.Project = null,
    disk_arena: std.heap.ArenaAllocator,
    /// Open documents, by project path; keys and values are owned by `gpa`.
    open: std.array_hash_map.String(Document) = .empty,
    /// The index of the project with the open documents' text, in
    /// `index_arena`.
    index: ?nav.Index = null,
    index_arena: std.heap.ArenaAllocator,
    next_id: u32 = 1,

    fn init(ctx: *cli.Ctx) Server {
        return .{
            .ctx = ctx,
            .gpa = ctx.gpa,
            .disk_arena = .init(ctx.gpa),
            .index_arena = .init(ctx.gpa),
        };
    }

    fn deinit(s: *Server) void {
        for (s.open.keys(), s.open.values()) |path, d| s.free(path, d);
        s.open.deinit(s.gpa);
        s.disk_arena.deinit();
        s.index_arena.deinit();
        if (s.workspace) |w| s.gpa.free(w);
        if (s.missing) |m| s.gpa.free(m);
    }

    fn free(s: *Server, path: []const u8, d: Document) void {
        s.gpa.free(path);
        s.gpa.free(d.uri);
        s.gpa.free(d.text);
    }

    /// Reads and answers messages until the client says to exit, and returns
    /// the exit status.
    fn serve(s: *Server) cli.Error!u8 {
        const in = s.ctx.stdin orelse return 1;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        while (try readMessage(in, arena_state.allocator())) |body| {
            defer _ = arena_state.reset(.retain_capacity);
            if (try s.handle(arena_state.allocator(), body)) |status| return status;
        }
        // The stream ended without an exit notification.
        return if (s.state == .shut_down) 0 else 1;
    }

    /// Answers one message, and returns the exit status once the client
    /// says to exit.
    fn handle(s: *Server, arena: Allocator, body: []const u8) cli.Error!?u8 {
        const message = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch {
            try s.fail(arena, .null, parse_error, "the message is not JSON");
            return null;
        };
        const method = string(field(message, "method")) orelse {
            // A response to a request of the server's, which needs nothing.
            if (field(message, "id") == null) {
                try s.fail(arena, .null, invalid_request, "no method");
            }
            return null;
        };
        const params = field(message, "params");
        if (field(message, "id")) |id| {
            try s.request(arena, id, method, params);
            return null;
        }
        return s.notification(arena, method, params);
    }

    fn request(
        s: *Server,
        arena: Allocator,
        id: json.Value,
        method: []const u8,
        params: ?json.Value,
    ) cli.Error!void {
        const is = struct {
            fn is(m: []const u8, name: []const u8) bool {
                return std.mem.eql(u8, m, name);
            }
        }.is;
        if (s.state == .uninitialized and !is(method, "initialize")) {
            return s.fail(arena, id, server_not_initialized, "initialize first");
        }
        if (s.state == .shut_down) return s.fail(arena, id, invalid_request, "shutting down");
        if (is(method, "initialize")) return s.initialize(arena, id, params);
        if (is(method, "shutdown")) {
            s.state = .shut_down;
            return s.respond(arena, id, @as(?u8, null));
        }
        if (is(method, "textDocument/definition")) {
            const target = try s.targetAt(arena, params);
            const found = if (target) |t| try nav.definition(&s.index.?, arena, t) else null;
            return s.respond(arena, id, found);
        }
        if (is(method, "textDocument/references")) {
            const target = try s.targetAt(arena, params);
            const declaration = field(field(params, "context"), "includeDeclaration");
            const with_heading = if (declaration) |d| d == .bool and d.bool else false;
            const ix = if (s.index) |*ix| ix else null;
            const found = if (target) |t|
                try nav.references(ix.?, arena, t, with_heading)
            else
                &.{};
            return s.respond(arena, id, found);
        }
        if (is(method, "textDocument/hover")) return s.hover(arena, id, params);
        return s.fail(arena, id, method_not_found, "specrail does not offer this");
    }

    fn notification(
        s: *Server,
        arena: Allocator,
        method: []const u8,
        params: ?json.Value,
    ) cli.Error!?u8 {
        const is = struct {
            fn is(m: []const u8, name: []const u8) bool {
                return std.mem.eql(u8, m, name);
            }
        }.is;
        if (is(method, "exit")) return if (s.state == .shut_down) 0 else 1;
        if (s.state != .initialized) return null;
        if (is(method, "initialized")) {
            try s.initialized(arena);
        } else if (is(method, "textDocument/didOpen")) {
            const doc = field(params, "textDocument");
            try s.store(arena, string(field(doc, "uri")), string(field(doc, "text")));
        } else if (is(method, "textDocument/didChange")) {
            const changes = field(params, "contentChanges");
            const count = if (changes) |c| (if (c == .array) c.array.items.len else 0) else 0;
            // With full synchronization, the last change holds the whole text.
            const latest = if (count > 0) element(changes, count - 1) else null;
            const uri = string(field(field(params, "textDocument"), "uri"));
            try s.store(arena, uri, string(field(latest, "text")));
        } else if (is(method, "textDocument/didClose")) {
            try s.close(arena, string(field(field(params, "textDocument"), "uri")));
        } else if (is(method, "textDocument/didSave") or
            is(method, "workspace/didChangeWatchedFiles"))
        {
            try s.load();
            try s.refresh(arena);
        }
        return null;
    }

    fn send(s: *Server, arena: Allocator, message: anytype) cli.Error!void {
        const body = try json.Stringify.valueAlloc(arena, message, .{});
        try s.ctx.stdout.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try s.ctx.stdout.writeAll(body);
        try s.ctx.stdout.flush();
    }

    fn respond(s: *Server, arena: Allocator, id: json.Value, result: anytype) cli.Error!void {
        try s.send(arena, .{ .jsonrpc = "2.0", .id = id, .result = result });
    }

    fn fail(
        s: *Server,
        arena: Allocator,
        id: json.Value,
        code: i32,
        message: []const u8,
    ) cli.Error!void {
        const err = .{ .code = code, .message = message };
        try s.send(arena, .{ .jsonrpc = "2.0", .id = id, .@"error" = err });
    }

    fn notify(s: *Server, arena: Allocator, method: []const u8, params: anytype) cli.Error!void {
        try s.send(arena, .{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    /// Settles the position encoding, finds the project, and says what the
    /// server offers.
    fn initialize(
        s: *Server,
        arena: Allocator,
        id: json.Value,
        params: ?json.Value,
    ) cli.Error!void {
        const capabilities = field(params, "capabilities");
        const encodings = field(field(capabilities, "general"), "positionEncodings");
        if (encodings) |list| if (list == .array) for (list.array.items) |e| {
            if (e == .string and std.mem.eql(u8, e.string, "utf-8")) s.encoding = .utf8;
        };
        const watched = field(field(capabilities, "workspace"), "didChangeWatchedFiles");
        const dynamic = field(watched, "dynamicRegistration");
        s.watch = dynamic != null and dynamic.? == .bool and dynamic.?.bool;
        const folder = string(field(element(field(params, "workspaceFolders"), 0), "uri"));
        const root_uri = folder orelse string(field(params, "rootUri"));
        const root_path = string(field(params, "rootPath"));
        const root = if (root_uri) |u| try text.uriToPath(arena, u) else root_path;
        if (root) |r| {
            s.workspace = try s.gpa.dupe(u8, r);
            try s.load();
            try s.rebuild();
        } else {
            s.missing = try s.gpa.dupe(u8, "specrail: the editor named no workspace folder");
        }
        s.state = .initialized;
        try s.respond(arena, id, .{
            .capabilities = .{
                .positionEncoding = if (s.encoding == .utf8) "utf-8" else "utf-16",
                .textDocumentSync = .{ .openClose = true, .change = 1, .save = true },
                .definitionProvider = true,
                .referencesProvider = true,
                .hoverProvider = true,
            },
            .serverInfo = .{ .name = "specrail" },
        });
    }

    /// Tells the user why there is no project, and asks to hear of changes
    /// to files.
    fn initialized(s: *Server, arena: Allocator) cli.Error!void {
        if (s.disk == null) {
            if (s.missing) |why| {
                try s.notify(arena, "window/showMessage", .{ .type = 2, .message = why });
                s.gpa.free(why);
                s.missing = null;
            }
        }
        if (!s.watch) return;
        const watcher = .{ .globPattern = "**/*" };
        const registration = .{
            .id = "specrail-files",
            .method = "workspace/didChangeWatchedFiles",
            .registerOptions = .{ .watchers = .{watcher} },
        };
        try s.send(arena, .{
            .jsonrpc = "2.0",
            .id = s.next_id,
            .method = "client/registerCapability",
            .params = .{ .registrations = .{registration} },
        });
        s.next_id += 1;
    }

    /// Reads the project from disk again. The index pointed into the old
    /// files, so it is dropped until `rebuild`.
    fn load(s: *Server) cli.Error!void {
        const workspace = s.workspace orelse return;
        s.index = null;
        s.disk = null;
        _ = s.disk_arena.reset(.free_all);
        const arena = s.disk_arena.allocator();
        var why: Io.Writer.Allocating = .init(arena);
        var local = s.ctx.*;
        local.cwd = workspace;
        local.arena = arena;
        local.stderr = &why.writer;
        s.disk = try project.open(&local);
        if (s.disk == null and s.missing == null) {
            const reason = std.mem.trim(u8, why.written(), " \t\r\n");
            s.missing = try s.gpa.dupe(u8, reason);
        }
    }

    /// Analyzes the project again, with the open documents' text in place of
    /// what is on disk.
    fn rebuild(s: *Server) cli.Error!void {
        const disk = s.disk orelse {
            s.index = null;
            return;
        };
        var next: std.heap.ArenaAllocator = .init(s.gpa);
        errdefer next.deinit();
        const arena = next.allocator();
        var spec_files: std.ArrayList(project.SourceFile) = .empty;
        errdefer spec_files.deinit(arena);
        var source_files: std.ArrayList(project.SourceFile) = .empty;
        errdefer source_files.deinit(arena);
        try s.overlay(arena, disk.spec_files, &spec_files);
        try s.overlay(arena, disk.source_files, &source_files);
        for (s.open.keys(), s.open.values()) |path, d| {
            if (listed(disk, path)) continue;
            // A new file the listing does not have yet.
            const is_spec = files.isUnder(path, disk.config.spec_root) and
                std.mem.endsWith(u8, path, ".spec.md");
            const list = if (is_spec) &spec_files else &source_files;
            try list.append(arena, .{ .path = path, .content = d.text });
        }
        var contents: std.StringHashMapUnmanaged([]const u8) = .empty;
        errdefer contents.deinit(arena);
        for ([_][]const project.SourceFile{ spec_files.items, source_files.items }) |list| {
            for (list) |f| try contents.put(arena, f.path, f.content);
        }
        const input: check.Input = .{
            .spec_files = spec_files.items,
            .source_files = source_files.items,
        };
        const analysis = try check.analyze(arena, input, s.ctx.now);
        s.index_arena.deinit();
        s.index_arena = next;
        s.index = .{
            .root = disk.root,
            .analysis = analysis,
            .source_files = source_files.items,
            .contents = contents,
            .encoding = s.encoding,
        };
    }

    fn overlay(
        s: *const Server,
        arena: Allocator,
        from: []const project.SourceFile,
        to: *std.ArrayList(project.SourceFile),
    ) Allocator.Error!void {
        for (from) |f| {
            const content = if (s.open.get(f.path)) |d| d.text else f.content;
            try to.append(arena, .{ .path = f.path, .content = content });
        }
    }

    /// The project path of a document; null outside the project.
    fn projectPath(
        s: *const Server,
        arena: Allocator,
        uri: []const u8,
    ) Allocator.Error!?[]const u8 {
        const disk = s.disk orelse return null;
        const abs = (try text.uriToPath(arena, uri)) orelse return null;
        const inside = abs.len > disk.root.len + 1 and std.mem.startsWith(u8, abs, disk.root) and
            abs[disk.root.len] == '/';
        return if (inside) abs[disk.root.len + 1 ..] else null;
    }

    /// Keeps the text of a document the editor opened or changed, and
    /// updates the index and the diagnostics.
    fn store(
        s: *Server,
        arena: Allocator,
        uri_given: ?[]const u8,
        text_given: ?[]const u8,
    ) cli.Error!void {
        const uri = uri_given orelse return;
        const content = text_given orelse return;
        const path = (try s.projectPath(arena, uri)) orelse return;
        const owned = try s.gpa.dupe(u8, content);
        errdefer s.gpa.free(owned);
        var old: ?[]const u8 = null;
        if (s.open.getPtr(path)) |d| {
            old = d.text;
            d.text = owned;
        } else {
            const key = try s.gpa.dupe(u8, path);
            errdefer s.gpa.free(key);
            const owned_uri = try s.gpa.dupe(u8, uri);
            errdefer s.gpa.free(owned_uri);
            try s.open.put(s.gpa, key, .{ .uri = owned_uri, .text = owned });
        }
        try s.refresh(arena);
        // The old index pointed into the old text until the refresh.
        if (old) |o| s.gpa.free(o);
    }

    fn close(s: *Server, arena: Allocator, uri_given: ?[]const u8) cli.Error!void {
        const uri = uri_given orelse return;
        const path = (try s.projectPath(arena, uri)) orelse return;
        const removed = s.open.fetchSwapRemove(path) orelse return;
        defer s.free(removed.key, removed.value);
        try s.refresh(arena);
        // Diagnostics for a closed document are cleared.
        try s.notify(arena, "textDocument/publishDiagnostics", .{
            .uri = removed.value.uri,
            .diagnostics = &[_]Diagnostic{},
        });
    }

    /// Rebuilds the index, and publishes diagnostics for every open
    /// document, since a change to one file can change another's.
    fn refresh(s: *Server, arena: Allocator) cli.Error!void {
        try s.rebuild();
        for (s.open.keys(), s.open.values()) |path, d| {
            var found: std.ArrayList(Diagnostic) = .empty;
            defer found.deinit(arena);
            if (s.index) |ix| for (ix.analysis.diagnostics.items) |x| {
                if (std.mem.eql(u8, x.path, path)) try found.append(arena, s.diagnostic(d.text, x));
            };
            try s.notify(arena, "textDocument/publishDiagnostics", .{
                .uri = d.uri,
                .diagnostics = found.items,
            });
        }
    }

    fn diagnostic(s: *const Server, content: []const u8, x: diag.Diagnostic) Diagnostic {
        const index = if (x.line > 0) x.line - 1 else 0;
        const l = text.lineAt(content, index);
        const start = text.column(l, if (x.column > 0) x.column - 1 else 0, s.encoding);
        const end = @max(start, text.column(l, l.len, s.encoding));
        return .{
            .range = .{
                .start = .{ .line = index, .character = start },
                .end = .{ .line = index, .character = end },
            },
            .severity = switch (x.severity) {
                .err => 1,
                .note => 3,
                .warning => 2,
            },
            .message = x.message,
        };
    }

    /// What the position a request names is on.
    fn targetAt(
        s: *const Server,
        arena: Allocator,
        params: ?json.Value,
    ) Allocator.Error!?nav.Target {
        if (s.index == null) return null;
        const ix = &s.index.?;
        const uri = string(field(field(params, "textDocument"), "uri")) orelse return null;
        const position = field(params, "position");
        const line = integer(field(position, "line")) orelse return null;
        const character = integer(field(position, "character")) orelse return null;
        if (line < 0 or character < 0) return null;
        const path = (try s.projectPath(arena, uri)) orelse return null;
        const content = ix.contents.get(path) orelse return null;
        const index: u32 = @intCast(line);
        const byte = text.byteOffset(text.lineAt(content, index), @intCast(character), s.encoding);
        return nav.targetAt(ix, path, index, byte);
    }

    fn hover(s: *Server, arena: Allocator, id: json.Value, params: ?json.Value) cli.Error!void {
        const target = try s.targetAt(arena, params);
        const markdown = if (target) |t| try nav.hover(&s.index.?, arena, t) else null;
        const Contents = struct { kind: []const u8, value: []const u8 };
        const Hover = struct { contents: Contents };
        const found: ?Hover = if (markdown) |m|
            .{ .contents = .{ .kind = "markdown", .value = m } }
        else
            null;
        try s.respond(arena, id, found);
    }
};

fn listed(disk: project.Project, path: []const u8) bool {
    for ([_][]const project.SourceFile{ disk.spec_files, disk.source_files }) |list| {
        for (list) |f| {
            if (std.mem.eql(u8, f.path, path)) return true;
        }
    }
    return false;
}

/// Reads one JSON-RPC message, framed by its `Content-Length` header, and
/// returns its body; null at the end of the stream.
fn readMessage(in: *Io.Reader, arena: Allocator) Allocator.Error!?[]const u8 {
    var length: ?usize = null;
    // Each header line is read whole; the empty line ends the headers.
    while (in.takeDelimiter('\n') catch return null) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        length = std.fmt.parseInt(usize, value, 10) catch null;
    } else return null;
    const n = length orelse return "";
    return in.readAllocAll(arena, n) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// Runs `specrail lsp` and returns its exit status.
pub fn run(ctx: *cli.Ctx) cli.Error!u8 {
    var server: Server = .init(ctx);
    defer server.deinit();
    return server.serve();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sandbox = @import("sandbox.zig");

const Sandbox = sandbox.Sandbox;

const a_spec =
    \\# § 1 Login
    \\
    \\## § 1.1 Password
    \\```toml
    \\x-owner = "auth"
    \\```
    \\
    \\It MUST accept a password.
    \\
    \\## § 1.2 Google
    \\
    \\It MUST accept Google.
    \\
;

const b_spec =
    \\# § 1 Waits
    \\```toml
    \\dependencies = ["specs/a.spec.md § 1.2 Google"]
    \\```
    \\
    \\It MUST wait.
    \\
;

const t_zig =
    \\// specrail: specs/a.spec.md § 1.1 Password
    \\// specrail: specs/a.spec.md § 1.2 Google
    \\// specrail: specs/b.spec.md § 1 Waits
    \\
;

/// Two spec files, one with a dependency entry naming the other, and a file
/// of tests that references every leaf.
fn lspProject(s: *Sandbox) !void {
    try s.write("specrail.toml", "spec_root = \"specs\"\n");
    try s.write("specs/a.spec.md", a_spec);
    try s.write("specs/b.spec.md", b_spec);
    try s.write("src/t.zig", t_zig);
}

/// A session with the server: messages to send, and what came back.
const Session = struct {
    box: *Sandbox,
    input: std.ArrayList(u8) = .empty,

    fn arena(se: *Session) Allocator {
        return se.box.arena_state.allocator();
    }

    fn uri(se: *Session, path: []const u8) ![]const u8 {
        const abs = try std.Io.Dir.path.join(se.arena(), &.{ se.box.root, path });
        return text.pathToUri(se.arena(), abs);
    }

    fn send(se: *Session, message: anytype) !void {
        const body = try json.Stringify.valueAlloc(se.arena(), message, .{});
        try se.input.print(se.arena(), "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    }

    /// Initializes with the project as the first workspace folder.
    fn start(se: *Session, encodings: []const []const u8) !void {
        const folder = .{ .uri = try se.uri(""), .name = "project" };
        const elsewhere = .{ .uri = "file:///nonexistent/specrail", .name = "other" };
        try se.send(.{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{
            .workspaceFolders = .{ folder, elsewhere },
            .rootUri = "file:///nonexistent/specrail-root",
            .capabilities = .{ .general = .{ .positionEncodings = encodings } },
        } });
        try se.send(.{ .jsonrpc = "2.0", .method = "initialized", .params = .{} });
    }

    /// A request about position `line`:`character` of the file at `path`.
    fn ask(se: *Session, id: i64, method: []const u8, path: []const u8, at: nav.Position) !void {
        try se.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = .{
            .textDocument = .{ .uri = try se.uri(path) },
            .position = at,
            .context = .{ .includeDeclaration = false },
        } });
    }

    fn finish(se: *Session) !void {
        try se.send(.{ .jsonrpc = "2.0", .id = 99, .method = "shutdown" });
        try se.send(.{ .jsonrpc = "2.0", .method = "exit" });
    }

    fn run(se: *Session) !Replies {
        const o = try se.box.runIn("", &.{"lsp"}, .{ .stdin = se.input.items });
        return .{ .code = o.code, .messages = try framed(se.arena(), o.stdout) };
    }
};

/// What the server wrote, and its exit status.
const Replies = struct {
    code: u8,
    messages: []const json.Value,

    fn result(r: Replies, id: i64) ?json.Value {
        for (r.messages) |m| {
            if (integer(field(m, "id")) == id) return field(m, "result") orelse field(m, "error");
        }
        return null;
    }

    fn notifications(r: Replies, arena: Allocator, method: []const u8) ![]const json.Value {
        var out: std.ArrayList(json.Value) = .empty;
        errdefer out.deinit(arena);
        for (r.messages) |m| {
            const name = string(field(m, "method")) orelse continue;
            if (std.mem.eql(u8, name, method)) try out.append(arena, field(m, "params").?);
        }
        return out.toOwnedSlice(arena);
    }
};

/// The messages in `stream`, each framed by its `Content-Length` header.
fn framed(arena: Allocator, stream: []const u8) ![]const json.Value {
    var out: std.ArrayList(json.Value) = .empty;
    errdefer out.deinit(arena);
    var reader: Io.Reader = .fixed(stream);
    while (try readMessage(&reader, arena)) |body| {
        try out.append(arena, try json.parseFromSliceLeaky(json.Value, arena, body, .{}));
    }
    return out.toOwnedSlice(arena);
}

fn startLine(location: ?json.Value) ?i64 {
    return integer(field(field(field(location, "range"), "start"), "line"));
}

// specrail: specs/lsp.spec.md § 1.1 Transport
// specrail: specs/lsp.spec.md § 1.3 Exit status
// specrail: specs/lsp.spec.md § 1.6 Workspace folders
test "the server answers framed JSON-RPC, and exits 0 only after a shutdown" {
    var s = try Sandbox.init();
    defer s.deinit();
    try lspProject(&s);
    var early: Session = .{ .box = &s };
    try early.send(.{ .jsonrpc = "2.0", .id = 0, .method = "textDocument/hover", .params = .{} });
    try early.start(&.{"utf-16"});
    try early.ask(2, "textDocument/definition", "src/t.zig", .{ .line = 0, .character = 5 });
    try early.finish();
    const r = try early.run();
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqual(@as(?i64, server_not_initialized), integer(field(r.result(0), "code")));
    const capabilities = field(r.result(1), "capabilities");
    try testing.expectEqual(true, field(capabilities, "definitionProvider").?.bool);
    // The first workspace folder holds the project, so definition finds it.
    try testing.expectEqual(@as(?i64, 2), startLine(r.result(2)));
    try testing.expectEqual(json.Value.null, r.result(99).?);
    const arena = s.arena_state.allocator();
    try testing.expectEqual(@as(usize, 0), (try r.notifications(arena, "window/showMessage")).len);
    var abrupt: Session = .{ .box = &s };
    try abrupt.start(&.{"utf-16"});
    try abrupt.send(.{ .jsonrpc = "2.0", .method = "exit" });
    try testing.expectEqual(@as(u8, 1), (try abrupt.run()).code);
}

// specrail: specs/lsp.spec.md § 1.6 Workspace folders
test "without workspace folders, the server serves the project of the root" {
    var s = try Sandbox.init();
    defer s.deinit();
    try lspProject(&s);
    var se: Session = .{ .box = &s };
    const params = .{ .rootUri = try se.uri("") };
    try se.send(.{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = params });
    try se.ask(2, "textDocument/definition", "src/t.zig", .{ .line = 1, .character = 5 });
    try se.finish();
    try testing.expectEqual(@as(?i64, 9), startLine((try se.run()).result(2)));
}

// specrail: specs/lsp.spec.md § 1.4 Position encoding
test "positions count UTF-8 bytes when the client offers them, and UTF-16 code units otherwise" {
    var s = try Sandbox.init();
    defer s.deinit();
    try lspProject(&s);
    const line = text.lineAt(t_zig, 1);
    for ([_][]const u8{ "utf-8", "utf-16" }) |encoding| {
        var se: Session = .{ .box = &s };
        try se.start(&.{ "utf-16", encoding });
        try se.ask(2, "textDocument/references", "specs/a.spec.md", .{ .line = 9, .character = 0 });
        try se.finish();
        const r = try se.run();
        const offered = string(field(field(r.result(1), "capabilities"), "positionEncoding")).?;
        try testing.expectEqualStrings(encoding, offered);
        const range = field(element(r.result(2), 0), "range");
        const end = integer(field(field(range, "end"), "character"));
        // § is two bytes, and one UTF-16 code unit.
        const length: i64 = @intCast(line.len);
        const expected = if (std.mem.eql(u8, encoding, "utf-8")) length else length - 1;
        try testing.expectEqual(@as(?i64, expected), end);
    }
}

// specrail: specs/lsp.spec.md § 1.5 Without a project
test "without a project, the server keeps running, answers emptily, and says why once" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.write("src/t.zig", t_zig);
    var se: Session = .{ .box = &s };
    try se.start(&.{"utf-16"});
    try se.ask(2, "textDocument/definition", "src/t.zig", .{ .line = 0, .character = 5 });
    try se.ask(3, "textDocument/references", "src/t.zig", .{ .line = 0, .character = 5 });
    try se.finish();
    const r = try se.run();
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(field(r.result(1), "capabilities") != null);
    try testing.expectEqual(json.Value.null, r.result(2).?);
    try testing.expectEqual(@as(usize, 0), r.result(3).?.array.items.len);
    const shown = try r.notifications(s.arena_state.allocator(), "window/showMessage");
    try testing.expectEqual(@as(usize, 1), shown.len);
    try sandbox.expectContains(string(field(shown[0], "message")).?, "specrail.toml");
}

// specrail: specs/lsp.spec.md § 2.1 Reference to section
test "go to definition leads from a reference line or dependency entry to the heading" {
    var s = try Sandbox.init();
    defer s.deinit();
    try lspProject(&s);
    var se: Session = .{ .box = &s };
    try se.start(&.{"utf-16"});
    try se.ask(2, "textDocument/definition", "src/t.zig", .{ .line = 1, .character = 5 });
    try se.ask(3, "textDocument/definition", "specs/b.spec.md", .{ .line = 2, .character = 20 });
    try se.ask(4, "textDocument/definition", "specs/b.spec.md", .{ .line = 5, .character = 2 });
    try se.finish();
    const r = try se.run();
    const heading = try se.uri("specs/a.spec.md");
    for ([_]i64{ 2, 3 }) |id| {
        try testing.expectEqualStrings(heading, string(field(r.result(id), "uri")).?);
        try testing.expectEqual(@as(?i64, 9), startLine(r.result(id)));
    }
    try testing.expectEqual(json.Value.null, r.result(4).?);
}

// specrail: specs/lsp.spec.md § 2.2 Section to references
test "find references on a heading lists everything naming the section or one below it" {
    var s = try Sandbox.init();
    defer s.deinit();
    try lspProject(&s);
    var se: Session = .{ .box = &s };
    try se.start(&.{"utf-16"});
    try se.ask(2, "textDocument/references", "specs/a.spec.md", .{ .line = 0, .character = 3 });
    try se.finish();
    const r = try se.run();
    var found: std.ArrayList([]const u8) = .empty;
    const arena = se.arena();
    for (r.result(2).?.array.items) |location| {
        const file = std.Io.Dir.path.basename(string(field(location, "uri")).?);
        try found.append(arena, try arena.print("{s}:{d}", .{ file, startLine(location).? }));
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    const joined = try std.mem.join(arena, " ", found.items);
    try testing.expectEqualStrings("b.spec.md:2 t.zig:0 t.zig:1", joined);
}

// specrail: specs/lsp.spec.md § 2.3 Hover
test "hover on a reference shows the section's heading, metadata block and prose" {
    var s = try Sandbox.init();
    defer s.deinit();
    try lspProject(&s);
    var se: Session = .{ .box = &s };
    try se.start(&.{"utf-16"});
    try se.ask(2, "textDocument/hover", "src/t.zig", .{ .line = 0, .character = 5 });
    try se.finish();
    const r = try se.run();
    const contents = field(r.result(2), "contents");
    try testing.expectEqualStrings("markdown", string(field(contents, "kind")).?);
    try testing.expectEqualStrings(
        "## § 1.1 Password\n```toml\nx-owner = \"auth\"\n```\n\nIt MUST accept a password.",
        string(field(contents, "value")).?,
    );
}

/// The diagnostics last published for `uri`, by their messages.
fn published(arena: Allocator, r: Replies, uri: []const u8, nth: usize) ![]const json.Value {
    const all = try r.notifications(arena, "textDocument/publishDiagnostics");
    var seen: usize = 0;
    for (all) |p| {
        if (!std.mem.eql(u8, string(field(p, "uri")).?, uri)) continue;
        if (seen == nth) return field(p, "diagnostics").?.array.items;
        seen += 1;
    }
    return error.TestUnexpectedResult;
}

// specrail: specs/lsp.spec.md § 1.2 Live index
// specrail: specs/lsp.spec.md § 3.1 Diagnostics
test "unsaved changes update the index, and every open document's diagnostics" {
    var s = try Sandbox.init();
    defer s.deinit();
    try lspProject(&s);
    var se: Session = .{ .box = &s };
    try se.start(&.{"utf-16"});
    const spec_uri = try se.uri("specs/a.spec.md");
    const test_uri = try se.uri("src/t.zig");
    const stale = try std.mem.replaceOwned(u8, se.arena(), t_zig, "1.2 Google", "1.2 Gogle");
    try se.send(.{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{
        .textDocument = .{
            .uri = spec_uri,
            .languageId = "markdown",
            .version = 1,
            .text = a_spec,
        },
    } });
    try se.send(.{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{
        .textDocument = .{ .uri = test_uri, .languageId = "zig", .version = 1, .text = t_zig },
    } });
    for ([_][]const u8{ stale, t_zig }) |content| {
        try se.send(.{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{
            .textDocument = .{ .uri = test_uri, .version = 2 },
            .contentChanges = .{.{ .text = content }},
        } });
    }
    try se.finish();
    const r = try se.run();
    const arena = se.arena();
    // Published once for the spec at its opening, once more with the test's.
    try testing.expectEqual(@as(usize, 0), (try published(arena, r, spec_uri, 1)).len);
    const broken = try published(arena, r, test_uri, 1);
    try testing.expectEqual(@as(usize, 1), broken.len);
    try sandbox.expectContains(string(field(broken[0], "message")).?, "stale");
    try testing.expectEqual(@as(?i64, 1), integer(field(broken[0], "severity")));
    // The spec's leaf lost its test, and the open spec says so.
    const untested = try published(arena, r, spec_uri, 2);
    try testing.expectEqual(@as(usize, 1), untested.len);
    try testing.expectEqual(@as(?i64, 9), startLine(untested[0]));
    try testing.expectEqual(@as(usize, 0), (try published(arena, r, spec_uri, 3)).len);
    try testing.expectEqual(@as(usize, 0), (try published(arena, r, test_uri, 2)).len);
}

/// A context like the command line's, for driving the server one message at
/// a time, with its stdout.
fn drive(s: *Sandbox) !struct { *cli.Ctx, *Io.Writer.Allocating } {
    const arena = s.arena_state.allocator();
    const out = try arena.create(Io.Writer.Allocating);
    out.* = .init(arena);
    const err = try arena.create(Io.Writer.Allocating);
    err.* = .init(arena);
    const ctx = try arena.create(cli.Ctx);
    ctx.* = .{
        .arena = arena,
        .io = testing.io,
        .stdout = &out.writer,
        .stderr = &err.writer,
        .cwd = s.root,
        .now = 20774 * 86400,
        .git_env = &s.env,
        .root_ceiling = s.root,
        .gpa = testing.allocator,
    };
    return .{ ctx, out };
}

fn deliver(server: *Server, message: anytype) !void {
    const arena = server.ctx.arena;
    _ = try server.handle(arena, try json.Stringify.valueAlloc(arena, message, .{}));
}

// specrail: specs/lsp.spec.md § 1.2 Live index
test "files created, changed or deleted on disk reach the index when the client says so" {
    var s = try Sandbox.init();
    defer s.deinit();
    try lspProject(&s);
    try s.write("src/t.zig", t_zig ++ "// specrail: specs/c.spec.md § 1 New\n");
    const ctx, const out = try drive(&s);
    var server: Server = .init(ctx);
    defer server.deinit();
    var se: Session = .{ .box = &s };
    const root = try se.uri("");
    const init_params = .{ .rootUri = root };
    const initialize = .{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "initialize",
        .params = init_params,
    };
    try deliver(&server, initialize);
    const t = try se.uri("src/t.zig");
    const where = .{ .textDocument = .{ .uri = t }, .position = .{ .line = 3, .character = 5 } };
    const definition = "textDocument/definition";
    const ask = .{ .jsonrpc = "2.0", .id = 2, .method = definition, .params = where };
    const watched = "workspace/didChangeWatchedFiles";
    const changed = .{ .jsonrpc = "2.0", .method = watched, .params = .{} };
    try deliver(&server, ask);
    try s.write("specs/c.spec.md", "# § 1 New\n\nIt MUST be new.\n");
    try deliver(&server, changed);
    try deliver(&server, ask);
    try s.tmp.dir.deleteFile(testing.io, "specs/c.spec.md");
    try deliver(&server, changed);
    try deliver(&server, ask);
    const r: Replies = .{ .code = 0, .messages = try framed(ctx.arena, out.written()) };
    var answers: std.ArrayList(?json.Value) = .empty;
    for (r.messages) |m| {
        if (integer(field(m, "id")) == 2) try answers.append(ctx.arena, field(m, "result"));
    }
    try testing.expectEqual(@as(usize, 3), answers.items.len);
    try testing.expectEqual(json.Value.null, answers.items[0].?);
    try testing.expectEqual(@as(?i64, 0), startLine(answers.items[1]));
    try testing.expectEqual(json.Value.null, answers.items[2].?);
}
