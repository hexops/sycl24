const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;

// Globally unique name of our module
pub const name = .game;

pub const Mod = mach.Mod(@This());

pub const global_events = .{
    // Listen for global tick event
    .tick = .{ .handler = tick },
};

pub fn tick(core: *mach.Core.Mod) !void {
    // Poll for input events
    var iter = mach.core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .close => core.send(.exit, .{}), // tell mach.Core to exit the app
            else => {},
        }
    }

    // Grab the back buffer of the swapchain
    const back_buffer_view = mach.core.swap_chain.getCurrentTextureView().?;
    defer back_buffer_view.release();

    // TODO: render stuff!

    // Present the swapchain
    mach.core.swap_chain.present();
}
