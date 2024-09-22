const std = @import("std");
const clippy = @import("clippy").ClippyInterface(.{});
const termui = @import("termui");

const zotero = @import("zotero.zig");
const Library = zotero.Library;
const Item = zotero.Item;
const Author = zotero.Author;

const ArgsFind = clippy.Arguments(&.{
    .{
        .arg = "-a/--author name",
        .help = "Author (last) name.",
    },
});

const Commands = clippy.Commands(.{
    .commands = &.{
        .{ .name = "find", .args = ArgsFind },
    },
});

pub const Choice = struct {
    item: Item,
    // last names of the authors
    authors: []const Author,
};

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

    var lib = try Library.init(allocator, "/home/lilith/Zotero/database.sqlite");
    defer lib.deinit();
    try lib.load();

    // std.debug.print("Parsed {d} items.\n", .{
    //     lib.items.items.len,
    // });

    switch (parsed.commands) {
        .find => |args| {
            var author_ids = std.ArrayList(usize).init(allocator);
            defer author_ids.deinit();

            var itt = lib.author_id_to_author.iterator();
            while (itt.next()) |item| {
                if (std.mem.containsAtLeast(
                    u8,
                    item.value_ptr.last,
                    1,
                    args.author.?,
                )) {
                    try author_ids.append(item.key_ptr.*);
                }
            }

            var options = std.ArrayList(Choice).init(allocator);
            defer options.deinit();

            // now that we have the author id's, we look up the items
            for (author_ids.items) |author_id| {
                const ids = lib.author_to_id.get(author_id).?;
                for (ids.items) |id| {
                    const item = lib.getItem(id).?;
                    const authors = try lib.getAuthors(lib.arena.allocator(), id);
                    try options.append(.{ .item = item, .authors = authors });

                    // for (authors) |a| {
                    //     std.debug.print("{s} ", .{a.last});
                    // }
                    // std.debug.print("\n{any}: {s}\n", .{ item.pub_date, item.title });
                    // const atts = try lib.getAttachments(alloc, id);
                    // if (atts.len > 0) {
                    //     std.debug.print("zotero://open-pdf/library/items/{s}\n\n", .{atts[0]});
                    // }
                }
            }

            const choice = try promptForChoice(allocator, options.items) orelse return;
            const ci = options.items[choice];
            std.debug.print("Selected: {s}\n", .{ci.item.title});

            const atts = try lib.getAttachments(allocator, ci.item.id);
            defer allocator.free(atts);
            if (atts.len > 0) {
                std.debug.print("zotero://open-pdf/library/items/{s}\n", .{atts[0]});
            } else {
                std.debug.print("No attachments for item...", .{});
            }
        },
    }
}

pub fn promptForChoice(allocator: std.mem.Allocator, items: []const Choice) !?usize {
    var tui = try termui.TermUI.init(
        std.io.getStdIn(),
        std.io.getStdOut(),
    );
    defer tui.deinit();

    const ChoiceWrapper = struct {
        tui: *termui.TermUI,
        allocator: std.mem.Allocator,
        items: []const Choice,

        pub fn write(self: @This(), out: anytype, index: usize) anyerror!void {
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            const writer = buf.writer();

            const item = self.items[index];
            for (item.authors[0..@min(3, item.authors.len)]) |a| {
                try writer.print("{s}, ", .{a.last});
            }
            if (item.authors.len > 2) {
                try writer.writeAll("et al. ");
            } else {
                // remove the last comma
                _ = buf.pop();
                buf.items[buf.items.len - 1] = ' ';
            }

            try writer.print("({d}): ", .{item.item.pub_date.year});

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
