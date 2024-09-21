const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const fuzzig = b.dependency("fuzzig", .{
        .target = target,
        .optimize = optimize,
    });
    const farbe = b.dependency("farbe", .{
        .target = target,
        .optimize = optimize,
    });
    const termui = b.dependency("termui", .{
        .target = target,
        .optimize = optimize,
    });
    const clippy = b.dependency("clippy", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zzot",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
    exe.root_module.addImport("fuzzig", fuzzig.module("fuzzig"));
    exe.root_module.addImport("farbe", farbe.module("farbe"));
    exe.root_module.addImport("termui", termui.module("termui"));
    exe.root_module.addImport("clippy", clippy.module("clippy"));

    // links the bundled sqlite3, so leave this out if you link the system one
    exe.linkLibrary(sqlite.artifact("sqlite"));

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
