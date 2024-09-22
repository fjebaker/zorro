const std = @import("std");
const clippy = @import("clippy").ClippyInterface(.{});
const termui = @import("termui");
const farbe = @import("farbe");

const zotero = @import("zotero.zig");
const Library = zotero.Library;
const Item = zotero.Item;
const Author = zotero.Author;

const ArgsFind = clippy.Arguments(&.{
    .{
        .arg = "-a/--author name",
        .help = "Author (last) name.",
    },
    .{
        .arg = "-y/--year YYYY",
        .help = "Publication year. Optionally may use `before:YYYY`, `after:YYYY`, or `YYYY-YYYY` (range) to filter publication years.",
    },
});

const Commands = clippy.Commands(.{
    .commands = &.{
        .{ .name = "find", .args = ArgsFind },
    },
});

pub const FindQuery = struct {
    authors: []const []const u8 = &.{},
    before: ?usize = null,
    after: ?usize = null,

    pub fn fromArgs(
        allocator: std.mem.Allocator,
        args: ArgsFind.Parsed,
    ) !FindQuery {
        const authors: []const []const u8 = b: {
            if (args.author) |as| {
                var list = std.ArrayList([]const u8).init(allocator);
                defer list.deinit();

                var itt = std.mem.tokenizeAny(u8, as, ",");
                while (itt.next()) |auth| {
                    try list.append(auth);
                }

                break :b try list.toOwnedSlice();
            }
            break :b try allocator.alloc([]const u8, 0);
        };
        errdefer allocator.free(authors);

        var before: ?usize = null;
        var after: ?usize = null;

        if (args.year) |year| {
            if (std.mem.startsWith(u8, year, "before:")) {
                before = try std.fmt.parseInt(usize, year[7..], 10);
            } else if (std.mem.startsWith(u8, year, "after:")) {
                after = try std.fmt.parseInt(usize, year[6..], 10);
            } else if (std.mem.indexOfScalar(u8, year, '-')) |div| {
                after = try std.fmt.parseInt(usize, year[0..div], 10);
                before = try std.fmt.parseInt(usize, year[div + 1 ..], 10);
            } else {
                before = try std.fmt.parseInt(usize, year, 10);
                after = before;
            }
        }

        return .{
            .authors = authors,
            .before = before,
            .after = after,
        };
    }

    pub fn free(self: *const FindQuery, allocator: std.mem.Allocator) void {
        if (self.authors.len > 0) allocator.free(self.authors);
    }
};

fn testQuery(args: ArgsFind.Parsed, comptime expected: FindQuery) !void {
    const actual = try FindQuery.fromArgs(std.testing.allocator, args);
    defer actual.free(std.testing.allocator);

    try std.testing.expectEqualDeep(expected, actual);
}

test "query-parsing" {
    try testQuery(.{ .year = "1984" }, .{ .after = 1984, .before = 1984 });
    try testQuery(.{ .year = "before:1984" }, .{ .before = 1984 });
    try testQuery(.{ .year = "after:1984" }, .{ .after = 1984 });
    try testQuery(.{ .year = "1984-1990" }, .{ .after = 1984, .before = 1990 });
    try testQuery(.{ .author = "Orwell" }, .{ .authors = &.{"Orwell"} });
    try testQuery(
        .{ .author = "Orwell,Strauss" },
        .{ .authors = &.{ "Orwell", "Strauss" } },
    );
}

pub const Choice = struct {
    item: Item,
    // last names of the authors
    authors: []const Author,
};

const YEAR_MASK = 0b00000001;
const AUTHOR_MASK = 0b00000010;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // get arguments
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var arg_iterator = clippy.ArgIterator.init(raw_args);
    // skip the first argument
    _ = try arg_iterator.next();

    const parsed = Commands.parseAll(&arg_iterator) catch |err| {
        switch (err) {
            error.MissingCommand => {
                // const writer = std.io.getStdOut().writer();
                // try cmd_help.print_help(writer);
                return;
            },
            else => return err,
        }
    };

    // due to sqlite locking the database when it is open, we create a copy for
    // us to use
    const database_path = "/home/lilith/Zotero/zotero.sqlite";
    const mirror_path = "/home/lilith/Zotero/zotero-mirror.sqlite";
    try std.fs.copyFileAbsolute(database_path, mirror_path, .{});

    var lib = try Library.init(allocator, mirror_path);
    defer lib.deinit();
    try lib.load();

    switch (parsed.commands) {
        .find => |args| {
            const query = try FindQuery.fromArgs(allocator, args);
            defer query.free(allocator);

            // mask that toggles which ones have been selected
            //  00000000
            //        |+-- year
            //        +--- author
            const selected = try allocator.alloc(u8, lib.items.items.len);
            defer allocator.free(selected);
            @memset(selected, 0);

            // the check mask used to select the items at the end
            var check: u8 = 0;

            if (query.before != null or query.after != null) {
                check = check | YEAR_MASK;

                for (lib.items.items, 0..) |item, i| {
                    const year = item.pub_date.year;
                    const b_ok = if (query.before) |b| year <= b else true;
                    const a_ok = if (query.after) |a| year >= a else true;
                    if (b_ok and a_ok) {
                        selected[i] = selected[i] | YEAR_MASK;
                    }
                }
            }

            if (query.authors.len > 0) {
                check = check | AUTHOR_MASK;

                var itt = lib.author_id_to_author.iterator();

                // apply the selection filtering
                while (itt.next()) |item| {
                    var has_authors: bool = true;
                    for (query.authors) |a| {
                        if (!std.mem.containsAtLeast(u8, item.value_ptr.last, 1, a)) {
                            has_authors = false;
                            break;
                        }
                    }
                    // filter those with the wrong authors
                    if (!has_authors) continue;

                    const auth_id = item.key_ptr.*;
                    const ids = lib.author_to_id.get(auth_id).?;
                    for (ids.items) |id| {
                        const i = lib.id_to_items.get(id).?;
                        selected[i] = selected[i] | AUTHOR_MASK;
                    }
                }
            }

            const num_selected = b: {
                var count: usize = 0;
                for (selected) |s| {
                    if (s == check) count += 1;
                }
                break :b count;
            };

            if (num_selected == 0 or num_selected == selected.len) {
                std.debug.print("No matches\n", .{});
                return;
            }

            const options = try allocator.alloc(Choice, num_selected);
            defer allocator.free(options);

            var opts_index: usize = 0;
            for (lib.items.items, 0..) |item, index| {
                if (selected[index] != check) continue;
                const authors = try lib.getAuthors(lib.arena.allocator(), item.id);
                options[opts_index] = .{ .item = item, .authors = authors };
                opts_index += 1;
            }

            const choice = try promptForChoice(allocator, query, options) orelse return;
            const ci = options[choice];
            std.debug.print("Selected: {s}\n", .{ci.item.title});

            const atts = try lib.getAttachments(allocator, ci.item.id);
            defer allocator.free(atts);
            if (atts.len > 0) {
                try zotero.openPdf(allocator, atts[0]);
            } else {
                std.debug.print("No attachments for item...", .{});
            }
        },
    }
}

const MATCH_COLOR = farbe.Farbe.init().fgRgb(255, 0, 0).bold();

pub fn promptForChoice(allocator: std.mem.Allocator, query: FindQuery, items: []const Choice) !?usize {
    var tui = try termui.TermUI.init(
        std.io.getStdIn(),
        std.io.getStdOut(),
    );
    defer tui.deinit();
    // some sanity things
    tui.out.original.lflag.ISIG = true;
    tui.in.original.lflag.ISIG = true;
    tui.in.original.iflag.ICRNL = true;

    const ChoiceWrapper = struct {
        tui: *termui.TermUI,
        query: FindQuery,
        allocator: std.mem.Allocator,
        items: []const Choice,

        pub fn write(self: @This(), out: anytype, index: usize) anyerror!void {
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            const writer = buf.writer();

            const item = self.items[index];
            for (item.authors[0..@min(3, item.authors.len)]) |a| {
                if (self.query.authors.len == 0) {
                    try writer.writeAll(a.last);
                } else {
                    for (self.query.authors) |auth| {
                        if (std.mem.indexOf(u8, a.last, auth)) |i| {
                            try MATCH_COLOR.write(
                                writer,
                                "{s}",
                                .{a.last[i .. i + auth.len]},
                            );
                            if (a.last.len > auth.len) {
                                try writer.writeAll(a.last[auth.len..]);
                            }
                        } else {
                            try writer.writeAll(a.last);
                        }
                    }
                }
                try writer.writeAll(", ");
            }
            if (item.authors.len > 2) {
                try writer.writeAll("et al. ");
            } else {
                // remove the last comma
                _ = buf.pop();
                buf.items[buf.items.len - 1] = ' ';
            }

            try writer.writeAll("(");
            if (self.query.after != null or self.query.before != null) {
                try MATCH_COLOR.write(writer, "{d}", .{item.item.pub_date.year});
            } else {
                try writer.print("{d}", .{item.item.pub_date.year});
            }
            try writer.writeAll("): ");

            const size = try self.tui.getSize();

            const rem = size.col -| (buf.items.len + 5);
            if (rem > item.item.title.len) {
                try buf.appendSlice(item.item.title);
            } else {
                try buf.appendSlice(item.item.title[0..rem -| 3]);
                try buf.appendSlice("...");
            }

            try out.writeAll(buf.items);
        }
    };

    const cw: ChoiceWrapper = .{
        .tui = &tui,
        .query = query,
        .allocator = allocator,
        .items = items,
    };

    return try termui.Selector.interactFmt(
        &tui,
        cw,
        ChoiceWrapper.write,
        items.len,
        .{ .clear = true },
    );
}
