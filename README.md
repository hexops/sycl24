## Step 01

Create your Zig project:

```
zig init
```

Delete the generated `src/root.zig` and `lib` steps in build.zig.

Add Mach:

```
zig fetch --save https://pkg.machengine.org/mach/3583e1754f9025edf74db868cbf5eda4bb2176f2.tar.gz
```

In your build.zig file add the `mach` dependency:

```
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

## Step 02

Modify `src/main.zig` to look like this, which gets us a window:

```
const std = @import("std");
const mach = @import("mach");

// The global list of Mach modules registered for use in our application.
pub const modules = .{
    mach.Core,
};

pub fn main() !void {
    // Initialize mach.Core
    try mach.core.initModule();

    // Main loop
    while (try mach.core.tick()) {}
}
```
