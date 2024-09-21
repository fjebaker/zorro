const std = @import("std");
const sqlite = @import("sqlite");
const zeit = @import("zeit");
const clippy = @import("clippy").ClippyInterface(.{});

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

pub const Author = struct {
    first: []const u8,
    last: []const u8,
};

pub const Item = struct {
    id: usize,
    key: []const u8,
    title: []const u8 = "No Title",
    abstract: []const u8 = "No Abstract",
    pub_date: zeit.Time = .{},
};

const ITEM_INFO_QUERY =
    \\SELECT items.itemID, "key", "value", "fieldID" FROM items
    \\    JOIN itemTypes on items.itemTypeID == itemTypes.itemTypeID
    \\    RIGHT JOIN itemData on items.itemID == itemData.itemID
    \\    JOIN itemDataValues on itemData.valueID == itemDataValues.valueID
    \\    WHERE "fieldID" in (1, 2, 6)
    \\;
;

const AUTHOR_LOOKUP_QUERY =
    \\SELECT "creatorID", "firstName", "lastName" FROM creators;
;

const AUTHOR_QUERY =
    \\SELECT items.itemID, "creatorID", "orderIndex" FROM items
    \\    JOIN itemCreators on items.itemID == itemCreators.itemID
    \\;
;

const ATTACHMENT_QUERY =
    \\SELECT
    \\    itemID FROM itemAttachments
    \\    WHERE parentItemID = ?
    \\        AND contentType = 'application/pdf'
    \\;
;

pub const Range = struct {
    start: usize,
    end: usize,
};

const OrderedAuthorIndex = struct {
    id: usize,
    order: usize,
};

pub const Library = struct {
    const AuthorMap = std.AutoArrayHashMap(usize, Author);
    const AuthorList = std.ArrayList(OrderedAuthorIndex);
    const IdList = std.ArrayList(usize);

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    author_id_to_author: AuthorMap,

    // keep a bi-directional mapping from key to authors and vice versa
    id_to_author: std.AutoArrayHashMap(usize, AuthorList),
    author_to_id: std.AutoArrayHashMap(usize, IdList),

    items: std.ArrayList(Item),
    // gives the index into the items array of the key
    id_to_items: std.AutoArrayHashMap(usize, usize),

    db: sqlite.Db,

    pub fn init(allocator: std.mem.Allocator, path: [:0]const u8) !Library {
        const arena = std.heap.ArenaAllocator.init(allocator);
        const db = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = path },
            .open_flags = .{
                .write = false,
                .create = false,
            },
            .threading_mode = .MultiThread,
        });
        return .{
            .allocator = allocator,
            .arena = arena,
            .author_id_to_author = AuthorMap.init(allocator),
            .id_to_author = std.AutoArrayHashMap(usize, AuthorList).init(allocator),
            .author_to_id = std.AutoArrayHashMap(usize, IdList).init(allocator),
            .items = std.ArrayList(Item).init(allocator),
            .id_to_items = std.AutoArrayHashMap(usize, usize).init(allocator),
            .db = db,
        };
    }

    pub fn deinit(self: *Library) void {
        self.arena.deinit();
        self.db.deinit();
        self.author_id_to_author.deinit();
        self.id_to_author.deinit();
        self.author_to_id.deinit();
        self.items.deinit();
        self.id_to_items.deinit();
        self.* = undefined;
    }

    /// Query and parse relevant information from the database to represent the
    /// library in memory
    pub fn load(self: *Library) !void {
        try self.loadAuthors();

        var item_info = try self.db.prepare(ITEM_INFO_QUERY);
        defer item_info.deinit();

        var current_id: ?usize = null;

        var item: *Item = undefined;
        var item_iter = try item_info.iterator(struct {
            id: usize,
            key: []const u8,
            value: []const u8,
            fieldID: usize,
        }, .{});

        const alloc = self.arena.allocator();
        while (try item_iter.nextAlloc(alloc, .{})) |n| {
            if (current_id == null or current_id.? != n.id) {
                current_id = n.id;
                try self.id_to_items.put(n.id, self.items.items.len);
                item = try self.addOne();
                // default initialize
                item.* = .{ .id = n.id, .key = n.key };
            }

            switch (n.fieldID) {
                1 => item.title = n.value,
                2 => item.abstract = n.value,
                6 => {
                    const year = try std.fmt.parseInt(i32, n.value[0..4], 10);
                    item.pub_date = .{ .year = year };
                },
                else => unreachable,
            }
        }
    }

    fn loadAuthors(self: *Library) !void {
        // first we read the id to author name map
        var author_lookup_info = try self.db.prepare(AUTHOR_LOOKUP_QUERY);
        defer author_lookup_info.deinit();

        var author_iter = try author_lookup_info.iterator(struct {
            creatorID: usize,
            first: []const u8,
            last: []const u8,
        }, .{});

        // ensure a decent amount of capacity to speed things up a little
        try self.author_id_to_author.ensureTotalCapacity(10_000);

        const alloc = self.arena.allocator();
        while (try author_iter.nextAlloc(alloc, .{})) |a| {
            const author: Author = .{
                .first = a.first,
                .last = a.last,
            };
            try self.author_id_to_author.put(a.creatorID, author);
        }

        // then we build the key to author lookup tables
        var author_info = try self.db.prepare(AUTHOR_QUERY);
        defer author_info.deinit();

        var iter = try author_info.iterator(struct {
            id: usize,
            creatorID: usize,
            orderIndex: usize,
        }, .{});

        // again ensure capacity
        try self.author_to_id.ensureTotalCapacity(10_000);
        try self.id_to_author.ensureTotalCapacity(10_000);

        while (try iter.nextAlloc(alloc, .{})) |a| {
            const a2k = try self.author_to_id.getOrPut(a.creatorID);
            if (!a2k.found_existing) {
                // TODO: this might need to use a regular allocator not an
                // arena allocator
                a2k.value_ptr.* = IdList.init(alloc);
            }
            try a2k.value_ptr.append(a.id);

            const k2a = try self.id_to_author.getOrPut(a.id);
            if (!k2a.found_existing) {
                // TODO: this might need to use a regular allocator not an
                // arena allocator
                k2a.value_ptr.* = AuthorList.init(alloc);
            }
            try k2a.value_ptr.append(
                .{ .id = a.creatorID, .order = a.orderIndex },
            );
        }
    }

    pub fn addOne(self: *Library) !*Item {
        return try self.items.addOne();
    }

    /// Get the Item by id
    pub fn getItem(self: *Library, id: usize) ?Item {
        const index = self.id_to_items.get(id) orelse return null;
        return self.items.items[index];
    }

    /// Get the attachement keys associated with an item id. Caller owns memory.
    pub fn getAttachments(
        self: *Library,
        allocator: std.mem.Allocator,
        id: usize,
    ) ![][]const u8 {
        var att_info = try self.db.prepare(ATTACHMENT_QUERY);
        defer att_info.deinit();

        var itt = try att_info.iterator(
            struct {
                itemID: usize,
            },
            .{ .parentItemID = id },
        );

        var list = std.ArrayList([]const u8).init(allocator);
        defer list.deinit();

        const alloc = self.arena.allocator();
        while (try itt.nextAlloc(alloc, .{})) |att| {
            const item = self.items.items[self.id_to_items.get(att.itemID).?];
            try list.append(item.key);
        }

        return list.toOwnedSlice();
    }

    /// Caller owns memory
    pub fn getAuthors(
        self: *Library,
        allocator: std.mem.Allocator,
        id: usize,
    ) ![]const Author {
        const authors = self.id_to_author.get(id) orelse
            return try allocator.alloc(Author, 0);

        var list = try allocator.alloc(Author, authors.items.len);
        errdefer allocator.free(list);

        for (authors.items) |author| {
            list[author.order] = self.author_id_to_author.get(author.id).?;
        }

        return list;
    }
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

    std.debug.print("Parsed {d} items.\n", .{
        lib.items.items.len,
    });

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

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // now that we have the author id's, we look up the items
            for (author_ids.items) |author_id| {
                const ids = lib.author_to_id.get(author_id).?;
                for (ids.items) |id| {
                    const item = lib.getItem(id).?;
                    const authors = try lib.getAuthors(alloc, id);
                    for (authors) |a| {
                        std.debug.print("{s} ", .{a.last});
                    }
                    std.debug.print("\n{any}: {s}\n", .{ item.pub_date, item.title });
                    const atts = try lib.getAttachments(alloc, id);
                    if (atts.len > 0) {
                        std.debug.print("zotero://open-pdf/library/items/{s}\n\n", .{atts[0]});
                    }
                }
            }
        },
    }
}
