const std = @import("std");
const sqlite = @import("sqlite");

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
const AUTHOR_QUERY =
    \\SELECT "key", "firstName", "lastName" FROM items
    \\    JOIN itemCreators on items.itemID == itemCreators.itemID
    \\    JOIN creators on creators.creatorID == itemCreators.creatorID
    \\    ORDER BY "key"
    \\;
;

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Library = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    authors: std.ArrayList(Author),
    key_to_author_indices: std.StringHashMap(Range),
    items: std.ArrayList(Item),
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
            .authors = std.ArrayList(Author).init(allocator),
            .key_to_author_indices = std.StringHashMap(Range).init(allocator),
            .items = std.ArrayList(Item).init(allocator),
            .db = db,
        };
    }

    pub fn deinit(self: *Library) void {
        self.arena.deinit();
        self.db.deinit();
        self.authors.deinit();
        self.key_to_author_indices.deinit();
        self.items.deinit();
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
        var author_info = try self.db.prepare(AUTHOR_QUERY);
        defer author_info.deinit();

        var author_iter = try author_info.iterator(struct {
            key: []const u8,
            first: []const u8,
            last: []const u8,
        }, .{});

        try self.key_to_author_indices.ensureTotalCapacity(10_000);

        var current_key: ?[]const u8 = null;
        var start: usize = 0;
        var end: usize = 0;

        const alloc = self.arena.allocator();
        while (try author_iter.nextAlloc(alloc, .{})) |a| {
            if (current_key == null) current_key = a.key;

            const author: Author = .{ .first = a.first, .last = a.last };
            try self.authors.append(author);

            if (!std.mem.eql(u8, current_key.?, a.key)) {
                current_key = a.key;
                try self.key_to_author_indices.put(
                    a.key,
                    .{ .start = start, .end = end },
                );
                start = end;
            }

            end += 1;
        }
    }

    pub fn addOne(self: *Library) !*Item {
        return try self.items.addOne();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var lib = try Library.init(allocator, "/home/lilith/Zotero/database.sqlite");
    defer lib.deinit();

    try lib.load();

    std.debug.print("Parsed {d} items.\n", .{
        lib.items.items.len,
    });

    // get just the last names
    const lastnames = try allocator.alloc([]const u8, lib.authors.items.len);
    defer allocator.free(lastnames);

    const indices = try allocator.alloc(usize, lib.authors.items.len);
    defer allocator.free(indices);

    for (0.., lastnames, lib.authors.items) |i, *last, author| {
        indices[i] = i;
        last.* = author.last;
    }
}
