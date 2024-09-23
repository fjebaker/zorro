const std = @import("std");

const utils = @import("utils.zig");
const zotero = @import("zotero.zig");
const find = @import("find.zig");

const clippy = utils.clippy;
const Library = zotero.Library;

const ArgsHelp = clippy.Arguments(&.{});

const Commands = clippy.Commands(.{
    .commands = &.{
        .{ .name = "find", .args = find.Args },
        .{ .name = "help", .args = ArgsHelp },
    },
});

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
                try out.writeAll("Missing command\n");
                try Commands.writeHelp(out, .{});
                if (@import("builtin").mode != .Debug) {
                    std.process.exit(1);
                }
                return;
            },
            else => return err,
        }
    };

    // parse for help here before we try loading the library
    switch (parsed.commands) {
        .help => {
            const out = std.io.getStdOut().writer();
            try Commands.writeHelp(out, .{});
            return;
        },
        else => {},
    }

    const home_path = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_path);

    const zotero_path = try std.fs.path.joinZ(allocator, &.{ home_path, "Zotero" });
    defer allocator.free(zotero_path);

    var state = utils.State.init(allocator, zotero_path);
    defer state.deinit();
    const mirror_path = try state.makeMirrorDB();

    var lib = try Library.init(allocator, mirror_path);
    defer lib.deinit();
    try lib.load();

    try runCommand(parsed, &state, &lib);

    // let the OS cleanup
    if (@import("builtin").mode != .Debug) {
        std.process.exit(0);
    }
}

fn runCommand(parsed: Commands.Parsed, state: *utils.State, lib: *Library) !void {
    switch (parsed.commands) {
        .help => unreachable,
        .find => |args| {
            try find.run(args, state, lib);
        },
    }
}
