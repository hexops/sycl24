const std = @import("std");
const mach = @import("mach");
const ImGui = @import("mach-imgui");
const gpu = mach.gpu;

pub const name = .app;
pub const Mod = mach.Mod(@This());

pub const systems = .{
    .init = .{ .handler = init },
    .after_init = .{ .handler = afterInit },
    .deinit = .{ .handler = deinit },
    .tick = .{ .handler = tick },
};

f: f32 = 0.0,
color: [3]f32 = undefined,

pub fn deinit(core: *mach.Core.Mod) void {
    core.schedule(.deinit);
}

fn init(
    game: *Mod,
    core: *mach.Core.Mod,
) !void {
    core.schedule(.init);
    game.schedule(.after_init);
}

fn afterInit(core: *mach.Core.Mod, imgui: *ImGui.Mod, game: *Mod) !void {
    imgui.init(.{ .allocator = std.heap.page_allocator });
    try imgui.state().init(.{});
    game.init(.{});

    // Start the loop so we get .tick events
    core.schedule(.start);
}

fn tick(core: *mach.Core.Mod, game: *Mod, imgui: *ImGui.Mod) !void {
    var iter = mach.core.pollEvents();
    while (iter.next()) |event| {
        _ = ImGui.processEvent(event);
        switch (event) {
            .close => core.schedule(.exit), // Tell mach.Core to exit the app
            else => {},
        }
    }

    // Use Dear ImGUI
    const io = imgui.state().getIO();

    // Create an imgui window/frame
    try imgui.state().newFrame();

    // Add some text, a slider, a color editor, etc.
    ImGui.c.text("Hello, mach-imgui!");
    _ = ImGui.c.sliderFloat("float", &game.state().f, 0.0, 1.0);
    _ = ImGui.c.colorEdit3("color", &game.state().color, ImGui.c.ColorEditFlags_None);
    ImGui.c.text("Application average %.3f ms/frame (%.1f FPS)", 1000.0 / io.framerate, io.framerate);

    // Note: to show a demo window with at on of helpful ideas of what ImGui is capable of, uncomment this line:
    // ImGui.c.showDemoWindow(null);

    // Grab the back buffer of the swapchain
    const back_buffer_view = mach.core.swap_chain.getCurrentTextureView().?;
    defer back_buffer_view.release();

    // Create a command encoder
    const label = @tagName(name) ++ ".tick";
    const encoder = core.state().device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    // Begin render pass
    const sky_blue_background = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = sky_blue_background,
        .load_op = .clear,
        .store_op = .store,
    }};
    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));
    defer render_pass.release();

    // Draw imgui
    try imgui.state().render(render_pass);

    // Finish render pass
    render_pass.end();

    // Submit our commands to the queue
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    core.state().queue.submit(&[_]*gpu.CommandBuffer{command});

    // Present the frame
    core.schedule(.present_frame);
}
