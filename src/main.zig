const std = @import("std");
const sqlite = @import("sqlite");

pub const Author = struct {
    first: []const u8,
    last: []const u8,
};

pub const Item = struct {
    key: []const u8,
    authors: []Author,
    title: []const u8,
    abstract: []const u8,
};

pub const Collection = struct {
    arena: std.heap.ArenaAllocator,
    authors: std.ArrayList(Author),
    items: std.ArrayList(Item),

    pub fn init(allocator: std.mem.Allocator) Collection {
        const arena = std.heap.ArenaAllocator.init(allocator);
        return .{
            .arena = arena,
            .authors = std.ArrayList(Author).init(allocator),
            .items = std.ArrayList(Item).init(allocator),
        };
    }

    pub fn addOne(self: *Collection) !*Item {
        return try self.items.addOne();
    }

    pub fn deinit(self: *Collection) void {
        self.arena.deinit();
        self.authors.deinit();
        self.items.deinit();
        self.* = undefined;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = "/home/lilith/Zotero/database.sqlite" },
        .open_flags = .{
            .write = false,
            .create = false,
        },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    const query =
        \\SELECT "key" FROM items;
    ;
    var stmt = try db.prepare(query);
    defer stmt.deinit();

    var coll = Collection.init(allocator);
    defer coll.deinit();
    const alloc = coll.arena.allocator();

    const keys = try stmt.all([]const u8, alloc, .{}, .{});
    _ = keys;

    const ITEM_INFO_QUERY =
        \\SELECT "key", "value", "fieldID" FROM items
        \\    JOIN itemTypes on items.itemTypeID == itemTypes.itemTypeID
        \\    RIGHT JOIN itemData on items.itemID == itemData.itemID
        \\    JOIN itemDataValues on itemData.valueID == itemDataValues.valueID
        \\    WHERE "fieldID" in (1, 2)
        \\    ORDER BY "key"
        \\;
    ;

    const AUTHOR_QUERY =
        \\SELECT "key", "firstName", "lastName" FROM items
        \\    JOIN itemCreators on items.itemID == itemCreators.itemID
        \\    JOIN creators on creators.creatorID == itemCreators.creatorID
        \\    ORDER BY "key"
        \\;
    ;

    var item_info = try db.prepare(ITEM_INFO_QUERY);
    defer item_info.deinit();

    var author_info = try db.prepare(AUTHOR_QUERY);
    defer author_info.deinit();

    var author_iter = try item_info.iterator(struct {
        key: []const u8,
        first: []const u8,
        last: []const u8,
    }, .{});

    var author_end_indices = try std.ArrayList(usize).initCapacity(allocator, 10_000);
    defer author_end_indices.deinit();

    var current_key: ?[]const u8 = null;
    var author_end: usize = 0;

    while (try author_iter.nextAlloc(alloc, .{})) |a| {
        if (current_key == null) current_key = a.key;

        const author: Author = .{ .first = a.first, .last = a.last };
        try coll.authors.append(author);

        if (!std.mem.eql(u8, current_key.?, a.key)) {
            current_key = a.key;
            try author_end_indices.append(author_end);
        }

        author_end += 1;
    }
    try author_end_indices.append(author_end);

    current_key = null;
    var item: *Item = undefined;
    var item_iter = try item_info.iterator(struct {
        key: []const u8,
        value: []const u8,
        fieldID: usize,
    }, .{});

    var author_start: usize = 0;
    var index: usize = 0;

    while (try item_iter.nextAlloc(alloc, .{})) |n| {
        if (current_key == null or !std.mem.eql(u8, current_key.?, n.key)) {
            current_key = n.key;
            item = try coll.addOne();

            const end = author_end_indices.items[index];
            item.authors = coll.authors.items[author_start..end];

            author_start = end;
            index += 1;
        }

        switch (n.fieldID) {
            1 => item.title = n.value,
            2 => item.abstract = n.value,
            else => unreachable,
        }
    }

    std.debug.print("Parsed {d} items.\n", .{
        coll.items.items.len,
    });
}
