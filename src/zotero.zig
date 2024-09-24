const std = @import("std");
const sqlite = @import("sqlite");
const zeit = @import("zeit");

const logger = std.log.scoped(.zotero);

fn parseDate(date: []const u8) !zeit.Time {
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
    modified_date: zeit.Time = .{},
};

const ITEM_INFO_QUERY =
    \\SELECT
    \\    items.itemID, items.itemTypeId, items.dateModified, items.key
    \\    FROM items
    \\    WHERE libraryID == 1
    \\;
;

const ITEM_FIELD_QUERY =
    \\SELECT itemID, fieldID, value FROM itemData
    \\    JOIN itemDataValues ON itemDataValues.valueID == itemData.valueID
    \\    WHERE "fieldID" in (1, 2, 6)
    \\;
;

const AUTHOR_LOOKUP_QUERY =
    \\SELECT creators.creatorID, firstName, lastName FROM creators;
;

const AUTHOR_QUERY =
    \\SELECT items.itemID, creatorID, orderIndex FROM items
    \\    JOIN itemCreators on items.itemID == itemCreators.itemID
    \\    WHERE libraryID == 1
    \\;
;

const ATTACHMENT_QUERY =
    \\SELECT
    \\    itemID, path FROM itemAttachments
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

        var item_iter = try item_info.iterator(struct {
            id: usize,
            itemTypeID: usize,
            dateModified: []const u8,
            key: []const u8,
        }, .{});

        const alloc = self.arena.allocator();

        try self.items.ensureTotalCapacity(10_000);
        try self.id_to_items.ensureTotalCapacity(10_000);

        while (try item_iter.nextAlloc(alloc, .{})) |n| {
            try self.id_to_items.put(n.id, self.items.items.len);
            const item = try self.addOne();
            // default initialize
            item.* = .{
                .id = n.id,
                .key = n.key,
                .modified_date = try parseDate(n.dateModified),
            };
        }

        logger.debug("ITEM_INFO_QUERY: done", .{});

        var item_field_info = try self.db.prepare(ITEM_FIELD_QUERY);
        defer item_field_info.deinit();

        var item_field_iter = try item_field_info.iterator(struct {
            id: usize,
            fieldID: usize,
            value: []const u8,
        }, .{});

        while (try item_field_iter.nextAlloc(alloc, .{})) |f| {
            const index = self.id_to_items.get(f.id) orelse
                continue;
            const item = &self.items.items[index];
            switch (f.fieldID) {
                1 => item.title = f.value,
                2 => item.abstract = f.value,
                6 => {
                    item.pub_date = try parseDate(f.value);
                },
                else => unreachable,
            }
        }

        logger.debug("ITEM_FIELD_QUERY: done", .{});
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

    pub const Attachment = struct {
        key: []const u8,
        path: []const u8,
    };

    /// Get the attachement keys associated with an item id. Caller owns memory.
    pub fn getAttachments(
        self: *Library,
        allocator: std.mem.Allocator,
        id: usize,
    ) ![]Attachment {
        var att_info = try self.db.prepare(ATTACHMENT_QUERY);
        defer att_info.deinit();

        var itt = try att_info.iterator(
            struct {
                itemID: usize,
                path: []const u8,
            },
            .{ .parentItemID = id },
        );

        var list = std.ArrayList(Attachment).init(allocator);
        defer list.deinit();

        const alloc = self.arena.allocator();
        while (try itt.nextAlloc(alloc, .{})) |att| {
            const item = self.items.items[self.id_to_items.get(att.itemID).?];
            try list.append(.{ .key = item.key, .path = att.path });
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
            list[author.order] = self.author_id_to_author.get(author.id) orelse {
                std.debug.print(">> id: {any}\n", .{author});
                unreachable;
            };
        }

        return list;
    }
};

/// Open a PDF inside of Zotero
pub fn openPdf(allocator: std.mem.Allocator, key: []const u8) !void {
    const query = try std.fmt.allocPrint(
        allocator,
        "zotero://open-pdf/library/items/{s}",
        .{key},
    );
    defer allocator.free(query);
    try executeUrl(allocator, query);
}

/// Select an item inside of Zotero
pub fn select(allocator: std.mem.Allocator, key: []const u8) !void {
    const query = try std.fmt.allocPrint(
        allocator,
        "zotero://select/library/items/{s}",
        .{key},
    );
    defer allocator.free(query);
    try executeUrl(allocator, query);
}

fn executeUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    var proc = std.process.Child.init(
        &.{ "zotero", "-url", url },
        allocator,
    );

    proc.stdin_behavior = std.process.Child.StdIo.Inherit;
    proc.stdout_behavior = std.process.Child.StdIo.Inherit;
    proc.stderr_behavior = std.process.Child.StdIo.Inherit;

    try proc.spawn();
    const term = try proc.wait();
    if (term != .Exited) return error.BadExit;
}
