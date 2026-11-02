const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.window_layout);

/// A declarative terminal layout loaded from a JSON file.
///
/// The root may be a window, tab, split, or terminal. Actions that create a
/// tab require a tab-compatible root; actions that create a window accept any
/// root and create an implicit window when necessary.
pub const Node = union(enum) {
    window: Container,
    tab: Container,
    split: Split,
    terminal: Terminal,

    pub const Container = struct {
        children: []const *Node,
    };

    pub const Split = struct {
        direction: Direction,
        ratio: f16,
        first: *Node,
        second: *Node,
    };

    pub const Terminal = struct {
        command: ?[:0]const u8 = null,
        working_directory: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,
        focus: bool = false,
    };

    pub const Direction = enum {
        horizontal,
        vertical,
    };

    pub fn countTerminals(self: *const Node) usize {
        return switch (self.*) {
            .window, .tab => |container| count: {
                var total: usize = 0;
                for (container.children) |child| total += child.countTerminals();
                break :count total;
            },
            .split => |split| split.first.countTerminals() + split.second.countTerminals(),
            .terminal => 1,
        };
    }

    pub fn firstFocusedTerminal(self: *const Node) ?*const Terminal {
        return switch (self.*) {
            .window, .tab => |container| focused: {
                for (container.children) |child| {
                    if (child.firstFocusedTerminal()) |terminal| break :focused terminal;
                }
                break :focused null;
            },
            .split => |split| split.first.firstFocusedTerminal() orelse
                split.second.firstFocusedTerminal(),
            .terminal => |*terminal| if (terminal.focus) terminal else null,
        };
    }

    pub fn firstTerminal(self: *const Node) ?*const Terminal {
        return switch (self.*) {
            .window, .tab => |container| first: {
                for (container.children) |child| {
                    if (child.firstTerminal()) |terminal| break :first terminal;
                }
                break :first null;
            },
            .split => |split| split.first.firstTerminal() orelse
                split.second.firstTerminal(),
            .terminal => |*terminal| terminal,
        };
    }
};

pub const ParseError = error{
    InvalidLayout,
    InvalidNodeType,
    InvalidDirection,
    InvalidRatio,
    ChildrenRequired,
    InvalidChildren,
    InvalidRoot,
    TooManyNodes,
    TooDeep,
    MultipleFocusedTerminals,
    InvalidLayoutName,
};

const RawNode = struct {
    type: Type,
    direction: ?Node.Direction = null,
    ratio: ?f32 = null,
    children: ?[]const RawNode = null,
    command: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    title: ?[]const u8 = null,
    focus: bool = false,

    const Type = enum {
        window,
        tab,
        split,
        terminal,
    };
};

pub const max_layout_bytes = 256 * 1024;
pub const max_layout_nodes = 64;
pub const max_layout_depth = 32;

const ParseState = struct {
    nodes: usize = 0,

    fn record(self: *ParseState, depth: usize) ParseError!void {
        if (depth > max_layout_depth) return error.TooDeep;
        self.nodes += 1;
        if (self.nodes > max_layout_nodes) return error.TooManyNodes;
    }
};

/// Parse and validate a layout file. All returned memory uses `alloc`.
pub fn parse(
    alloc: Allocator,
    source: []const u8,
) !*Node {
    if (source.len > max_layout_bytes) return error.InvalidLayout;

    const raw = try std.json.parseFromSliceLeaky(
        RawNode,
        alloc,
        source,
        .{ .allocate = .alloc_if_needed, .ignore_unknown_fields = true },
    );

    var state: ParseState = .{};
    const root = try parseNode(alloc, &raw, 0, &state);
    try validateRoot(root);

    var focused: usize = 0;
    countFocused(root, &focused);
    if (focused > 1) return error.MultipleFocusedTerminals;

    return root;
}

fn parseNode(
    alloc: Allocator,
    raw: *const RawNode,
    depth: usize,
    state: *ParseState,
) !*Node {
    try state.record(depth);

    const node = try alloc.create(Node);
    switch (raw.type) {
        .window, .tab => {
            const raw_children = raw.children orelse return error.ChildrenRequired;
            if (raw_children.len == 0) return error.InvalidChildren;

            const children = try alloc.alloc(*Node, raw_children.len);
            for (raw_children, 0..) |*raw_child, i| {
                const child = try parseNode(alloc, raw_child, depth + 1, state);
                try validateContainerChild(raw.type, child);
                children[i] = child;
            }

            node.* = if (raw.type == .window)
                .{ .window = .{ .children = children } }
            else
                .{ .tab = .{ .children = children } };
        },

        .split => {
            const direction = raw.direction orelse return error.InvalidDirection;
            const ratio = raw.ratio orelse 0.5;
            if (!(ratio > 0 and ratio < 1)) return error.InvalidRatio;

            const raw_children = raw.children orelse return error.ChildrenRequired;
            if (raw_children.len != 2) return error.InvalidChildren;

            const first = try parseNode(alloc, &raw_children[0], depth + 1, state);
            try validateSplitChild(first);
            const second = try parseNode(alloc, &raw_children[1], depth + 1, state);
            try validateSplitChild(second);

            node.* = .{ .split = .{
                .direction = direction,
                .ratio = @floatCast(ratio),
                .first = first,
                .second = second,
            } };
        },

        .terminal => {
            if (raw.children != null and raw.children.?.len != 0) {
                return error.InvalidChildren;
            }

            node.* = .{ .terminal = .{
                .command = if (raw.command) |value| command: {
                    if (value.len == 0) break :command null;
                    break :command try alloc.dupeZ(u8, value);
                } else null,
                .working_directory = if (raw.working_directory orelse raw.directory) |value|
                    try alloc.dupeZ(u8, value)
                else
                    null,
                .title = if (raw.title) |value| try alloc.dupeZ(u8, value) else null,
                .focus = raw.focus,
            } };
        },
    }

    return node;
}

fn validateRoot(node: *const Node) ParseError!void {
    return switch (node.*) {
        .window, .tab, .split, .terminal => {},
    };
}

fn validateContainerChild(parent: RawNode.Type, node: *const Node) ParseError!void {
    return switch (parent) {
        .window => switch (node.*) {
            .tab => {},
            else => error.InvalidNodeType,
        },
        .tab => switch (node.*) {
            .window, .tab => error.InvalidNodeType,
            .split, .terminal => {},
        },
        else => unreachable,
    };
}

fn validateSplitChild(node: *const Node) ParseError!void {
    return switch (node.*) {
        .window, .tab => error.InvalidNodeType,
        .split, .terminal => {},
    };
}

fn countFocused(node: *const Node, count: *usize) void {
    switch (node.*) {
        .window, .tab => |container| for (container.children) |child| countFocused(child, count),
        .split => |split| {
            countFocused(split.first, count);
            countFocused(split.second, count);
        },
        .terminal => |terminal| {
            if (terminal.focus) count.* += 1;
        },
    }
}

/// A named collection of layout files. This is the Config field value.
pub const Registry = struct {
    const Self = @This();

    pub const Entry = struct {
        name: [:0]const u8,
        path: [:0]const u8,
        optional: bool = false,
        /// Cached file contents populated by `load`.
        source: ?[:0]const u8 = null,
    };

    entries: std.ArrayListUnmanaged(Entry) = .empty,
    loaded: bool = false,

    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        if (input.len == 0) {
            self.entries.clearRetainingCapacity();
            self.loaded = false;
            return;
        }

        const sep = std.mem.indexOfScalar(u8, input, '=') orelse return error.InvalidLayoutName;
        const name = std.mem.trim(u8, input[0..sep], &std.ascii.whitespace);
        const value = std.mem.trim(u8, input[sep + 1 ..], &std.ascii.whitespace);
        try validateName(name);
        if (value.len == 0) return error.ValueRequired;

        var path_value = value;
        var optional = false;
        if (path_value.len > 0 and path_value[0] == '?') {
            optional = true;
            path_value = path_value[1..];
        }
        if (path_value.len >= 2 and path_value[0] == '"' and path_value[path_value.len - 1] == '"') {
            path_value = path_value[1 .. path_value.len - 1];
        }
        if (path_value.len == 0) return error.ValueRequired;

        try self.register(alloc, name, path_value, optional);
    }

    /// Register or replace a named layout file.
    pub fn register(
        self: *Self,
        alloc: Allocator,
        name: []const u8,
        path: []const u8,
        optional: bool,
    ) !void {
        try validateName(name);
        if (path.len == 0) return error.ValueRequired;

        const path_copy = try alloc.dupeZ(u8, path);
        const name_copy = try alloc.dupeZ(u8, name);

        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.path = path_copy;
                entry.optional = optional;
                entry.source = null;
                self.loaded = false;
                return;
            }
        }

        try self.entries.append(alloc, .{
            .name = name_copy,
            .path = path_copy,
            .optional = optional,
        });
        self.loaded = false;
    }

    pub fn validateName(name: []const u8) ParseError!void {
        if (name.len == 0 or name.len > 64) return error.InvalidLayoutName;
        for (name) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') {
                return error.InvalidLayoutName;
            }
        }
    }

    pub fn expand(self: *Self, alloc: Allocator, base: []const u8) !void {
        for (self.entries.items) |*entry| {
            if (std.fs.path.isAbsolute(entry.path)) continue;

            if (std.mem.startsWith(u8, entry.path, "~/")) home: {
                const home = std.process.getEnvVarOwned(alloc, "HOME") catch break :home;
                defer alloc.free(home);
                const resolved = try std.fs.path.resolve(alloc, &.{ home, entry.path[2..] });
                entry.path = try alloc.dupeZ(u8, resolved);
                continue;
            }

            const resolved = try std.fs.path.resolve(alloc, &.{ base, entry.path });
            entry.path = try alloc.dupeZ(u8, resolved);
        }
        self.loaded = false;
    }

    /// Read and validate all layout files. Errors are reported as config
    /// diagnostics while valid layouts remain available.
    pub fn load(self: *Self, alloc: Allocator, diags: anytype) !void {
        self.loaded = true;
        for (self.entries.items) |*entry| {
            const path = entry.path;
            if (path.len == 0) continue;

            const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
                if (err == error.FileNotFound and entry.optional) continue;
                try addDiagnostic(alloc, diags, entry.name, "unable to open layout file {s}: {s}", .{ path, @errorName(err) });
                continue;
            };
            defer file.close();

            const source = file.readToEndAlloc(alloc, max_layout_bytes + 1) catch |err| {
                try addDiagnostic(alloc, diags, entry.name, "unable to read layout file {s}: {s}", .{ path, @errorName(err) });
                continue;
            };
            if (source.len > max_layout_bytes) {
                try addDiagnostic(alloc, diags, entry.name, "layout file is too large: {s}", .{path});
                continue;
            }

            var validation_arena = std.heap.ArenaAllocator.init(alloc);
            defer validation_arena.deinit();
            _ = parse(validation_arena.allocator(), source) catch |err| {
                try addDiagnostic(alloc, diags, entry.name, "invalid layout {s}: {s}", .{ path, @errorName(err) });
                entry.source = null;
                continue;
            };

            entry.source = try alloc.dupeZ(u8, source);
            log.info("loaded window layout name={s} path={s}", .{ entry.name, path });
        }
    }

    fn addDiagnostic(
        alloc: Allocator,
        diags: anytype,
        name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try diags.append(alloc, .{
            .key = try alloc.dupeZ(u8, name),
            .message = try std.fmt.allocPrintSentinel(alloc, fmt, args, 0),
        });
    }

    pub fn get(self: *const Self, name: []const u8, alloc: Allocator) !?*Node {
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const source = entry.source orelse return null;
            return try parse(alloc, source);
        }
        return null;
    }

    pub fn validateDefault(
        self: *const Self,
        alloc: Allocator,
        diags: anytype,
        name: []const u8,
    ) !void {
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (entry.source != null) return;
            return addDiagnostic(alloc, diags, name, "default window layout is unavailable", .{});
        }
        try addDiagnostic(alloc, diags, name, "unknown default window layout", .{});
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    pub fn iterator(self: *const Self) []const Entry {
        return self.entries.items;
    }

    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        var result: Self = .{ .loaded = self.loaded };
        try result.entries.ensureTotalCapacity(alloc, self.entries.items.len);
        for (self.entries.items) |entry| {
            result.entries.appendAssumeCapacity(.{
                .name = try alloc.dupeZ(u8, entry.name),
                .path = try alloc.dupeZ(u8, entry.path),
                .optional = entry.optional,
                .source = if (entry.source) |source| try alloc.dupeZ(u8, source) else null,
            });
        }
        return result;
    }

    pub fn equal(self: Self, other: Self) bool {
        if (self.entries.items.len != other.entries.items.len) return false;
        for (self.entries.items, other.entries.items) |a, b| {
            if (!std.mem.eql(u8, a.name, b.name)) return false;
            if (!std.mem.eql(u8, a.path, b.path)) return false;
            if (a.optional != b.optional) return false;
            if ((a.source == null) != (b.source == null)) return false;
            if (a.source) |source| {
                if (!std.mem.eql(u8, source, b.source.?)) return false;
            }
        }
        return true;
    }

    pub fn formatEntry(self: Self, formatter: anytype) !void {
        if (self.entries.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        var buf: [std.fs.max_path_bytes + 128]u8 = undefined;
        for (self.entries.items) |entry| {
            const value = std.fmt.bufPrint(&buf, "{s}={s}{s}", .{
                entry.name,
                if (entry.optional) "?" else "",
                entry.path,
            }) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutOfMemory,
            };
            try formatter.formatEntry([]const u8, value);
        }
    }
};

test "WindowLayout: parse split tree" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(arena.allocator(),
        \\{
        \\  "type": "window",
        \\  "children": [{
        \\    "type": "tab",
        \\    "children": [{
        \\      "type": "split",
        \\      "direction": "horizontal",
        \\      "ratio": 0.65,
        \\      "children": [
        \\        {"type": "terminal", "command": "nvim", "focus": true},
        \\        {"type": "terminal", "title": "shell"}
        \\      ]
        \\    }]
        \\  }]
        \\}
    );

    try testing.expectEqual(@as(usize, 2), root.countTerminals());
    try testing.expectEqualStrings("nvim", root.firstFocusedTerminal().?.command.?);
}

test "WindowLayout: reject invalid split" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidChildren, parse(arena.allocator(),
        \\{"type":"split","direction":"horizontal","children":[{"type":"terminal"}]}
    ));
    try testing.expectError(error.InvalidRatio, parse(arena.allocator(),
        \\{"type":"split","direction":"horizontal","ratio":1,
        \\"children":[{"type":"terminal"},{"type":"terminal"}]}
    ));
}

test "WindowLayout: registry parse and get" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry: Registry = .{};
    try registry.parseCLI(alloc, "dev=/tmp/dev.json");
    try registry.parseCLI(alloc, "logs=/tmp/logs.json");
    try testing.expectEqual(@as(usize, 2), registry.count());

    // Replace preserves one entry per name.
    try registry.parseCLI(alloc, "dev=/tmp/dev2.json");
    try testing.expectEqual(@as(usize, 2), registry.count());

    try testing.expectError(error.InvalidLayoutName, registry.parseCLI(alloc, "bad name=/tmp/a.json"));
}

test "WindowLayout: registry loads and parses a file" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dev.json",
        .data =
        \\{
        \\  "type": "split",
        \\  "direction": "vertical",
        \\  "ratio": 0.4,
        \\  "children": [
        \\    {"type": "terminal", "title": "top"},
        \\    {"type": "terminal", "title": "bottom"}
        \\  ]
        \\}
        ,
    });

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "dev.json" });
    defer testing.allocator.free(path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry: Registry = .{};
    try registry.parseCLI(alloc, try std.fmt.allocPrint(alloc, "dev={s}", .{path}));

    var diagnostic_count: usize = 0;
    const TestDiagnostics = struct {
        count: *usize,

        pub fn append(self: @This(), _: Allocator, _: anytype) !void {
            self.count.* += 1;
        }
    };
    try registry.load(alloc, TestDiagnostics{ .count = &diagnostic_count });
    try testing.expectEqual(@as(usize, 0), diagnostic_count);

    const plan = (try registry.get("dev", alloc)).?;
    try testing.expectEqual(@as(usize, 2), plan.countTerminals());
}
