const std = @import("std");
const mach = @import("mach");
const zigimg = @import("zigimg");
const assets = @import("assets");
const gpu = mach.gpu;

pub const name = .app;
pub const Mod = mach.Mod(@This());

pub const systems = .{
    .init = .{ .handler = init },
    .after_init = .{ .handler = afterInit },
    .deinit = .{ .handler = deinit },
    .tick = .{ .handler = tick },
};

pipeline: *gpu.RenderPipeline,
vertex_buffer: *gpu.Buffer,
index_buffer: *gpu.Buffer,
bind_group: *gpu.BindGroup,

pub fn deinit(core: *mach.Core.Mod, game: *Mod) void {
    game.state().pipeline.release();
    core.schedule(.deinit);
}

fn init(game: *Mod, core: *mach.Core.Mod) !void {
    core.schedule(.init);
    game.schedule(.after_init);
}

fn afterInit(game: *Mod, core: *mach.Core.Mod) !void {
    // Create our shader module
    const shader_module = core.state().device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
    defer shader_module.release();

    // Blend state describes how rendered colors get blended
    const blend = gpu.BlendState{};

    // Color target describes e.g. the pixel format of the window we are rendering to.
    const color_target = gpu.ColorTargetState{
        .format = core.get(core.state().main_window, .framebuffer_format).?,
        .blend = &blend,
    };

    // Fragment state describes which shader and entrypoint to use for rendering fragments.
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    // Create Vertex buffer layout
    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "position"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &vertex_attributes,
    });

    // Create our render pipeline that will ultimately get pixels onto the screen.
    const pipeline = core.state().device.createRenderPipeline(&.{
        .label = @tagName(name) ++ ".init",
        .fragment = &fragment,
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vertex_main",
            .buffers = &[_]gpu.VertexBufferLayout{vertex_buffer_layout},
        }),
    });

    // Create Vertex buffer
    const vertex_buffer = mach.core.device.createBuffer(&.{
        .usage = .{ .vertex = true },
        .size = @sizeOf(Vertex) * vertices.len,
        .mapped_at_creation = .true,
    });
    const vertex_mapped = vertex_buffer.getMappedRange(Vertex, 0, vertices.len);
    @memcpy(vertex_mapped.?, vertices[0..]);
    vertex_buffer.unmap();

    const index_buffer = mach.core.device.createBuffer(&.{
        .usage = .{ .index = true },
        .size = @sizeOf(u32) * index_data.len,
        .mapped_at_creation = .true,
    });
    const index_mapped = index_buffer.getMappedRange(u32, 0, index_data.len);
    @memcpy(index_mapped.?, index_data[0..]);
    index_buffer.unmap();

    // Create Texture
    var img = try zigimg.Image.fromMemory(mach.core.allocator, @embedFile("assets/gotta-go-fast.png"));
    defer img.deinit();
    const img_size = gpu.Extent3D{
        .width = @as(u32, @intCast(img.width)),
        .height = @as(u32, @intCast(img.height)),
    };

    const texture = mach.core.device.createTexture(&.{
        .size = img_size,
        .format = .rgba8_unorm,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
            .render_attachment = true,
        },
    });
    defer texture.release();

    const data_layout = gpu.Texture.DataLayout{
        .bytes_per_row = @as(u32, @intCast(img.width * 4)),
        .rows_per_image = @as(u32, @intCast(img.height)),
    };
    switch (img.pixels) {
        .rgba32 => |pixels| mach.core.queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, pixels),
        .rgb24 => |pixels| {
            const data = try rgb24ToRgba32(mach.core.allocator, pixels);
            defer data.deinit(mach.core.allocator);
            mach.core.queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, data.rgba32);
        },
        else => @panic("unsupported image color format"),
    }

    const sampler = mach.core.device.createSampler(&.{ .mag_filter = .linear, .min_filter = .linear });
    defer sampler.release();

    const texture_view = texture.createView(&gpu.TextureView.Descriptor{});
    defer texture_view.release();

    const bind_group_layout = pipeline.getBindGroupLayout(0);
    defer bind_group_layout.release();

    const bind_group = mach.core.device.createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .layout = bind_group_layout,
            .entries = &.{
                gpu.BindGroup.Entry.sampler(0, sampler),
                gpu.BindGroup.Entry.textureView(1, texture_view),
            },
        }),
    );

    // Store our render pipeline in our module's state, so we can access it later on.
    game.init(.{
        .pipeline = pipeline,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .bind_group = bind_group,
    });

    // Start the loop so we get .tick events
    core.schedule(.start);
}

fn tick(core: *mach.Core.Mod, game: *Mod) !void {
    var iter = mach.core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .close => core.schedule(.exit), // Tell mach.Core to exit the app
            else => {},
        }
    }

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

    // Draw
    render_pass.setPipeline(game.state().pipeline);
    render_pass.setVertexBuffer(0, game.state().vertex_buffer, 0, @sizeOf(Vertex) * vertices.len);
    render_pass.setIndexBuffer(game.state().index_buffer, .uint32, 0, @sizeOf(u32) * index_data.len);
    render_pass.setBindGroup(0, game.state().bind_group, &.{});
    render_pass.drawIndexed(index_data.len, 1, 0, 0, 0);

    // Finish render pass
    render_pass.end();

    // Submit our commands to the queue
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    core.state().queue.submit(&[_]*gpu.CommandBuffer{command});

    // Present the frame
    core.schedule(.present_frame);
}

const Vertex = extern struct {
    position: @Vector(2, f32),
    uv: @Vector(2, f32),
};
const vertices = [_]Vertex{
    .{ .position = .{ -0.5, -0.5 }, .uv = .{ 1, 1 } },
    .{ .position = .{ 0.5, -0.5 }, .uv = .{ 0, 1 } },
    .{ .position = .{ 0.5, 0.5 }, .uv = .{ 0, 0 } },
    .{ .position = .{ -0.5, 0.5 }, .uv = .{ 1, 0 } },
};
const index_data = [_]u32{ 0, 1, 2, 2, 3, 0 };

fn rgb24ToRgba32(allocator: std.mem.Allocator, in: []zigimg.color.Rgb24) !zigimg.color.PixelStorage {
    const out = try zigimg.color.PixelStorage.init(allocator, .rgba32, in.len);
    for (in, out.rgba32) |in_pixel, *out_pixel| {
        out_pixel.* = zigimg.color.Rgba32{ .r = in_pixel.r, .g = in_pixel.g, .b = in_pixel.b, .a = 255 };
    }
    return out;
}
