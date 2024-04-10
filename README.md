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
    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mach", mach_dep.module("mach"));
}
```
