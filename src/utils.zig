const std = @import("std");
const zeit = @import("zeit");
pub const clippy = @import("clippy").ClippyInterface(.{});

pub const State = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    zotero_path: [:0]const u8,

    pub fn init(allocator: std.mem.Allocator, zotero_path: [:0]const u8) State {
        const arena = std.heap.ArenaAllocator.init(allocator);
        return .{
            .allocator = allocator,
            .arena = arena,
            .zotero_path = zotero_path,
        };
    }

    pub fn deinit(self: *State) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Get a subpath from the zotero root directory. Caller owns memory.
    pub fn makePath(
        self: *const State,
        allocator: std.mem.Allocator,
        p: []const u8,
    ) ![:0]const u8 {
        return try std.fs.path.joinZ(
            allocator,
            &.{ self.zotero_path, p },
        );
    }

    /// Get a subpath from the zotero root directory. Caller owns memory.
    pub fn makePath2(
        self: *const State,
        allocator: std.mem.Allocator,
        paths: []const []const u8,
    ) ![:0]const u8 {
        const temp = try std.fs.path.join(allocator, paths);
        defer allocator.free(temp);
        return try std.fs.path.joinZ(
            allocator,
            &.{ self.zotero_path, temp },
        );
    }

    /// Make a copy of the current Zotero database, as concurrent access is
    /// forbidden. Returns the absolute path to the mirror.
    ///
    // Due to sqlite locking the database when it is open, we create a copy for
    // us to use.
    pub fn makeMirrorDB(self: *State) ![:0]const u8 {
        const database_path = try self.makePath(
            self.allocator,
            "zotero.sqlite",
        );
        defer self.allocator.free(database_path);
        const mirror_path = try self.makePath(
            self.arena.allocator(),
            "zotero-mirror.sqlite",
        );
        try std.fs.copyFileAbsolute(database_path, mirror_path, .{});
        return mirror_path;
    }
};

pub fn parseDate(date: []const u8) !zeit.Time {
    const year = try std.fmt.parseInt(i32, date[0..4], 10);
    const month = @max(1, try std.fmt.parseInt(u5, date[5..7], 10));
    const day = @max(1, try std.fmt.parseInt(u5, date[8..10], 10));
    return .{ .year = year, .month = @enumFromInt(month), .day = day };
}

fn testParseDate(date: []const u8, comptime expected: zeit.Time) !void {
    const t = try parseDate(date);
    try std.testing.expectEqualDeep(expected, t);
}

test "parse-date" {
    try testParseDate(
        "2024-01-02",
        .{ .day = 2, .month = .jan, .year = 2024 },
    );
}

/// Get the index pointing to the end of the current slice returned by a
/// standard library split iterator
pub fn getSplitIndex(itt: std.mem.SplitIterator(u8, .scalar)) usize {
    if (itt.index) |ind| {
        return ind - 1;
    } else {
        return itt.buffer.len;
    }
}

pub fn Iterator(comptime T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,
        pub fn init(items: []const T) @This() {
            return .{ .items = items };
        }

        /// Get the next item and advance the counter.
        pub fn next(self: *@This()) ?T {
            if (self.index >= self.items.len) return null;
            const item = self.items[self.index];
            self.index += 1;
            return item;
        }

        /// Get at the next item without advancing the counter.
        pub fn peek(self: *@This()) ?T {
            if (self.index >= self.items.len) return null;
            return self.items[self.index];
        }
    };
}

pub const LineWindowIterator = struct {
    pub const LineSlice = struct {
        line_no: usize,
        slice: []const u8,
    };
    itt: std.mem.SplitIterator(u8, .scalar),
    chunk: ?std.mem.WindowIterator(u8) = null,

    size: usize,
    stride: usize,
    current_line: usize = 0,

    end_index: usize = 0,

    fn getNextWindow(w: *LineWindowIterator) ?[]const u8 {
        if (w.chunk) |*chunk| {
            const line = chunk.next();
            if (line) |l| {
                w.end_index += l.len;
                return l;
            }
        }
        return null;
    }

    fn package(w: *LineWindowIterator, line: []const u8) LineSlice {
        return .{ .line_no = w.current_line, .slice = line };
    }

    /// Returns the next `LineSlice`
    pub fn next(w: *LineWindowIterator) ?LineSlice {
        if (w.getNextWindow()) |line| {
            return w.package(line);
        }

        while (w.itt.next()) |section| {
            w.end_index = getSplitIndex(w.itt) - section.len;
            w.chunk = std.mem.window(u8, section, w.size, w.stride);
            if (w.getNextWindow()) |line| {
                const pkg = w.package(line);
                w.current_line += 1;
                return pkg;
            }
        }
        return null;
    }
};

pub fn lineWindow(text: []const u8, size: usize, stride: usize) LineWindowIterator {
    const itt = std.mem.splitScalar(u8, text, '\n');
    return .{ .itt = itt, .size = size, .stride = stride };
}
