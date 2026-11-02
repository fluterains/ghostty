const std = @import("std");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig").Config;

pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,

    // Accepted here so the action parser can reach Config.load below. The
    // values are consumed from the same process arguments again by Config.
    layout: ?[:0]const u8 = null,
    @"layout-file": ?Config.Path = null,
    @"layout-name": ?[:0]const u8 = null,
    @"window-layout": ?[:0]const u8 = null,
    @"window-layout-default": ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |*arena| arena.deinit();
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-layouts` command lists every named window layout available to the
/// current configuration.
///
/// Layouts are printed one per line as `name=path`. Command-line options such
/// as `--layout-file` participate in configuration loading, so temporary
/// layouts can be inspected before launching Ghostty.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var config = try Config.load(alloc);
    defer config.deinit();

    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout_writer.interface;
    for (config.@"window-layout".iterator()) |entry| {
        try writer.print("{s}={s}\n", .{ entry.name, entry.path });
    }
    try writer.flush();

    return 0;
}
