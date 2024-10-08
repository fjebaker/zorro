const std = @import("std");
const termui = @import("termui");
const farbe = @import("farbe");
const zeit = @import("zeit");

const utils = @import("utils.zig");
const zotero = @import("zotero.zig");

const clippy = utils.clippy;

const Library = zotero.Library;
const Item = zotero.Item;
const Author = zotero.Author;

const logger = std.log.scoped(.find);

const YEAR_MASK = 0b00000001;
const AUTHOR_MASK = 0b00000010;
const ADDED_MASK = 0b00000100;

// how much the correct order scores
const AUTHOR_SCORE = 1;
// how many positions to give bonus scores to for the right author
const AUTHOR_SCORE_POSITION = 5;

const MATCH_COLOR = farbe.Farbe.init().fgRgb(255, 0, 0).bold();
const STATUS_COLOR = farbe.Farbe.init().fgRgb(255, 128, 0).bold();

pub const Args = clippy.Arguments(&.{
    .{
        .arg = "-a/--author name",
        .help = "Author (last) name. The value `.` has the special meaning that it will match any author, but the item *must* have an author.",
    },
    .{
        .arg = "-y/--year YYYY",
        .help = "Publication year. Optionally may use `before:YYYY`, `after:YYYY`, or `before:YYYY,after:YYYY` to filter publication years.",
    },
    .{
        .arg = "--added expr",
        .help = "Use to filter when the item was added to the library. Valid expressions are `YYYY-[MM[-DD]]`, `before:YYYY[-MM[-DD]]`, `after:YYYY[-MM[-DD]]`, or `before:YYYY[-MM[-DD]],after:YYYY[-M[-DD]].",
    },
});

const ScoreMask = struct {
    score: i32 = 0,
    mask: u8 = 0,
};

const Choice = struct {
    score: i32 = 0,
    item: Item,
    // last names of the authors
    authors: []const Author,

    pub fn sortScore(_: void, a: Choice, b: Choice) bool {
        return a.score > b.score;
    }
};

const FindQuery = struct {
    authors: []const []const u8 = &.{},
    date_range: utils.DateRange = .{},
    added_range: utils.DateRange = .{},

    pub fn fromArgs(
        allocator: std.mem.Allocator,
        args: Args.Parsed,
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

        return .{
            .authors = authors,
            .date_range = try utils.parseDateExpr(args.year),
            .added_range = try utils.parseDateExpr(args.added),
        };
    }

    pub fn free(self: *const FindQuery, allocator: std.mem.Allocator) void {
        if (self.authors.len > 0) allocator.free(self.authors);
    }
};

fn testQuery(args: Args.Parsed, comptime expected: FindQuery) !void {
    const actual = try FindQuery.fromArgs(std.testing.allocator, args);
    defer actual.free(std.testing.allocator);

    try std.testing.expectEqualDeep(expected, actual);
}

test "query-parsing" {
    try testQuery(.{ .author = "Orwell" }, .{ .authors = &.{"Orwell"} });
    try testQuery(
        .{ .author = "Orwell,Strauss" },
        .{ .authors = &.{ "Orwell", "Strauss" } },
    );
}

fn filterQuery(
    allocator: std.mem.Allocator,
    query: FindQuery,
    lib: *Library,
) ![]Choice {
    // mask that toggles which ones have been selected
    //  00000000
    //       ||+-- year
    //       |+-- author
    //       +-- added
    const selected = try allocator.alloc(ScoreMask, lib.items.items.len);
    defer allocator.free(selected);
    for (selected) |*s| s.* = .{};

    // the check mask used to select the items at the end
    var check: u8 = 0;

    logger.debug("Date range: {any}", .{query.date_range});
    if (query.date_range.before != null or query.date_range.after != null) {
        const dr = query.date_range;
        check = check | YEAR_MASK;
        for (lib.items.items, 0..) |item, i| {
            if (dr.filterTime(item.pub_date)) {
                selected[i].mask |= YEAR_MASK;
            }
        }
    }

    logger.debug("Added range: {any}", .{query.added_range});
    if (query.added_range.before != null or query.added_range.after != null) {
        const dr = query.added_range;
        check = check | ADDED_MASK;
        for (lib.items.items, 0..) |item, i| {
            if (dr.filterTime(item.added_date)) {
                selected[i].mask |= ADDED_MASK;
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
                if (a.len == 1 and a[0] == '.') {
                    has_authors = true;
                    break;
                }
                if (std.mem.containsAtLeast(u8, item.value_ptr.last, 1, a)) {
                    has_authors = true;
                    break;
                }
            }
            // filter those with the wrong authors
            if (!has_authors) continue;

            const auth_id = item.key_ptr.*;
            const ids = lib.author_to_id.get(auth_id) orelse continue;
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

    const options = try allocator.alloc(Choice, num_selected);
    errdefer allocator.free(options);

    if (num_selected == 0) {
        return options;
    }

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

    return options;
}

pub fn run(args: Args.Parsed, state: *utils.State, lib: *Library) !void {
    const query = try FindQuery.fromArgs(state.allocator, args);
    defer query.free(state.allocator);

    const options = try filterQuery(state.allocator, query, lib);
    defer state.allocator.free(options);

    if (options.len == 0) {
        std.debug.print("No items match selection.\n", .{});
        return;
    }

    // sort by score
    std.sort.heap(Choice, options, {}, Choice.sortScore);

    const choice = try promptForChoice(
        state.allocator,
        lib,
        query,
        options,
    ) orelse return;

    const ci = options[choice.index];
    std.debug.print("Selected: {s}\n", .{ci.item.title});

    const atts = try lib.getAttachments(state.allocator, ci.item.id);
    defer state.allocator.free(atts);

    if (atts.len == 0) {
        std.debug.print("No attachments for item...", .{});
    }

    switch (choice.how) {
        .path => {
            const split = std.mem.indexOf(u8, atts[0].path, ":").? + 1;
            const full_path = try state.makePath2(
                state.allocator,
                &.{ "storage", atts[0].key, atts[0].path[split..] },
            );
            defer state.allocator.free(full_path);

            std.debug.print("'{s}'\n", .{full_path});
        },
        .open_item => {
            // select and then open
            try zotero.select(state.allocator, ci.item.key);
            try zotero.openPdf(state.allocator, atts[0].key);
        },
    }
}

pub const Result = struct {
    index: usize,
    how: enum { path, open_item } = .open_item,
};

pub fn promptForChoice(
    allocator: std.mem.Allocator,
    lib: *Library,
    query: FindQuery,
    items: []const Choice,
) !?Result {
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

    var cw: ChoiceWrapper = .{
        .query = query,
        .allocator = allocator,
        .items = items,
        .lib = lib,
        .author_pad = longest_author,
    };

    const choice_index = try termui.Selector.interactAlt(
        &tui,
        &cw,
        ChoiceWrapper.predraw,
        ChoiceWrapper.write,
        ChoiceWrapper.input,
        items.len,
        .{
            .clear = true,
            .max_rows = @max(2, @min(18, items.len)),
            .pad_below = 2,
            .pad_above = 1,
        },
    );

    if (cw.path) |p| {
        return .{ .index = p, .how = .path };
    }
    if (choice_index) |index| {
        return .{ .index = index };
    }
    return null;
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

const ChoiceWrapper = struct {
    query: FindQuery,
    allocator: std.mem.Allocator,
    items: []const Choice,
    lib: *Library,
    author_pad: usize,
    cols: usize = 0,
    // set to value to just print path instead of opening item
    path: ?usize = null,

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
        const dr = self.query.date_range;
        if (dr.after != null or dr.before != null) {
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

        const end = @min(item.item.title.len, self.cols -| 10);

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const writer = buf.writer();

        try STATUS_COLOR.write(writer, "Selected", .{});

        try s.display.printToRowC(
            status_row - 1,
            "{s}: {s} (date: {d:0>4}-{d:0>2}-{d:0>2} | added: {d:0>4}-{d:0>2}-{d:0>2})",
            .{
                buf.items,
                item.item.key,
                @abs(item.item.pub_date.year),
                @intFromEnum(item.item.pub_date.month),
                item.item.pub_date.day,
                @abs(item.item.added_date.year),
                @intFromEnum(item.item.added_date.month),
                item.item.added_date.day,
            },
        );
        try s.display.printToRowC(
            status_row,
            "   Title: {s}",
            .{
                item.item.title[0..end],
            },
        );
    }

    pub fn input(
        self: *@This(),
        s: *termui.Selector,
        key: termui.TermUI.Input,
    ) anyerror!termui.InputHandleOutcome {
        const index = s.getSelected();
        const item = self.items[index];
        const status_row = s.display.max_rows - 1;
        switch (key) {
            .char => |c| switch (c) {
                's' => {
                    try zotero.select(self.allocator, item.item.key);

                    try s.display.moveToEnd();
                    try s.display.writeToRowC(status_row, "! Selected item");
                    return .skip;
                },
                'p' => {
                    self.path = index;
                    return .exit;
                },
                'o' => {
                    const atts = try self.lib.getAttachments(
                        self.allocator,
                        item.item.id,
                    );
                    defer self.allocator.free(atts);

                    try s.display.moveToEnd();

                    if (atts.len > 0) {
                        try zotero.openPdf(self.allocator, atts[0].key);
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
                    return .skip;
                },
                else => {},
            },
            else => {},
        }
        return .handle;
    }
};
