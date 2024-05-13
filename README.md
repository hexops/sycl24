# Install / download software

* [VLC media player](https://www.videolan.org/) - or something that can play `.opus` audio files.
* Zig `<TODO specific version>`
* Zig editor extension, configure it to use ZLS `<TODO specific version>`

# Step 01: create your Zig project

```
zig init
```

Delete the generated `src/root.zig` and `lib` steps in build.zig.

Add Mach:

```
zig fetch --save https://pkg.machengine.org/mach/205a1f33db0efe40a218e793937e7b686ac117dc.tar.gz
```

In your build.zig file add the `mach` dependency:

```zig
pub fn build(b: *std.Build) void {
    // ...

    // Add Mach dependency
    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mach", mach_dep.module("mach"));
    @import("mach").link(mach_dep.builder, exe);
}
```

```
zig build run
```

![image](https://github.com/hexops/mach/assets/3173176/cb2a681e-e579-4dc0-b394-cca4889aa44e)

# Step 02: use mach.Core to create a window

Modify `src/main.zig` to use the `mach.Core` module and your own `Game` module:

```zig
const mach = @import("mach");

// The global list of Mach modules registered for use in our application.
pub const modules = .{
    mach.Core,
    @import("App.zig"),
};

pub fn main() !void {
    // Initialize mach.Core
    try mach.core.initModule();

    // Main loop
    while (try mach.core.tick()) {}
}
```

Create the `src/App.zig` module:

```zig
const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;

pub const name = .app;
pub const Mod = mach.Mod(@This());

pub const systems = .{
    .init = .{ .handler = init },
    .after_init = .{ .handler = afterInit },
    .deinit = .{ .handler = deinit },
    .tick = .{ .handler = tick },
};

pub fn deinit(core: *mach.Core.Mod) void {
    core.schedule(.deinit);
}

fn init(game: *Mod, core: *mach.Core.Mod) !void {
    core.schedule(.init);
    game.schedule(.after_init);
}

fn afterInit(core: *mach.Core.Mod) !void {
    // TODO: use the GPU to initialize resources

    // Start the loop so we get .tick events
    core.schedule(.start);
}

fn tick(core: *mach.Core.Mod) !void {
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

    // TODO: Draw things!

    // Finish render pass
    render_pass.end();

    // Submit our commands to the queue
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    core.state().queue.submit(&[_]*gpu.CommandBuffer{command});

    // Present the frame
    core.schedule(.present_frame);
}
```

```
zig build run
```

<img width="600" alt="image" src="https://github.com/hexops/mach/assets/3173176/abcfbc2d-8de2-41f9-88bd-cc702e498f56">

# Step 03: render a triangle

Create `src/shader.wgsl`:

```zig
@vertex fn vertex_main(
    @builtin(vertex_index) VertexIndex : u32
) -> @builtin(position) vec4<f32> {
    var pos = array<vec2<f32>, 3>(
        vec2<f32>( 0.0,  0.5),
        vec2<f32>(-0.5, -0.5),
        vec2<f32>( 0.5, -0.5)
    );
    return vec4<f32>(pos[VertexIndex], 0.0, 1.0);
}

@fragment fn frag_main() -> @location(0) vec4<f32> {
    return vec4<f32>(0.247, 0.608, 0.043, 1.0);
}
```

See `step-03/src/shader.zig` for some code comments.

We'll modify `src/App.zig` like this:

```diff
const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;

pub const name = .app;
pub const Mod = mach.Mod(@This());

pub const systems = .{
    .init = .{ .handler = init },
    .after_init = .{ .handler = afterInit },
    .deinit = .{ .handler = deinit },
    .tick = .{ .handler = tick },
};

+pipeline: *gpu.RenderPipeline,

-pub fn deinit(core: *mach.Core.Mod) void {
+pub fn deinit(core: *mach.Core.Mod, game: *Mod) void {
+    game.state().pipeline.release();
    core.schedule(.deinit);
}

fn init(game: *Mod, core: *mach.Core.Mod) !void {
    core.schedule(.init);
    game.schedule(.after_init);
}

-fn afterInit(core: *mach.Core.Mod) !void {
-    // TODO: use the GPU to initialize resources
+fn afterInit(game: *Mod, core: *mach.Core.Mod) !void {
+    // Create our shader module
+    const shader_module = core.state().device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
+    defer shader_module.release();

+    // Blend state describes how rendered colors get blended
+    const blend = gpu.BlendState{};

+    // Color target describes e.g. the pixel format of the window we are rendering to.
+    const color_target = gpu.ColorTargetState{
+        .format = core.get(core.state().main_window, .framebuffer_format).?,
+        .blend = &blend,
+    };

+    // Fragment state describes which shader and entrypoint to use for rendering fragments.
+    const fragment = gpu.FragmentState.init(.{
+        .module = shader_module,
+        .entry_point = "frag_main",
+        .targets = &.{color_target},
+    });

+    // Create our render pipeline that will ultimately get pixels onto the screen.
+    const label = @tagName(name) ++ ".init";
+    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
+        .label = label,
+        .fragment = &fragment,
+        .vertex = gpu.VertexState{
+            .module = shader_module,
+            .entry_point = "vertex_main",
+        },
+    };
+    const pipeline = core.state().device.createRenderPipeline(&pipeline_descriptor);

+    // Store our render pipeline in our module's state, so we can access it later on.
+    game.init(.{
+        .pipeline = pipeline,
+    });

    // Start the loop so we get .tick events
    core.schedule(.start);
}

-fn tick(core: *mach.Core.Mod) !void {
+fn tick(core: *mach.Core.Mod, game: *Mod) !void {
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

-    // TODO: Draw things!
+    // Draw
+    render_pass.setPipeline(game.state().pipeline);
+    render_pass.draw(3, 1, 0, 0);

    // Finish render pass
    render_pass.end();

    // Submit our commands to the queue
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    core.state().queue.submit(&[_]*gpu.CommandBuffer{command});

    // Present the frame
    core.schedule(.present_frame);
}
```

```
zig build run
```

<img width="600" alt="image" src="https://github.com/hexops/mach/assets/3173176/b9358256-9365-4dc2-9bab-1c096e7f1eeb">

## Step 04: Imgui briefing

```
zig fetch --save https://github.com/slimsag/mach-imgui/archive/9ab7acbd7e3a9cb30fdba11831d725d04377c0df.tar.gz
```

## Next steps

https://github.com/hexops/mach/tree/main/examples
