const std = @import("std");
const clippy = @import("clippy").ClippyInterface(.{});
const termui = @import("termui");

const farbe = @import("farbe");

const zotero = @import("zotero.zig");
const Library = zotero.Library;
const Item = zotero.Item;
const Author = zotero.Author;

const Key = termui.TermUI.Key;

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

const ArgsHelp = clippy.Arguments(&.{});

const Commands = clippy.Commands(.{
    .commands = &.{
        .{ .name = "find", .args = ArgsFind },
        .{ .name = "help", .args = ArgsHelp },
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
    score: i32 = 0,
    item: Item,
    // last names of the authors
    authors: []const Author,

    pub fn sortScore(_: void, a: Choice, b: Choice) bool {
        return a.score > b.score;
    }
};

pub const ScoreMask = struct {
    score: i32 = 0,
    mask: u8 = 0,
};

const YEAR_MASK = 0b00000001;
const AUTHOR_MASK = 0b00000010;
// how much the correct order scores
const AUTHOR_SCORE = 1;
// how many positions to give bonus scores to for the right author
const AUTHOR_SCORE_POSITION = 5;

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
                const out = std.io.getStdErr().writer();
                try out.writeAll("Missing command");
                try Commands.writeHelp(out, .{});
                if (@import("builtin").mode != .Debug) {
                    std.process.exit(1);
                }
                return;
            },
            else => return err,
        }
    };

    const home_path = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_path);

    // due to sqlite locking the database when it is open, we create a copy for
    // us to use
    const database_path = try std.fs.path.joinZ(
        allocator,
        &.{ home_path, "Zotero/zotero.sqlite" },
    );
    defer allocator.free(database_path);
    const mirror_path = try std.fs.path.joinZ(
        allocator,
        &.{ home_path, "Zotero/zotero-mirror.sqlite" },
    );
    defer allocator.free(mirror_path);
    try std.fs.copyFileAbsolute(database_path, mirror_path, .{});

    var lib = try Library.init(allocator, mirror_path);
    defer lib.deinit();
    try lib.load();

    switch (parsed.commands) {
        .help => {
            const out = std.io.getStdOut().writer();
            try Commands.writeHelp(out, .{});
            return;
        },
        .find => |args| {
            const query = try FindQuery.fromArgs(allocator, args);
            defer query.free(allocator);

            // mask that toggles which ones have been selected
            //  00000000
            //        |+-- year
            //        +--- author
            const selected = try allocator.alloc(ScoreMask, lib.items.items.len);
            defer allocator.free(selected);
            for (selected) |*s| s.* = .{};

            // the check mask used to select the items at the end
            var check: u8 = 0;

            if (query.before != null or query.after != null) {
                check = check | YEAR_MASK;

                for (lib.items.items, 0..) |item, i| {
                    const year = item.pub_date.year;
                    const b_ok = if (query.before) |b| year <= b else true;
                    const a_ok = if (query.after) |a| year >= a else true;
                    if (b_ok and a_ok) {
                        selected[i].mask |= YEAR_MASK;
                    }
                }
            }

            if (query.authors.len > 0) {
                check = check | AUTHOR_MASK;

                var itt = lib.author_id_to_author.iterator();

                // apply the selection filtering
                while (itt.next()) |item| {
                    var has_authors: bool = false;
                    for (query.authors) |a| {
                        if (std.mem.containsAtLeast(u8, item.value_ptr.last, 1, a)) {
                            has_authors = true;
                            break;
                        }
                    }
                    // filter those with the wrong authors
                    if (!has_authors) continue;

                    const auth_id = item.key_ptr.*;
                    const ids = lib.author_to_id.get(auth_id).?;
                    for (ids.items) |id| {
                        const i = lib.id_to_items.get(id).?;
                        const authors = lib.id_to_author.get(id).?;

                        const matched_position = b: {
                            for (authors.items) |auth| {
                                if (auth.id == auth_id) break :b auth.order;
                            }
                            unreachable;
                        };

                        selected[i].score += @intCast(AUTHOR_SCORE * @max(
                            1,
                            AUTHOR_SCORE_POSITION -| matched_position,
                        ));
                        selected[i].mask |= AUTHOR_MASK;
                    }
                }
            }

            const num_selected = b: {
                var count: usize = 0;
                for (selected) |s| {
                    if (s.mask == check) count += 1;
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
                if (selected[index].mask != check) continue;
                const authors = try lib.getAuthors(lib.arena.allocator(), item.id);
                options[opts_index] = .{
                    .score = selected[index].score,
                    .item = item,
                    .authors = authors,
                };
                opts_index += 1;
            }

            // sort by score
            std.sort.heap(Choice, options, {}, Choice.sortScore);

            const choice = try promptForChoice(
                allocator,
                &lib,
                query,
                options,
            ) orelse return;
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

    // let the OS cleanup
    if (@import("builtin").mode != .Debug) {
        std.process.exit(0);
    }
}

const MATCH_COLOR = farbe.Farbe.init().fgRgb(255, 0, 0).bold();

pub fn promptForChoice(
    allocator: std.mem.Allocator,
    lib: *Library,
    query: FindQuery,
    items: []const Choice,
) !?usize {
    // TODO: there's no need to actually write into memory here, we just need
    // to know which is going to be the longest
    var tmpbuf = std.ArrayList(u8).init(allocator);
    defer tmpbuf.deinit();

    const longest_author = b: {
        var longest: usize = 0;
        for (items) |item| {
            const len = try writeAuthor(
                tmpbuf.writer(),
                query.authors,
                item.authors,
                false,
            );
            longest = @max(len, longest);
        }
        break :b longest;
    };

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
        query: FindQuery,
        allocator: std.mem.Allocator,
        items: []const Choice,
        lib: *Library,
        author_pad: usize,
        cols: usize = 0,

        pub fn write(
            self: *@This(),
            _: *termui.Selector,
            out: anytype,
            index: usize,
        ) anyerror!void {
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            const writer = buf.writer();

            const item = self.items[index];

            const author_len = try writeAuthor(
                writer,
                self.query.authors,
                item.authors,
                true,
            );
            try writer.writeByteNTimes(' ', self.author_pad -| author_len);

            var len: usize = self.author_pad;

            try writer.writeAll(" (");
            if (self.query.after != null or self.query.before != null) {
                try MATCH_COLOR.write(writer, "{d}", .{item.item.pub_date.year});
            } else {
                try writer.print("{d}", .{item.item.pub_date.year});
            }
            try writer.writeAll("): ");
            len += 4 + 4;

            const rem = self.cols -| (len + 12);
            if (rem > item.item.title.len) {
                try buf.appendSlice(item.item.title);
            } else {
                try buf.appendSlice(item.item.title[0..rem -| 3]);
                try buf.appendSlice("...");
            }

            try out.writeAll(buf.items);
        }

        pub fn predraw(self: *@This(), s: *termui.Selector) anyerror!void {
            const size = try s.display.ctrl.tui.getSize();
            self.cols = size.col;

            if (self.items.len != 1) {
                try s.display.printToRowC(0, "Found {d} matches", .{self.items.len});
            } else {
                try s.display.printToRowC(0, "Found 1 match", .{});
            }

            const index = s.getSelected();
            const item = self.items[index];
            const status_row = s.display.max_rows - 1;

            const end = @min(item.item.title.len, self.cols - 5);
            try s.display.printToRowC(
                status_row,
                " {s}",
                .{item.item.title[0..end]},
            );
        }

        pub fn input(
            self: *@This(),
            s: *termui.Selector,
            key: termui.TermUI.Input,
        ) anyerror!bool {
            const index = s.getSelected();
            const item = self.items[index];
            const status_row = s.display.max_rows - 1;
            switch (key) {
                .char => |c| switch (c) {
                    's' => {
                        try zotero.select(self.allocator, item.item.key);

                        try s.display.moveToEnd();
                        try s.display.writeToRowC(status_row, "! Selected item");
                    },
                    'o' => {
                        const atts = try self.lib.getAttachments(
                            self.allocator,
                            item.item.id,
                        );
                        defer self.allocator.free(atts);

                        try s.display.moveToEnd();

                        if (atts.len > 0) {
                            try zotero.openPdf(self.allocator, atts[0]);
                            try s.display.writeToRowC(
                                status_row,
                                "! Opened item",
                            );
                        } else {
                            try s.display.writeToRowC(
                                status_row,
                                "! Item has no attachments",
                            );
                        }
                    },
                    else => {},
                },
                else => {},
            }
            return true;
        }
    };

    var cw: ChoiceWrapper = .{
        .query = query,
        .allocator = allocator,
        .items = items,
        .lib = lib,
        .author_pad = longest_author,
    };

    return try termui.Selector.interactAlt(
        &tui,
        &cw,
        ChoiceWrapper.predraw,
        ChoiceWrapper.write,
        ChoiceWrapper.input,
        items.len,
        .{
            .clear = true,
            .max_rows = 18,
            .pad_below = 1,
            .pad_above = 1,
        },
    );
}

fn writeAuthor(
    writer: anytype,
    query_authors: []const []const u8,
    authors: []const Author,
    color: bool,
) !usize {
    var len: usize = 0;
    for (0..@min(3, authors.len)) |index| {
        const a = authors[index];

        if (!color or query_authors.len == 0) {
            try writer.writeAll(a.last);
        } else {
            // highlight the matching author
            if (!try writeHighlightMatch(writer, a.last, query_authors)) {
                try writer.writeAll(a.last);
            }
        }

        len += try std.unicode.calcUtf16LeLen(a.last);

        // dont write a comma for the last author
        if (index != 2 and index != authors.len - 1) {
            try writer.writeAll(", ");
            len += 2;
        }
    }

    if (authors.len > 2) {
        try writer.writeAll(", [+]");
        len += 5;
    }

    return len;
}

fn writeHighlightMatch(
    writer: anytype,
    last_name: []const u8,
    query_authors: []const []const u8,
) !bool {
    for (query_authors) |auth| {
        if (std.mem.indexOf(u8, last_name, auth)) |i| {
            try MATCH_COLOR.write(
                writer,
                "{s}",
                .{last_name[i .. i + auth.len]},
            );
            if (last_name.len > auth.len) {
                try writer.writeAll(last_name[auth.len..]);
            }
            return true;
        }
    }
    return false;
}
