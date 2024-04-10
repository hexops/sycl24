const std = @import("std");
const mach = @import("mach");

// Globally unique name of our module
pub const name = .game;

pub const Mod = mach.Mod(@This());

pub const global_events = .{
    // Listen for the global init event
    .init = .{ .handler = init },
};

pub fn init() void {
    std.debug.print("Hello, Mach!", .{});
}
