const std = @import("std");
const sqlite = @import("sqlite");
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
    key: []const u8,
    title: []const u8,
    abstract: []const u8,
};

const ITEM_INFO_QUERY =
    \\SELECT "key", "value", "fieldID" FROM items
    \\    JOIN itemTypes on items.itemTypeID == itemTypes.itemTypeID
    \\    RIGHT JOIN itemData on items.itemID == itemData.itemID
    \\    JOIN itemDataValues on itemData.valueID == itemDataValues.valueID
    \\    WHERE "fieldID" in (1, 2)
    \\    ORDER BY "key"
    \\;
;

// TODO: would be better to store the author indexes and a lookup
const AUTHOR_LOOKUP_QUERY =
    \\SELECT "creatorID", "firstName", "lastName" FROM creators;
;
const AUTHOR_QUERY =
    \\SELECT "key", "creatorID", "orderIndex" FROM items
    \\    JOIN itemCreators on items.itemID == itemCreators.itemID
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
    const KeyList = std.ArrayList([]const u8);

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    id_to_author: AuthorMap,

    // keep a bi-directional mapping from key to authors and vice versa
    key_to_author: std.StringHashMap(AuthorList),
    author_to_key: std.AutoArrayHashMap(usize, KeyList),

    items: std.ArrayList(Item),
    // gives the index into the items array of the key
    key_to_items: std.StringHashMap(usize),

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
            .id_to_author = AuthorMap.init(allocator),
            .key_to_author = std.StringHashMap(AuthorList).init(allocator),
            .author_to_key = std.AutoArrayHashMap(usize, KeyList).init(allocator),
            .items = std.ArrayList(Item).init(allocator),
            .key_to_items = std.StringHashMap(usize).init(allocator),
            .db = db,
        };
    }

    pub fn deinit(self: *Library) void {
        self.arena.deinit();
        self.db.deinit();
        self.id_to_author.deinit();
        self.key_to_author.deinit();
        self.author_to_key.deinit();
        self.items.deinit();
        self.key_to_items.deinit();
        self.* = undefined;
    }

    /// Query and parse relevant information from the database to represent the
    /// library in memory
    pub fn load(self: *Library) !void {
        try self.loadAuthors();

        var item_info = try self.db.prepare(ITEM_INFO_QUERY);
        defer item_info.deinit();

        var current_key: ?[]const u8 = null;

        var item: *Item = undefined;
        var item_iter = try item_info.iterator(struct {
            key: []const u8,
            value: []const u8,
            fieldID: usize,
        }, .{});

        const alloc = self.arena.allocator();
        while (try item_iter.nextAlloc(alloc, .{})) |n| {
            if (current_key == null or !std.mem.eql(u8, current_key.?, n.key)) {
                current_key = n.key;
                try self.key_to_items.put(n.key, self.items.items.len);
                item = try self.addOne();
            }

            switch (n.fieldID) {
                1 => item.title = n.value,
                2 => item.abstract = n.value,
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
        try self.id_to_author.ensureTotalCapacity(10_000);

        const alloc = self.arena.allocator();
        while (try author_iter.nextAlloc(alloc, .{})) |a| {
            const author: Author = .{
                .first = a.first,
                .last = a.last,
            };
            try self.id_to_author.put(a.creatorID, author);
        }

        // then we build the key to author lookup tables
        var author_info = try self.db.prepare(AUTHOR_QUERY);
        defer author_info.deinit();

        var iter = try author_info.iterator(struct {
            key: []const u8,
            creatorID: usize,
            orderIndex: usize,
        }, .{});

        // again ensure capacity
        try self.author_to_key.ensureTotalCapacity(10_000);
        try self.key_to_author.ensureTotalCapacity(10_000);

        while (try iter.nextAlloc(alloc, .{})) |a| {
            const a2k = try self.author_to_key.getOrPut(a.creatorID);
            if (!a2k.found_existing) {
                // TODO: this might need to use a regular allocator not an
                // arena allocator
                a2k.value_ptr.* = KeyList.init(alloc);
            }
            try a2k.value_ptr.append(a.key);

            const k2a = try self.key_to_author.getOrPut(a.key);
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

    pub fn getItemByKey(self: *Library, key: []const u8) ?Item {
        const index = self.key_to_items.get(key) orelse return null;
        return self.items.items[index];
    }

    /// Caller owns memory
    pub fn getAuthorsByKey(
        self: *Library,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !?[]const Author {
        const authors = self.key_to_author.get(key) orelse return null;

        var list = try allocator.alloc(Author, authors.items.len);
        errdefer allocator.free(list);

        for (authors.items) |author| {
            list[author.order] = self.id_to_author.get(author.id).?;
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
            // get just the last names
            // const lastnames = try allocator.alloc([]const u8, lib.authors.items.len);
            // defer allocator.free(lastnames);

            // const indices = try allocator.alloc(usize, lib.authors.items.len);
            // defer allocator.free(indices);

            // for (0.., lastnames, lib.authors.items) |i, *last, author| {
            //     indices[i] = i;
            //     last.* = author.last;
            // }

            var author_ids = std.ArrayList(usize).init(allocator);
            defer author_ids.deinit();

            var itt = lib.id_to_author.iterator();
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
                const keys = lib.author_to_key.get(author_id).?;
                for (keys.items) |key| {
                    const item = lib.getItemByKey(key).?;
                    const authors = (try lib.getAuthorsByKey(alloc, key)).?;
                    for (authors) |a| {
                        std.debug.print("{s} ", .{a.last});
                    }
                    std.debug.print("\n{s}\n\n", .{item.title});
                }
            }

            // for (lastnames) |name| {
            //     if (std.mem.containsAtLeast(u8, name, 1, args.author.?)) {
            //         std.debug.print("> {s}\n", .{name});
            //     }
            // }
        },
    }
}
