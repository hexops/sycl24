const std = @import("std");
const zigimg = @import("zigimg");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;

const loader = @import("loader.zig");

const vec2 = math.vec2;
const vec3 = math.vec3;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

timer: mach.Timer,
player: mach.EntityID,
direction: Vec2 = vec2(0, 0),
spawning: bool = false,
spawn_timer: mach.Timer,
fps_timer: mach.Timer,
frame_count: usize,
sprites: usize,
rand: std.rand.DefaultPrng,
time: f32,
allocator: std.mem.Allocator,
pipeline: mach.EntityID,
frame_encoder: *gpu.CommandEncoder = undefined,
frame_render_pass: *gpu.RenderPassEncoder = undefined,

// Define the globally unique name of our module. You can use any name here, but keep in mind no
// two modules in the program can have the same name.
pub const name = .app;
pub const Mod = mach.Mod(@This());

pub const systems = .{
    .init = .{ .handler = init },
    .deinit = .{ .handler = deinit },
    .after_init = .{ .handler = afterInit },
    .tick = .{ .handler = tick },
    .end_frame = .{ .handler = endFrame },
};

fn deinit(
    core: *mach.Core.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
) !void {
    sprite_pipeline.schedule(.deinit);
    core.schedule(.deinit);
}

fn init(
    core: *mach.Core.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    game: *Mod,
) !void {
    core.schedule(.init);
    sprite_pipeline.schedule(.init);
    game.schedule(.after_init);
}

fn afterInit(
    entities: *mach.Entities.Mod,
    core: *mach.Core.Mod,
    sprite: *gfx.Sprite.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    game: *Mod,
) !void {
    // We can create entities, and set components on them. Note that components live in a module
    // namespace, e.g. the `.mach_gfx_sprite` module could have a 3D `.location` component with a different
    // type than the `.physics2d` module's `.location` component if you desire.

    // Create a sprite rendering pipeline
    const allocator = gpa.allocator();
    const pipeline = try entities.new();
    try sprite_pipeline.set(pipeline, .texture, try loadTexture(core, allocator));
    sprite_pipeline.schedule(.update);

    const atlas = try loader.Atlas.initFromFile(std.heap.c_allocator, "src/assets/spritesheet.atlas");
    // defer atlas.deinit(std.testing.allocator);
    std.debug.print("loaded sprite atlas: {} sprites, {} animations\n", .{ atlas.sprites.len, atlas.animations.len });
    for (atlas.sprites) |sprite_info| {
        std.debug.print("sprite: {s} origin={any} source={any}\n", .{ sprite_info.name, sprite_info.origin, sprite_info.source });
    }

    // Create our player sprite
    const player = try entities.new();
    try sprite.set(player, .transform, Mat4x4.translate(vec3(-0.02, 0, 0)));
    try sprite.set(player, .size, vec2(128, 128));
    try sprite.set(player, .uv_transform, Mat3x3.translate(vec2(0, 0)));
    try sprite.set(player, .pipeline, pipeline);
    sprite.schedule(.update);

    game.init(.{
        .timer = try mach.Timer.start(),
        .spawn_timer = try mach.Timer.start(),
        .player = player,
        .fps_timer = try mach.Timer.start(),
        .frame_count = 0,
        .sprites = 0,
        .rand = std.rand.DefaultPrng.init(1337),
        .time = 0,
        .allocator = allocator,
        .pipeline = pipeline,
    });

    core.schedule(.start);
}

fn tick(
    entities: *mach.Entities.Mod,
    core: *mach.Core.Mod,
    sprite: *gfx.Sprite.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    game: *Mod,
) !void {
    var iter = mach.core.pollEvents();
    var direction = game.state().direction;
    var spawning = game.state().spawning;
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] -= 1,
                    .right => direction.v[0] += 1,
                    .up => direction.v[1] += 1,
                    .down => direction.v[1] -= 1,
                    .space => spawning = true,
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] += 1,
                    .right => direction.v[0] -= 1,
                    .up => direction.v[1] -= 1,
                    .down => direction.v[1] += 1,
                    .space => spawning = false,
                    else => {},
                }
            },
            .close => core.schedule(.exit),
            else => {},
        }
    }
    game.state().direction = direction;
    game.state().spawning = spawning;

    var player_transform = sprite.get(game.state().player, .transform).?;
    var player_pos = player_transform.translation();
    if (spawning and game.state().spawn_timer.read() > 1.0 / 60.0) {
        // Spawn new entities
        _ = game.state().spawn_timer.lap();
        for (0..100) |_| {
            var new_pos = player_pos;
            new_pos.v[0] += game.state().rand.random().floatNorm(f32) * 25;
            new_pos.v[1] += game.state().rand.random().floatNorm(f32) * 25;

            const new_entity = try entities.new();
            try sprite.set(new_entity, .transform, Mat4x4.translate(new_pos).mul(&Mat4x4.scale(Vec3.splat(0.3))));
            try sprite.set(new_entity, .size, vec2(32, 32));
            try sprite.set(new_entity, .uv_transform, Mat3x3.translate(vec2(0, 0)));
            try sprite.set(new_entity, .pipeline, game.state().pipeline);
            game.state().sprites += 1;
        }
    }

    // Multiply by delta_time to ensure that movement is the same speed regardless of the frame rate.
    const delta_time = game.state().timer.lap();

    // Rotate entities
    var q = try entities.query(.{
        .transforms = gfx.Sprite.Mod.write(.transform),
    });
    while (q.next()) |v| {
        for (v.transforms) |*entity_transform| {
            const location = entity_transform.*.translation();
            // var transform = entity_transform.mul(&Mat4x4.translate(-location));
            // transform = mat.rotateZ(0.3 * delta_time).mul(&transform);
            // transform = transform.mul(&Mat4x4.translate(location));
            var transform = Mat4x4.ident;
            transform = transform.mul(&Mat4x4.translate(location));
            transform = transform.mul(&Mat4x4.rotateZ(2 * math.pi * game.state().time));
            transform = transform.mul(&Mat4x4.scaleScalar(@min(math.cos(game.state().time / 2.0), 0.5)));
            entity_transform.* = transform;
        }
    }

    // Calculate the player position, by moving in the direction the player wants to go
    // by the speed amount.
    const speed = 200.0;
    player_pos.v[0] += direction.x() * speed * delta_time;
    player_pos.v[1] += direction.y() * speed * delta_time;
    try sprite.set(game.state().player, .transform, Mat4x4.translate(player_pos));
    sprite.schedule(.update);

    // Perform pre-render work
    sprite_pipeline.schedule(.pre_render);

    // Create a command encoder for this frame
    const label = @tagName(name) ++ ".tick";
    game.state().frame_encoder = core.state().device.createCommandEncoder(&.{ .label = label });

    // Grab the back buffer of the swapchain
    const back_buffer_view = mach.core.swap_chain.getCurrentTextureView().?;
    defer back_buffer_view.release();

    // Begin render pass
    const sky_blue = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = sky_blue,
        .load_op = .clear,
        .store_op = .store,
    }};
    game.state().frame_render_pass = game.state().frame_encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));

    // Render our sprite batch
    sprite_pipeline.state().render_pass = game.state().frame_render_pass;
    sprite_pipeline.schedule(.render);

    // Finish the frame once rendering is done.
    game.schedule(.end_frame);

    game.state().time += delta_time;
}

fn endFrame(game: *Mod, core: *mach.Core.Mod) !void {
    // Finish render pass
    game.state().frame_render_pass.end();
    const label = @tagName(name) ++ ".endFrame";
    var command = game.state().frame_encoder.finish(&.{ .label = label });
    core.state().queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    game.state().frame_encoder.release();
    game.state().frame_render_pass.release();

    // Present the frame
    core.schedule(.present_frame);

    // Every second, update the window title with the FPS
    if (game.state().fps_timer.read() >= 1.0) {
        try mach.Core.printTitle(
            core,
            core.state().main_window,
            "sprite [ FPS: {d} ] [ Sprites: {d} ]",
            .{ game.state().frame_count, game.state().sprites },
        );
        core.schedule(.update);
        game.state().fps_timer.reset();
        game.state().frame_count = 0;
    }
    game.state().frame_count += 1;
}

fn loadTexture(core: *mach.Core.Mod, allocator: std.mem.Allocator) !*gpu.Texture {
    const device = core.state().device;
    const queue = core.state().queue;

    // Load the image from memory
    var img = try zigimg.Image.fromMemory(allocator, @embedFile("assets/spritesheet.png"));
    defer img.deinit();
    const img_size = gpu.Extent3D{ .width = @as(u32, @intCast(img.width)), .height = @as(u32, @intCast(img.height)) };

    // Create a GPU texture
    const label = @tagName(name) ++ ".loadTexture";
    const texture = device.createTexture(&.{
        .label = label,
        .size = img_size,
        .format = .rgba8_unorm,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
            .render_attachment = true,
        },
    });
    const data_layout = gpu.Texture.DataLayout{
        .bytes_per_row = @as(u32, @intCast(img.width * 4)),
        .rows_per_image = @as(u32, @intCast(img.height)),
    };
    switch (img.pixels) {
        .rgba32 => |pixels| queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, pixels),
        .rgb24 => |pixels| {
            const data = try rgb24ToRgba32(allocator, pixels);
            defer data.deinit(allocator);
            queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, data.rgba32);
        },
        else => @panic("unsupported image color format"),
    }
    return texture;
}

fn rgb24ToRgba32(allocator: std.mem.Allocator, in: []zigimg.color.Rgb24) !zigimg.color.PixelStorage {
    const out = try zigimg.color.PixelStorage.init(allocator, .rgba32, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        out.rgba32[i] = zigimg.color.Rgba32{ .r = in[i].r, .g = in[i].g, .b = in[i].b, .a = 255 };
    }
    return out;
}
