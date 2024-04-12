const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const imgui = b.dependency("imgui", .{});
    const mach_dep = b.dependency("mach", .{ .target = target, .optimize = optimize });

    const mach_imgui = b.addModule("mach_imgui", .{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    mach_imgui.addImport("mach", mach_dep.module("mach"));
    mach_imgui.addCSourceFile(.{ .file = .{ .path = "src/cimgui.cpp" }, .flags = &.{} });
    mach_imgui.addCSourceFile(.{ .file = imgui.path("imgui.cpp"), .flags = &.{} });
    mach_imgui.addCSourceFile(.{ .file = imgui.path("imgui_widgets.cpp"), .flags = &.{} });
    mach_imgui.addCSourceFile(.{ .file = imgui.path("imgui_tables.cpp"), .flags = &.{} });
    mach_imgui.addCSourceFile(.{ .file = imgui.path("imgui_draw.cpp"), .flags = &.{} });
    mach_imgui.addCSourceFile(.{ .file = imgui.path("imgui_demo.cpp"), .flags = &.{} });
    mach_imgui.addIncludePath(imgui.path("."));
    mach_imgui.addIncludePath(.{ .path = "src" });
}
