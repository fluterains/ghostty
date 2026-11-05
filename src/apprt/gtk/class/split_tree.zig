const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const WindowLayout = @import("../../../config/window_layout.zig");
const apprt = @import("../../../apprt.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const Surface = @import("surface.zig").Surface;
const SurfaceScrolledWindow = @import("surface_scrolled_window.zig").SurfaceScrolledWindow;

const log = std.log.scoped(.gtk_ghostty_split_tree);

pub const SplitTree = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTree",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const @"has-surfaces" = struct {
            pub const name = "has-surfaces";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getHasSurfaces,
                        },
                    ),
                },
            );
        };

        pub const @"is-zoomed" = struct {
            pub const name = "is-zoomed";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getIsZoomed,
                        },
                    ),
                },
            );
        };

        pub const tree = struct {
            pub const name = "tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = .{
                        .getter = getTreeValue,
                        .setter = setTreeValue,
                    },
                },
            );
        };

        pub const @"is-split" = struct {
            pub const name = "is-split";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getIsSplit,
                        },
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tree property has changed, with access
        /// to the previous and new values.
        pub const changed = struct {
            pub const name = "changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ ?*const Surface.Tree, ?*const Surface.Tree },
                void,
            );
        };
    };

    const Private = struct {
        const focus_history_max = 32;

        /// The tree datastructure containing all of our surface views.
        tree: ?*Surface.Tree,

        // Template bindings
        tree_bin: *adw.Bin,

        /// Last focused surface in the tree. We need this to handle various
        /// tree change states.
        last_focused: WeakRef(Surface) = .empty,

        /// Recently focused surfaces, oldest first. These are strong
        /// references bounded by focus_history_max.
        focus_history: std.ArrayListUnmanaged(*Surface) = .empty,

        /// The source that we use to rebuild the tree. This is also
        /// used to debounce updates.
        rebuild_source: ?c_uint = null,

        /// True while installing a tree that was already applied to the
        /// existing widget hierarchy. The tree property must still notify
        /// bindings, but propTree must not schedule another rebuild.
        skip_rebuild: bool = false,

        /// The source that we use to restore focus. With enough nested
        /// splits, some surfaces might initially be allocated a width or
        /// height of 0 which causes them to get unmapped and lose focus.
        /// We can reliably restore focus to the last focused surface only
        /// once it is mapped again.
        restore_focus_source: ?c_uint = null,

        /// Used to store state about a pending surface close for the
        /// close dialog.
        pending_close: ?Surface.Tree.Node.Handle,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Initialize our actions
        self.initActionMap();

        // Initialize some basic state
        const priv = self.private();
        priv.pending_close = null;
    }

    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            // All of these will eventually take a target surface parameter.
            // For now all our targets originate from the focused surface.
            .init("new-split", actionNewSplit, s_variant_type),
            .init("equalize", actionEqualize, null),
            .init("zoom", actionZoom, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "split-tree", &actions);
    }

    fn recordFocus(self: *Self, surface: *Surface) void {
        const priv = self.private();
        priv.last_focused.set(surface);

        var i: usize = 0;
        while (i < priv.focus_history.items.len) {
            const existing = priv.focus_history.items[i];
            if (existing != surface) {
                i += 1;
                continue;
            }

            _ = priv.focus_history.orderedRemove(i);
            existing.unref();
        }

        _ = surface.ref();
        priv.focus_history.append(
            Application.default().allocator(),
            surface,
        ) catch |err| {
            surface.unref();
            log.warn("unable to record split focus history: {}", .{err});
            return;
        };

        while (priv.focus_history.items.len > Private.focus_history_max) {
            priv.focus_history.items[0].unref();
            _ = priv.focus_history.orderedRemove(0);
        }
    }

    fn forgetFocus(self: *Self, surface: *Surface) void {
        const history = &self.private().focus_history;
        var i: usize = 0;
        while (i < history.items.len) {
            const existing = history.items[i];
            if (existing != surface) {
                i += 1;
                continue;
            }

            _ = history.orderedRemove(i);
            existing.unref();
        }
    }

    fn treeContainsSurface(tree: *const Surface.Tree, surface: *Surface) bool {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return true;
        }
        return false;
    }

    /// Drop focus references to surfaces that are no longer present after a
    /// tree replacement. Without this, the bounded history can keep closed
    /// terminals alive until enough new panes happen to evict them.
    fn pruneFocusState(self: *Self) void {
        const priv = self.private();
        const tree: ?*const Surface.Tree = priv.tree;

        var i: usize = 0;
        while (i < priv.focus_history.items.len) {
            const surface = priv.focus_history.items[i];
            if (tree != null and treeContainsSurface(tree.?, surface)) {
                i += 1;
                continue;
            }

            _ = priv.focus_history.orderedRemove(i);
            surface.unref();
        }

        if (priv.last_focused.get()) |surface| {
            defer surface.unref();
            if (tree == null or !treeContainsSurface(tree.?, surface)) {
                priv.last_focused.set(null);
            }
        }
    }

    fn recentFocus(self: *Self, buffer: *[Private.focus_history_max]*Surface) usize {
        const items = self.private().focus_history.items;
        var count: usize = 0;
        var i = items.len;
        while (i > 0 and count < buffer.len) {
            i -= 1;
            buffer[count] = items[i];
            count += 1;
        }
        return count;
    }

    /// Create a new split in the given direction from the currently
    /// active surface.
    ///
    /// If the tree is empty this will create a new tree with a new surface
    /// and ignore the direction.
    ///
    /// The parent will be used as the parent of the surface regardless of
    /// if that parent is in this split tree or not. This allows inheriting
    /// surface properties from anywhere.
    pub fn newSplit(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        parent_: ?*Surface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) Allocator.Error!void {
        const alloc = Application.default().allocator();

        // Create our new surface.
        const surface: *Surface = .new(.{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
        defer surface.unref();
        _ = surface.refSink();

        // Inherit properly if we were asked to.
        if (parent_) |p| {
            if (p.core()) |core| {
                surface.setParent(core, .split);
            }
        }

        // Bind is-split property for new surface
        _ = self.as(gobject.Object).bindProperty(
            "is-split",
            surface.as(gobject.Object),
            "is-split",
            .{ .sync_create = true },
        );

        // Create our tree
        var single_tree = try Surface.Tree.init(alloc, surface);
        defer single_tree.deinit();

        // If we have no tree yet, then this becomes our tree and we're done.
        const old_tree = self.getTree() orelse {
            self.setTree(&single_tree);
            self.recordFocus(surface);
            return;
        };

        // The handle we create the split relative to. Today this is the active
        // surface but this might be the handle of the given parent if we want.
        const handle = self.getActiveSurfaceHandle() orelse .root;
        const active_surface = old_tree.nodes[handle.idx()].leaf;

        // Create our split!
        var new_tree = try old_tree.split(
            alloc,
            handle,
            direction,
            0.5, // Always split equally for new splits
            &single_tree,
        );
        defer new_tree.deinit();
        log.debug(
            "new split at={} direction={} old_tree={f} new_tree={f}",
            .{ handle, direction, old_tree, &new_tree },
        );

        // Replace our tree and record focus only after all fallible work has
        // succeeded. This keeps the previous focus state intact on failure.
        self.recordFocus(surface);

        // Insert the new split directly into the existing GTK hierarchy when
        // possible. This only detaches and reparents the target surface and
        // leaves every other split untouched.
        if (ext.getAncestor(
            SurfaceScrolledWindow,
            active_surface.as(gtk.Widget),
        )) |old_window| {
            if (replaceLeafWithSplit(
                &new_tree,
                handle,
                direction,
                old_window,
                surface,
            )) {
                self.setTreeIncremental(&new_tree);
                self.applyZoom();
                surface.grabFocus();
                return;
            }
        }

        // Fall back to the debounced full rebuild if the existing widget
        // cannot be found or replaced safely.
        self.setTree(&new_tree);
    }

    pub const LayoutError = Allocator.Error || error{
        InvalidTabLayout,
        InvalidLayoutNode,
    };

    /// Build a complete split tree from a configured layout and install it
    /// atomically. The layout must resolve to exactly one tab.
    pub fn newLayout(
        self: *Self,
        layout: *const WindowLayout.Node,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) LayoutError!void {
        const tab_layout = switch (layout.*) {
            .window => |container| window: {
                if (container.children.len != 1) return error.InvalidTabLayout;
                const child = container.children[0];
                break :window switch (child.*) {
                    .tab => child,
                    else => return error.InvalidTabLayout,
                };
            },
            .tab => layout,
            .split, .terminal => layout,
        };

        const alloc = Application.default().allocator();
        var scratch_arena = std.heap.ArenaAllocator.init(alloc);
        defer scratch_arena.deinit();

        var built = try self.buildLayoutNode(
            scratch_arena.allocator(),
            tab_layout,
            overrides,
        );
        defer built.tree.deinit();

        // Every new Surface starts focused so a normal, single-surface split
        // is immediately usable. In a bulk-loaded layout, however, GTK will
        // only realize one of them as focused; the others would retain the
        // default flag and continue blinking their cursors. Set the complete
        // initial state before installing the tree.
        const focus = built.focus orelse built.first orelse return error.InvalidLayoutNode;
        var layout_it = built.tree.iterator();
        while (layout_it.next()) |entry| {
            entry.view.setInitialFocused(entry.view == focus);
        }

        self.setTree(&built.tree);
        self.recordFocus(focus);
        focus.grabFocus();
    }

    const BuiltLayout = struct {
        tree: Surface.Tree,
        focus: ?*Surface = null,
        first: ?*Surface = null,
    };

    fn buildLayoutNode(
        self: *Self,
        scratch_alloc: Allocator,
        node: *const WindowLayout.Node,
        overrides: anytype,
    ) LayoutError!BuiltLayout {
        return switch (node.*) {
            .terminal => |terminal| terminal: {
                var command: ?configpkg.Command = null;
                if (terminal.command) |raw| {
                    var parsed: configpkg.Command = undefined;
                    parsed.parseCLI(scratch_alloc, raw) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ValueRequired => return error.InvalidLayoutNode,
                    };
                    command = parsed;
                }

                const surface: *Surface = .new(.{
                    .command = command orelse overrides.command,
                    .working_directory = terminal.working_directory orelse overrides.working_directory,
                    .title = terminal.title orelse overrides.title,
                });
                errdefer surface.unref();
                _ = surface.refSink();

                _ = self.as(gobject.Object).bindProperty(
                    "is-split",
                    surface.as(gobject.Object),
                    "is-split",
                    .{ .sync_create = true },
                );

                const alloc = Application.default().allocator();
                var tree = try Surface.Tree.init(alloc, surface);
                errdefer tree.deinit();
                surface.unref();

                break :terminal .{
                    .tree = tree,
                    .focus = if (terminal.focus) surface else null,
                    .first = surface,
                };
            },

            .split => |split| split: {
                var first = try self.buildLayoutNode(scratch_alloc, split.first, overrides);
                errdefer first.tree.deinit();
                var second = try self.buildLayoutNode(scratch_alloc, split.second, overrides);
                defer second.tree.deinit();

                const alloc = Application.default().allocator();
                var tree = try Surface.Tree.join(
                    &first.tree,
                    &second.tree,
                    alloc,
                    switch (split.direction) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    split.ratio,
                );
                errdefer tree.deinit();
                first.tree.deinit();

                break :split .{
                    .tree = tree,
                    .focus = first.focus orelse second.focus,
                    .first = first.first orelse second.first,
                };
            },

            .tab => |container| container: {
                if (container.children.len != 1) return error.InvalidTabLayout;
                break :container self.buildLayoutNode(scratch_alloc, container.children[0], overrides);
            },

            .window => error.InvalidTabLayout,
        };
    }

    pub fn resize(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        amount: u16,
    ) Allocator.Error!bool {
        // Avoid useless work
        if (amount == 0) return false;

        const old_tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;

        // Get all our dimensions we're going to need to turn our
        // amount into a percentage.
        const priv = self.private();
        const width = priv.tree_bin.as(gtk.Widget).getWidth();
        const height = priv.tree_bin.as(gtk.Widget).getHeight();
        if (width == 0 or height == 0) return false;
        const width_f64: f64 = @floatFromInt(width);
        const height_f64: f64 = @floatFromInt(height);
        const amount_f64: f64 = @floatFromInt(amount);

        // Get our ratio and use positive/neg for directions.
        const ratio: f64 = switch (direction) {
            .right => amount_f64 / width_f64,
            .left => -(amount_f64 / width_f64),
            .down => amount_f64 / height_f64,
            .up => -(amount_f64 / height_f64),
        };

        const layout: Surface.Tree.Split.Layout = switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };

        var new_tree = try old_tree.resize(
            Application.default().allocator(),
            active,
            layout,
            @floatCast(ratio),
        );
        defer new_tree.deinit();

        const changed = changedSplit(old_tree, &new_tree) orelse return false;
        const changed_ratio = new_tree.nodes[changed.idx()].split.ratio;
        old_tree.resizeInPlace(changed, changed_ratio);

        if (self.findSplitWidget(changed)) |widget| {
            widget.restorePosition();
        } else {
            // The model was updated in place, so restore it from the clone if
            // the corresponding widget cannot be found.
            self.setTree(&new_tree);
        }
        return true;
    }

    /// Move focus from the currently focused surface to the given
    /// direction. Returns true if focus switched to a new surface.
    pub fn goto(self: *Self, to: Surface.Tree.Goto) bool {
        const tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;
        const app = Application.default();
        const config_obj = app.getConfig();
        defer config_obj.unref();
        const config = config_obj.get();
        var recent_buffer: [Private.focus_history_max]*Surface = undefined;
        const recent_count = self.recentFocus(&recent_buffer);
        const recent: []const *const Surface = recent_buffer[0..recent_count];
        const target = if (tree.gotoWithHistoryWrap(
            Application.default().allocator(),
            active,
            to,
            recent,
            config.@"split-focus-wrap",
        )) |handle_|
            handle_ orelse return false
        else |err| switch (err) {
            // Nothing we can do in this scenario. This is highly unlikely
            // since split trees don't use that much memory. The application
            // is probably about to crash in other ways.
            error.OutOfMemory => return false,
        };

        // If we aren't changing targets then we did nothing.
        if (active == target) return false;

        // Get the surface at the target location and grab focus.
        const surface = tree.nodes[target.idx()].leaf;
        surface.grabFocus();

        // We also need to set our focus history to this because if we
        // trigger a tree change like below, the grab focus above never
        // actually triggers in time to record this.
        self.recordFocus(surface);

        if (tree.zoomed != null) {
            if (!config.@"split-preserve-zoom".navigation) {
                tree.zoomed = null;
            } else {
                tree.zoom(target);
            }

            // Keep the full widget tree attached and only switch which
            // branches are visible. Rebuilding the tree here detaches and
            // reattaches every surface, which causes visible flashing.
            self.applyZoom();
            self.as(gobject.Object).notifyByPspec(properties.@"is-zoomed".impl.param_spec);
        }

        return true;
    }

    fn disconnectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    fn connectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = Surface.signals.@"close-request".connect(
                surface,
                *Self,
                surfaceCloseRequest,
                self,
                .{},
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceFocused,
                self,
                .{ .detail = "focused" },
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceMapped,
                self,
                .{ .detail = "mapped" },
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns true if this split tree needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getTree() orelse return false;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.core()) |core| {
                if (core.needsConfirmQuit()) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tree = self.getTree() orelse return null;
        const handle = self.getActiveSurfaceHandle() orelse return null;
        return tree.nodes[handle.idx()].leaf;
    }

    fn getActiveSurfaceHandle(self: *Self) ?Surface.Tree.Node.Handle {
        const tree = self.getTree() orelse return null;
        var it = tree.iterator();
        var first_focused: ?Surface.Tree.Node.Handle = null;
        var focused_count: usize = 0;
        while (it.next()) |entry| {
            if (!entry.view.getFocused()) continue;
            if (first_focused == null) first_focused = entry.handle;
            focused_count += 1;
        }

        if (focused_count == 1) return first_focused;

        // During a GTK rebuild focus events can transiently leave multiple
        // surfaces marked focused. Prefer our explicit last-focused surface
        // instead of whichever node happens to appear first in the tree.
        if (self.private().last_focused.get()) |v| {
            defer v.unref();

            if (v.getFocused()) {
                it = tree.iterator();
                while (it.next()) |entry| {
                    if (entry.view == v) return entry.handle;
                }
            }
        }

        if (focused_count > 0) return first_focused;

        // If none are currently focused, the most previously focused
        // surface (if it exists) is our active surface. This lets things
        // like apprt actions and bell ringing continue to work in the
        // background.
        if (self.private().last_focused.get()) |v| {
            defer v.unref();

            // We need to find the handle of the last focused surface.
            it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == v) return entry.handle;
            }
        }

        return null;
    }

    /// Returns the last focused surface in the tree.
    pub fn getLastFocusedSurface(self: *Self) ?*Surface {
        const surface = self.private().last_focused.get() orelse return null;
        // We unref because get() refs the surface. We don't use the weakref
        // in a multi-threaded context so this is safe.
        surface.unref();
        return surface;
    }

    pub fn getHasSurfaces(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return !tree.isEmpty();
    }

    pub fn getIsZoomed(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return tree.zoomed != null;
    }

    /// Get the tree data model that we're showing in this widget. This
    /// does not clone the tree.
    pub fn getTree(self: *Self) ?*Surface.Tree {
        return self.private().tree;
    }

    /// Set the tree data model that we're showing in this widget. This
    /// will clone the given tree.
    pub fn setTree(self: *Self, tree_: ?*const Surface.Tree) void {
        self.setTreeImpl(tree_, true);
    }

    /// Install a tree whose widget hierarchy has already been updated in
    /// place. This still emits the tree notification for bindings and handlers,
    /// but intentionally skips the deferred full rebuild.
    fn setTreeIncremental(self: *Self, tree_: ?*const Surface.Tree) void {
        self.setTreeImpl(tree_, false);
    }

    fn setTreeImpl(self: *Self, tree_: ?*const Surface.Tree, rebuild: bool) void {
        const priv = self.private();

        // We always normalize our tree parameter so that empty trees
        // become null so that we don't have to deal with callers being
        // confused about that.
        const tree: ?*const Surface.Tree = tree: {
            const tree = tree_ orelse break :tree null;
            if (tree.isEmpty()) break :tree null;
            break :tree tree;
        };

        // Emit the signal so that handlers can witness both the before and
        // after values of the tree.
        signals.changed.impl.emit(
            self,
            null,
            .{ priv.tree, tree },
            null,
        );

        if (priv.tree) |old_tree| {
            self.disconnectSurfaceHandlers();
            ext.boxedFree(Surface.Tree, old_tree);
            priv.tree = null;
        }

        if (tree) |new_tree| {
            assert(priv.tree == null);
            assert(!new_tree.isEmpty());
            priv.tree = ext.boxedCopy(Surface.Tree, new_tree);
            self.connectSurfaceHandlers();
        }

        self.pruneFocusState();

        const object = self.as(gobject.Object);
        if (rebuild) {
            object.notifyByPspec(properties.tree.impl.param_spec);
        } else {
            priv.skip_rebuild = true;
            defer priv.skip_rebuild = false;
            object.notifyByPspec(properties.tree.impl.param_spec);
            object.notifyByPspec(properties.@"is-split".impl.param_spec);
            object.notifyByPspec(properties.@"active-surface".impl.param_spec);
        }
    }

    fn getTreeValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().tree,
        );
    }

    fn setTreeValue(self: *Self, value: *const gobject.Value) void {
        self.setTree(gobject.ext.Value.get(
            value,
            ?*Surface.Tree,
        ));
    }

    pub fn getIsSplit(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) return false;

        const root_handle: Surface.Tree.Node.Handle = .root;
        const root = tree.nodes[root_handle.idx()];
        return switch (root) {
            .leaf => false,
            .split => true,
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.last_focused.set(null);
        for (priv.focus_history.items) |surface| surface.unref();
        priv.focus_history.deinit(Application.default().allocator());
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }
        if (priv.restore_focus_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove restore focus source", .{});
            }
            priv.restore_focus_source = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tree) |tree| {
            ext.boxedFree(Surface.Tree, tree);
            priv.tree = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    pub fn actionNewSplit(
        _: *gio.SimpleAction,
        args_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const args = args_ orelse {
            log.warn("split-tree.new-split called without a parameter", .{});
            return;
        };

        var dir: ?[*:0]const u8 = null;
        args.get("&s", &dir);

        const direction = std.meta.stringToEnum(
            Surface.Tree.Split.Direction,
            std.mem.span(dir) orelse return,
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid split direction for split-tree.new-split: {s}", .{dir.?});
            return;
        };

        self.newSplit(
            direction,
            self.getActiveSurface(),
            .none,
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }

    pub fn actionEqualize(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;

        const old_tree = self.getTree() orelse return;
        var new_tree = old_tree.equalize(Application.default().allocator()) catch |err| {
            log.warn("unable to equalize tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();

        const tree = self.getTree() orelse return;
        var all_found = true;
        for (old_tree.nodes, new_tree.nodes, 0..) |old_node, new_node, handle| {
            switch (old_node) {
                .leaf => {},
                .split => |old_split| {
                    const new_split = new_node.split;
                    if (old_split.ratio == new_split.ratio) continue;
                    tree.resizeInPlace(
                        @enumFromInt(handle),
                        new_split.ratio,
                    );
                    if (self.findSplitWidget(@enumFromInt(handle))) |widget| {
                        widget.restorePosition();
                    } else {
                        all_found = false;
                        break;
                    }
                },
            }
        }

        if (!all_found) self.setTree(&new_tree);
    }

    pub fn actionZoom(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tree = self.getTree() orelse return;
        if (tree.zoomed != null) {
            tree.zoomed = null;
        } else {
            const active = self.getActiveSurfaceHandle() orelse return;
            if (tree.zoomed == active) return;
            tree.zoom(active);
        }

        // The full split tree remains attached. Zoom only changes which
        // branches are visible, so avoid a full widget-tree rebuild.
        self.applyZoom();
        self.as(gobject.Object).notifyByPspec(properties.@"is-zoomed".impl.param_spec);
    }

    fn surfaceCloseRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const core = surface.core() orelse return;

        // Reset our pending close state
        const priv = self.private();
        priv.pending_close = null;

        // Find the surface in the tree to verify this is valid and
        // set our pending close handle.
        priv.pending_close = handle: {
            const tree = self.getTree() orelse return;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == surface) {
                    break :handle entry.handle;
                }
            }

            return;
        };

        // If we don't need to confirm then just close immediately.
        if (!core.needsConfirmQuit()) {
            closeConfirmationClose(
                null,
                self,
            );
            return;
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.surface);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Self,
            closeConfirmationClose,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }

    fn closeConfirmationClose(
        _: ?*CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        // Get the handle we're closing
        const priv = self.private();
        const handle = priv.pending_close orelse return;
        priv.pending_close = null;

        // Focus the sibling subtree that replaces the closed split. If the
        // sibling is itself a subtree, choose the leaf nearest the shared
        // boundary: leftmost for a closed left child and rightmost for a
        // closed right child.
        const old_tree = self.getTree() orelse return;
        self.forgetFocus(old_tree.nodes[handle.idx()].leaf);
        const next_focus = siblingFocusTarget(old_tree, handle);

        // Remove it from the tree.
        var new_tree = old_tree.remove(
            Application.default().allocator(),
            handle,
        ) catch |err| {
            log.warn("unable to remove surface from tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();

        // Remove the leaf from the existing widget hierarchy when possible.
        // The sibling subtree takes the old split's place, so unrelated
        // branches never need to be detached or reparented.
        if (!new_tree.isEmpty() and self.removeLeafFromSplit(old_tree, handle)) {
            self.setTreeIncremental(&new_tree);
            self.applyZoom();
            if (next_focus) |v| {
                self.recordFocus(v);
                v.grabFocus();
            }
            return;
        }

        // Fall back to the full rebuild for the final pane or if the widget
        // hierarchy cannot be updated incrementally.
        self.setTree(&new_tree);

        // Grab focus. We have to set this on the "last focused" because our
        // focus will be set when the tree is redrawn.
        if (next_focus) |v| self.recordFocus(v);
    }

    fn propSurfaceFocused(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We never CLEAR our last_focused because the property is specifically
        // the last focused surface. We let the weakref clear itself when
        // the surface is destroyed.
        if (!surface.getFocused()) return;
        self.recordFocus(surface);

        // Our active surface probably changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn propSurfaceMapped(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        if (!surface.getMapped()) return;

        // We could add the idle callback only if this is actually the last
        // focused surface, but all surfaces usually get mapped at once, so
        // the idle callback runs only once anyway.
        const priv = self.private();
        if (priv.restore_focus_source == null) priv.restore_focus_source = glib.idleAdd(
            onRestoreFocus,
            self,
        );
    }

    fn nodeContains(
        tree: *const Surface.Tree,
        ancestor: Surface.Tree.Node.Handle,
        target: Surface.Tree.Node.Handle,
    ) bool {
        if (ancestor == target) return true;
        return switch (tree.nodes[ancestor.idx()]) {
            .leaf => false,
            .split => |split| nodeContains(tree, split.left, target) or
                nodeContains(tree, split.right, target),
        };
    }

    fn findParentSplit(
        tree: *const Surface.Tree,
        target: Surface.Tree.Node.Handle,
        current: Surface.Tree.Node.Handle,
    ) ?Surface.Tree.Node.Handle {
        return switch (tree.nodes[current.idx()]) {
            .leaf => null,
            .split => |split| {
                if (split.left == target or split.right == target) return current;
                if (nodeContains(tree, split.left, target)) {
                    return findParentSplit(tree, target, split.left);
                }
                if (nodeContains(tree, split.right, target)) {
                    return findParentSplit(tree, target, split.right);
                }
                return null;
            },
        };
    }

    fn siblingFocusTarget(
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
    ) ?*Surface {
        const parent_handle = findParentSplit(tree, handle, .root) orelse return null;
        const parent_split = &tree.nodes[parent_handle.idx()].split;
        const target_is_left = parent_split.left == handle;
        const sibling_handle = if (target_is_left)
            parent_split.right
        else
            parent_split.left;

        const target_handle = switch (tree.nodes[sibling_handle.idx()]) {
            .leaf => sibling_handle,
            .split => if (target_is_left)
                tree.deepest(.left, sibling_handle)
            else
                tree.deepest(.right, sibling_handle),
        };
        return tree.nodes[target_handle.idx()].leaf;
    }

    fn changedSplit(
        old_tree: *const Surface.Tree,
        new_tree: *const Surface.Tree,
    ) ?Surface.Tree.Node.Handle {
        for (old_tree.nodes, new_tree.nodes, 0..) |old_node, new_node, handle| {
            switch (old_node) {
                .leaf => {},
                .split => |old_split| {
                    switch (new_node) {
                        .leaf => return null,
                        .split => |new_split| {
                            if (old_split.ratio != new_split.ratio) {
                                return @enumFromInt(handle);
                            }
                        },
                    }
                },
            }
        }
        return null;
    }

    fn findSplitWidgetIn(
        tree: *const Surface.Tree,
        target: Surface.Tree.Node.Handle,
        current: Surface.Tree.Node.Handle,
        widget: *gtk.Widget,
    ) ?*SplitTreeSplit {
        if (current == target) {
            return gobject.ext.cast(SplitTreeSplit, widget);
        }

        const split = switch (tree.nodes[current.idx()]) {
            .leaf => return null,
            .split => |split| split,
        };
        const split_widget = gobject.ext.cast(SplitTreeSplit, widget) orelse return null;
        const start = split_widget.getStartChild() orelse return null;
        const end = split_widget.getEndChild() orelse return null;
        if (nodeContains(tree, split.left, target)) {
            return findSplitWidgetIn(tree, target, split.left, start);
        }
        if (nodeContains(tree, split.right, target)) {
            return findSplitWidgetIn(tree, target, split.right, end);
        }
        return null;
    }

    fn findSplitWidget(
        self: *Self,
        target: Surface.Tree.Node.Handle,
    ) ?*SplitTreeSplit {
        const tree = self.getTree() orelse return null;
        const root = self.private().tree_bin.getChild() orelse return null;
        return findSplitWidgetIn(tree, target, .root, root);
    }

    fn applyZoomNode(
        self: *Self,
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
        widget: *gtk.Widget,
        zoomed: ?Surface.Tree.Node.Handle,
    ) void {
        switch (tree.nodes[handle.idx()]) {
            .leaf => {},
            .split => |split| {
                const split_widget = gobject.ext.cast(SplitTreeSplit, widget) orelse {
                    log.warn("split widget not found while applying zoom", .{});
                    return;
                };
                // Structural updates such as removing a leaf can renumber
                // handles in the immutable model. Keep the surviving widget
                // mapped to its current handle without rebuilding it.
                split_widget.setHandle(handle);
                const start = split_widget.getStartChild() orelse return;
                const end = split_widget.getEndChild() orelse return;
                const start_visible = if (zoomed) |target|
                    nodeContains(tree, split.left, target)
                else
                    true;
                const end_visible = if (zoomed) |target|
                    nodeContains(tree, split.right, target)
                else
                    true;

                start.setVisible(@intFromBool(start_visible));
                end.setVisible(@intFromBool(end_visible));
                self.applyZoomNode(tree, split.left, start, zoomed);
                self.applyZoomNode(tree, split.right, end, zoomed);

                // Hiding a paned child changes its allocated position. Restore
                // all split positions once the full tree is visible again.
                if (zoomed == null) split_widget.restorePosition();
            },
        }
    }

    /// Apply the model's zoom state to the already-built widget tree. The
    /// active branch remains attached and visible while its sibling branches
    /// are hidden, avoiding the detach/attach cycle of a full rebuild.
    fn applyZoom(self: *Self) void {
        const tree = self.getTree() orelse return;
        const root = self.private().tree_bin.getChild() orelse return;

        var zoomed = tree.zoomed;
        if (zoomed) |target| {
            if (!nodeContains(tree, .root, target)) {
                tree.zoomed = null;
                zoomed = null;
            }
        }

        // The root is never hidden by zoom, but an incremental topology update
        // can promote a previously hidden sibling to root. Ensure it is shown.
        root.setVisible(1);
        self.applyZoomNode(tree, .root, root, zoomed);
    }

    fn propTree(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();

        // No matter what we notify
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"has-surfaces".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"is-zoomed".impl.param_spec);

        // The widget hierarchy was updated in place by the caller. Only the
        // observable model properties need to be refreshed.
        if (priv.skip_rebuild) return;

        // If we were planning a rebuild or focus restore, always remove
        // that so we can start from a clean slate.
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }
        if (priv.restore_focus_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove restore focus source", .{});
            }
            priv.restore_focus_source = null;
        }

        // If we transitioned to an empty tree, clear immediately instead of
        // waiting for an idle callback. Delaying teardown can keep the last
        // surface alive during shutdown if the main loop exits first.
        if (priv.tree == null) {
            priv.tree_bin.setChild(null);
            return;
        }

        // Build on an idle callback so rapid tree changes are debounced.
        // We keep the existing tree attached until the rebuild runs,
        // which avoids transient empty frames.
        assert(priv.rebuild_source == null);
        priv.rebuild_source = glib.idleAdd(
            onRebuild,
            self,
        );
    }

    fn onRebuild(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always mark our rebuild source as null since we're done.
        const priv = self.private();
        priv.rebuild_source = null;

        // Rebuild our tree
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) {
            priv.tree_bin.setChild(null);
        } else {
            // Always build the complete hierarchy. Zoom is applied by hiding
            // sibling branches, so exiting zoom never requires rebuilding and
            // reparenting every surface.
            const built = self.buildTree(tree, .root);
            defer built.deinit();
            priv.tree_bin.setChild(built.widget);
            self.applyZoom();
        }

        // Replacing our tree widget hierarchy can reset focus state.
        // If we have a last-focused surface, restore focus to it.
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            v.grabFocus();
        }

        // Our split status may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"is-split".impl.param_spec);

        // Our active surface may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);

        return 0;
    }

    fn onRestoreFocus(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        const priv = self.private();
        priv.restore_focus_source = null;

        // A surface can lose focus when the tree is rebuilt because GTK may
        // temporarily unmap it while reparenting widgets. Only grab focus once
        // the last focused surface is mapped again.
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            if (v.getMapped()) {
                v.grabFocus();
            }
        }

        return 0;
    }

    const ParentSlot = union(enum) {
        bin: *adw.Bin,
        paned_start: *gtk.Paned,
        paned_end: *gtk.Paned,
    };

    fn parentSlotOf(widget: *gtk.Widget) ?ParentSlot {
        const parent = widget.getParent() orelse return null;

        if (gobject.ext.cast(gtk.Paned, parent)) |paned| {
            if (paned.getStartChild()) |child| {
                if (child == widget) {
                    return .{ .paned_start = paned };
                }
            }

            if (paned.getEndChild()) |child| {
                if (child == widget) {
                    return .{ .paned_end = paned };
                }
            }
        }

        if (gobject.ext.cast(adw.Bin, parent)) |bin| {
            if (bin.getChild()) |child| {
                if (child == widget) {
                    return .{ .bin = bin };
                }
            }
        }

        return null;
    }

    fn clearParentSlot(slot: ParentSlot) void {
        switch (slot) {
            .bin => |bin| bin.setChild(null),
            .paned_start => |paned| paned.setStartChild(null),
            .paned_end => |paned| paned.setEndChild(null),
        }
    }

    fn detachForReplace(widget: *gtk.Widget) ?ParentSlot {
        const slot = parentSlotOf(widget) orelse return null;
        clearParentSlot(slot);
        return slot;
    }

    fn attachReplacement(slot: ParentSlot, widget: *gtk.Widget) void {
        switch (slot) {
            .bin => |bin| bin.setChild(widget),
            .paned_start => |paned| paned.setStartChild(widget),
            .paned_end => |paned| paned.setEndChild(widget),
        }
    }

    fn replaceLeafWithSplit(
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
        direction: Surface.Tree.Split.Direction,
        old_window: *SurfaceScrolledWindow,
        surface: *Surface,
    ) bool {
        const old_widget = old_window.as(gtk.Widget);
        _ = old_widget.as(gobject.Object).ref();
        defer old_widget.as(gobject.Object).unref();

        const slot = detachForReplace(old_widget) orelse {
            log.warn("unable to detach surface for incremental split", .{});
            return false;
        };

        const new_window = gobject.ext.newInstance(
            SurfaceScrolledWindow,
            .{ .surface = surface },
        );
        const new_widget = new_window.as(gtk.Widget);
        switch (tree.nodes[handle.idx()]) {
            .split => {},
            .leaf => {
                attachReplacement(slot, old_widget);
                return false;
            },
        }
        const split: *const Surface.Tree.Split = &tree.nodes[handle.idx()].split;

        const replacement = switch (direction) {
            .left, .up => SplitTreeSplit.new(handle, split, new_widget, old_widget),
            .right, .down => SplitTreeSplit.new(handle, split, old_widget, new_widget),
        };
        attachReplacement(slot, replacement.as(gtk.Widget));
        return true;
    }

    fn removeLeafFromSplit(
        self: *Self,
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
    ) bool {
        const parent_handle = findParentSplit(tree, handle, .root) orelse return false;
        const parent_split = &tree.nodes[parent_handle.idx()].split;
        const parent_widget = self.findSplitWidget(parent_handle) orelse return false;
        const start = parent_widget.getStartChild() orelse return false;
        const end = parent_widget.getEndChild() orelse return false;

        const target_is_start = parent_split.left == handle;
        const sibling = if (target_is_start) end else start;
        _ = sibling.as(gobject.Object).ref();
        defer sibling.as(gobject.Object).unref();

        const slot = parentSlotOf(parent_widget.as(gtk.Widget)) orelse return false;

        // Remove the sibling from the old split before detaching the split
        // widget from its grandparent, so the sibling can take its place.
        parent_widget.removeChild(sibling);

        clearParentSlot(slot);
        attachReplacement(slot, sibling);
        return true;
    }

    /// Builds the widget tree associated with a surface split tree.
    ///
    /// Returned widgets are expected to be attached to a parent by the caller.
    ///
    /// If `release_ref` is true then `widget` has an extra temporary
    /// reference that must be released once it is parented in the rebuilt
    /// tree.
    const BuildTreeResult = struct {
        widget: *gtk.Widget,
        release_ref: bool,

        pub fn initNew(widget: *gtk.Widget) BuildTreeResult {
            return .{ .widget = widget, .release_ref = false };
        }

        pub fn initReused(widget: *gtk.Widget) BuildTreeResult {
            // We add a temporary ref to the widget to ensure it doesn't
            // get destroyed while we're rebuilding the tree and detaching
            // it from its old parent. The caller is expected to release
            // this ref once the widget is attached to its new parent.
            _ = widget.as(gobject.Object).ref();

            // Detach after we ref it so that this doesn't mark the
            // widget for destruction.
            detachWidget(widget);

            return .{ .widget = widget, .release_ref = true };
        }

        pub fn deinit(self: BuildTreeResult) void {
            // If we have to release a ref, do it.
            if (self.release_ref) self.widget.as(gobject.Object).unref();
        }
    };

    fn buildTree(
        self: *Self,
        tree: *const Surface.Tree,
        current: Surface.Tree.Node.Handle,
    ) BuildTreeResult {
        return switch (tree.nodes[current.idx()]) {
            .leaf => |v| leaf: {
                const window = ext.getAncestor(
                    SurfaceScrolledWindow,
                    v.as(gtk.Widget),
                ) orelse {
                    // The surface isn't in a window already so we don't
                    // have to worry about reuse.
                    break :leaf .initNew(gobject.ext.newInstance(
                        SurfaceScrolledWindow,
                        .{ .surface = v },
                    ).as(gtk.Widget));
                };

                // Keep this widget alive while we detach it from the
                // old tree and adopt it into the new one.
                break :leaf .initReused(window.as(gtk.Widget));
            },
            .split => |s| split: {
                const left = self.buildTree(tree, s.left);
                defer left.deinit();
                const right = self.buildTree(tree, s.right);
                defer right.deinit();

                break :split .initNew(SplitTreeSplit.new(
                    current,
                    &s,
                    left.widget,
                    right.widget,
                ).as(gtk.Widget));
            },
        };
    }

    /// Detach a split widget from its current parent.
    ///
    /// We intentionally use parent-specific child APIs when possible
    /// (`GtkPaned.setStartChild/setEndChild`, `AdwBin.setChild`) instead of
    /// calling `gtk.Widget.unparent` directly. Container implementations track
    /// child pointers/properties internally, and those setters are the path
    /// that keeps container state and notifications in sync.
    fn detachWidget(widget: *gtk.Widget) void {
        const parent = widget.getParent() orelse return;

        // Surface will be in a paned when it is split.
        if (gobject.ext.cast(gtk.Paned, parent)) |paned| {
            if (paned.getStartChild()) |child| {
                if (child == widget) {
                    paned.setStartChild(null);
                    return;
                }
            }

            if (paned.getEndChild()) |child| {
                if (child == widget) {
                    paned.setEndChild(null);
                    return;
                }
            }
        }

        // Surface will be in a bin when it is not split.
        if (gobject.ext.cast(adw.Bin, parent)) |bin| {
            if (bin.getChild()) |child| {
                if (child == widget) {
                    bin.setChild(null);
                    return;
                }
            }
        }

        // Fallback for unexpected parents where we don't have a typed
        // container API available.
        widget.unparent();
    }

    //---------------------------------------------------------------
    // Class

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.@"has-surfaces".impl,
                properties.@"is-zoomed".impl,
                properties.tree.impl,
                properties.@"is-split".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tree_bin", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_tree", &propTree);

            // Signals
            signals.changed.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// This is an internal-only widget that represents a split in the
/// split tree. This is a wrapper around gtk.Paned that allows us to handle
/// ratio (0 to 1) based positioning of the split, and also allows us to
/// write back the updated ratio to the split tree when the user manually
/// adjusts the split position.
///
/// Since this is internal, it expects to be nested within a SplitTree and
/// will use `getAncestor` to find the SplitTree it belongs to.
///
/// This is an _immutable_ widget. It isn't meant to be updated after
/// creation. As such, there are no properties or APIs to change the split,
/// access the paned, etc.
const SplitTreeSplit = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTreeSplit",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The handle of the node in the tree that this split represents.
        /// Assumed to be correct.
        handle: Surface.Tree.Node.Handle,

        /// Source to handle repositioning the split when properties change.
        idle: ?c_uint = null,

        /// Force the next idle update to apply the tree ratio rather than
        /// treating the current paned position as a user resize. This is used
        /// after showing panes that were hidden by split zoom.
        force_position: bool = false,

        // Template bindings
        paned: *gtk.Paned,

        pub var offset: c_int = 0;
    };

    /// Create a new split.
    ///
    /// The reason we don't use GObject properties here is because this is
    /// an immutable widget and we don't want to deal with the overhead of
    /// all the boilerplate for properties, signals, bindings, etc.
    pub fn new(
        handle: Surface.Tree.Node.Handle,
        split: *const Surface.Tree.Split,
        start_child: *gtk.Widget,
        end_child: *gtk.Widget,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.handle = handle;

        // Setup our paned fields
        const paned = priv.paned;
        paned.setStartChild(start_child);
        paned.setEndChild(end_child);
        paned.as(gtk.Orientable).setOrientation(switch (split.layout) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        });

        // Signals and so on are setup in the template.

        return self;
    }

    fn getStartChild(self: *Self) ?*gtk.Widget {
        return self.private().paned.getStartChild();
    }

    fn setHandle(self: *Self, handle: Surface.Tree.Node.Handle) void {
        self.private().handle = handle;
    }

    fn getEndChild(self: *Self) ?*gtk.Widget {
        return self.private().paned.getEndChild();
    }

    fn removeChild(self: *Self, child: *gtk.Widget) void {
        const paned = self.private().paned;
        if (paned.getStartChild()) |start| {
            if (start == child) {
                paned.setStartChild(null);
                return;
            }
        }
        if (paned.getEndChild()) |end| {
            if (end == child) paned.setEndChild(null);
        }
    }

    fn restorePosition(self: *Self) void {
        const priv = self.private();
        priv.force_position = true;
        self.refresh();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        if (priv.idle == null) priv.idle = glib.idleAdd(
            onIdle,
            self,
        );
    }

    fn onIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        const paned = priv.paned;

        // Our idle source is always over
        priv.idle = null;

        // Get our split. This is the most dangerous part of this entire
        // widget. We assume that this widget is always a child of a
        // SplitTree, we assume that our handle is valid, and we assume
        // the handle is always a split node.
        const split_tree = ext.getAncestor(
            SplitTree,
            self.as(gtk.Widget),
        ) orelse return 0;
        const tree = split_tree.getTree() orelse return 0;

        // Hiding a sibling while zoomed changes the paned position and max
        // position. Those changes are not user resizes and must not mutate the
        // split's stored ratio.
        if (tree.zoomed != null) return 0;

        const split: *const Surface.Tree.Split = &tree.nodes[priv.handle.idx()].split;

        // Current, min, and max positions as pixels.
        const pos = paned.getPosition();
        const min = min: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "min-position",
                &val,
            );
            break :min gobject.ext.Value.get(&val, c_int);
        };
        const max = max: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "max-position",
                &val,
            );
            break :max gobject.ext.Value.get(&val, c_int);
        };
        const pos_set: bool = max: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "position-set",
                &val,
            );
            break :max gobject.ext.Value.get(&val, c_int) != 0;
        };

        // We don't actually use min, but we don't expect this to ever
        // be non-zero, so let's add an assert to ensure that.
        assert(min == 0);

        // If our max is zero then we can't do any math. I don't know
        // if this is possible but I suspect it can be if you make a nested
        // split completely minimized.
        if (max == 0) return 0;

        const desired_ratio: f64 = @floatCast(split.ratio);

        // After leaving zoom, restore the position from the tree ratio. The
        // paned position while its sibling was hidden is not meaningful.
        if (priv.force_position) {
            priv.force_position = false;
            const desired_pos: c_int = desired_pos: {
                const max_f64: f64 = @floatFromInt(max);
                break :desired_pos @intFromFloat(@round(max_f64 * desired_ratio));
            };
            paned.setPosition(desired_pos);
            return 0;
        }

        // Determine our current ratio.
        const current_ratio: f64 = ratio: {
            const pos_f64: f64 = @floatFromInt(pos);
            const max_f64: f64 = @floatFromInt(max);
            break :ratio pos_f64 / max_f64;
        };
        // If our ratio is close enough to our desired ratio, then
        // we ignore the update. This is to avoid constant split updates
        // for lossy floating point math.
        if (std.math.approxEqAbs(
            f64,
            current_ratio,
            desired_ratio,
            0.001,
        )) {
            return 0;
        }

        // If we're out of bounds, then we need to either set the position
        // to what we expect OR update our expected ratio.

        // If we've never set the position, then we set it to the desired.
        if (!pos_set) {
            const desired_pos: c_int = desired_pos: {
                const max_f64: f64 = @floatFromInt(max);
                break :desired_pos @intFromFloat(@round(max_f64 * desired_ratio));
            };
            paned.setPosition(desired_pos);
            return 0;
        }

        // If we've set the position, then this is a manual human update
        // and we need to write our update back to the tree.
        tree.resizeInPlace(priv.handle, @floatCast(current_ratio));

        return 0;
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn propPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    fn propMaxPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    fn propMinPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.idle) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove idle source", .{});
            }
            priv.idle = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree-split",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("paned", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_max_position", &propMaxPosition);
            class.bindTemplateCallback("notify_min_position", &propMinPosition);
            class.bindTemplateCallback("notify_position", &propPosition);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
