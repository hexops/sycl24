# Step 01: create your Zig project

```
zig init
```

Delete the generated `src/root.zig` and `lib` steps in build.zig.

Add Mach:

```
zig fetch --save https://pkg.machengine.org/mach/3583e1754f9025edf74db868cbf5eda4bb2176f2.tar.gz
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
    @import("mach").link(mach_dep.builder, exe, &exe.root_module);
}
```

```
zig build run
```

![image](https://github.com/hexops/mach/assets/3173176/cb2a681e-e579-4dc0-b394-cca4889aa44e)

# Step 02: use mach.Core to create a window

Modify `src/main.zig` to use the `mach.Core` module and your own `Game` module:

```zig
const std = @import("std");
const mach = @import("mach");

const Game = @import("Game.zig");

// The global list of Mach modules registered for use in our application.
pub const modules = .{
    mach.Core,
    Game,
};

pub fn main() !void {
    // Initialize mach.Core
    try mach.core.initModule();

    // Main loop
    while (try mach.core.tick()) {}
}
```

Create the `src/Game.zig` module:

```zig
const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;

// Globally unique name of our module
pub const name = .game;

pub const Mod = mach.Mod(@This());

pub const global_events = .{
    // Listen for global init and tick events
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

In `src/Game.zig` register a listener for the global init event:

```zig
 pub const global_events = .{
+    .init = .{ .handler = init },
     .tick = .{ .handler = tick },
 };
```

Below that, add some state to our module as a struct field:

```zig
pipeline: *gpu.RenderPipeline,
```

Then create the `init` event handler, and add some boilerplate to load a shader module and create a render pipeline:

```zig
fn init(game: *Mod) !void {
    // Create our shader module
    const shader_module = mach.core.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
    defer shader_module.release();

    // Blend state describes how rendered colors get blended
    const blend = gpu.BlendState{};

    // Color target describes e.g. the pixel format of the window we are rendering to.
    const color_target = gpu.ColorTargetState{
        .format = mach.core.descriptor.format,
        .blend = &blend,
    };

    // Fragment state describes which shader and entrypoint to use for rendering fragments.
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    // Create our render pipeline that will ultimately get pixels onto the screen.
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vertex_main",
        },
    };
    const pipeline = mach.core.device.createRenderPipeline(&pipeline_descriptor);

    // Store our render pipeline in our module's state, so we can access it later on.
    game.init(.{
        .pipeline = pipeline,
    });
}
```

Modify your `pub fn tick` to have the `Game` module injected as a parameter:

```zig
-pub fn tick(core: *mach.Core.Mod) !void {
+pub fn tick(core: *mach.Core.Mod, game: *Mod) !void {
```

Then replace `// TODO: render stuff!` with some rendering code:

```zig
    // Create a command encoder
    const encoder = mach.core.device.createCommandEncoder(null);
    defer encoder.release();

    const sky_blue = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = sky_blue,
        .load_op = .clear,
        .store_op = .store,
    };
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
    });
    const pass = encoder.beginRenderPass(&render_pass_info);
    defer pass.release();
    pass.setPipeline(game.state().pipeline);
    pass.draw(3, 1, 0, 0);
    pass.end();

    // Submit our encoded commands to the GPU queue
    var command = encoder.finish(null);
    defer command.release();
    mach.core.queue.submit(&[_]*gpu.CommandBuffer{command});
```

```
zig build run
```

<img width="600" alt="image" src="https://github.com/hexops/mach/assets/3173176/b9358256-9365-4dc2-9bab-1c096e7f1eeb">
