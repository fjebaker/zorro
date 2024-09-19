const std = @import("std");

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
