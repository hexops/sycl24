const std = @import("std");
pub const c = @import("cimgui.zig");
const mach = @import("mach");
const core = mach.core;
const gpu = core.gpu;

pub const name = .imgui;

pub const Mod = mach.Mod(@This());

pub const components = .{
    .text = .{ .type = []const u8 },
};

allocator: std.mem.Allocator,

pub const InitOptions = struct {
    font_data: ?[]const u8 = null,
    max_frames_in_flight: u32 = 3,
    color_format: ?gpu.Texture.Format = null, // uses swap chain format if null
    depth_stencil_format: gpu.Texture.Format = .undefined,
    mag_filter: gpu.FilterMode = .linear,
    min_filter: gpu.FilterMode = .linear,
    mipmap_filter: gpu.MipmapFilterMode = .linear,
};

pub fn init(imgui: *@This(), options: InitOptions) !void {
    _ = c.createContext(null);
    c.setZigAllocator(&imgui.allocator);

    var io = c.getIO();
    std.debug.assert(io.backend_platform_user_data == null);
    std.debug.assert(io.backend_renderer_user_data == null);
    io.ini_filename = null;

    const brp = try imgui.allocator.create(BackendPlatformData);
    brp.* = BackendPlatformData.init();
    io.backend_platform_user_data = brp;

    const brd = try imgui.allocator.create(BackendRendererData);
    brd.* = BackendRendererData.init(core.device, options);
    io.backend_renderer_user_data = brd;

    if (options.font_data) |font_data| {
        io.config_flags |= c.ConfigFlags_NavEnableKeyboard;
        io.font_global_scale = 1.0 / io.display_framebuffer_scale.y;

        const size_pixels = 12 * io.display_framebuffer_scale.y;

        var font_cfg: c.FontConfig = std.mem.zeroes(c.FontConfig);
        font_cfg.font_data_owned_by_atlas = false;
        font_cfg.oversample_h = 2;
        font_cfg.oversample_v = 1;
        font_cfg.glyph_max_advance_x = std.math.floatMax(f32);
        font_cfg.rasterizer_multiply = 1.0;
        font_cfg.rasterizer_density = 1.0;
        font_cfg.ellipsis_char = c.UNICODE_CODEPOINT_MAX;
        _ = io.fonts.?.addFontFromMemoryTTF(
            @constCast(@ptrCast(font_data.ptr)),
            @intCast(font_data.len),
            size_pixels,
            &font_cfg,
            null,
        );
    }
}

pub fn deinit(imgui: *@This()) void {
    var bpd = BackendPlatformData.get();
    bpd.deinit();
    imgui.allocator.destroy(bpd);

    var brd = BackendRendererData.get();
    brd.deinit();
    imgui.allocator.destroy(brd);
}

pub fn newFrame(imgui: *@This()) !void {
    try BackendPlatformData.get().newFrame();
    try BackendRendererData.get().newFrame(imgui.allocator);
    c.newFrame();
}

pub fn getIO(imgui: @This()) *c.IO {
    _ = imgui;
    return c.getIO();
}

pub fn processEvent(event: core.Event) bool {
    return BackendPlatformData.get().processEvent(event);
}

pub fn render(imgui: @This(), pass_encoder: *gpu.RenderPassEncoder) !void {
    c.render();
    try BackendRendererData.get().render(imgui.allocator, c.getDrawData().?, pass_encoder);
}

// ------------------------------------------------------------------------------------------------
// Platform
// ------------------------------------------------------------------------------------------------

// Missing from mach:
// - HasSetMousePos
// - Clipboard
// - IME
// - Mouse Source (e.g. pen, touch)
// - Mouse Enter/Leave
// - joystick/gamepad

// Bugs?
// - Positive Delta Time

const BackendPlatformData = struct {
    pub fn init() BackendPlatformData {
        var io = c.getIO();
        io.backend_platform_name = "mach";
        io.backend_flags |= c.BackendFlags_HasMouseCursors;
        //io.backend_flags |= c.BackendFlags_HasSetMousePos;

        var bd = BackendPlatformData{};
        bd.setDisplaySizeAndScale();
        return bd;
    }

    pub fn deinit(bd: *BackendPlatformData) void {
        _ = bd;
        var io = c.getIO();
        io.backend_platform_name = null;
    }

    pub fn get() *BackendPlatformData {
        std.debug.assert(c.getCurrentContext() != null);

        const io = c.getIO();
        return @ptrCast(@alignCast(io.backend_platform_user_data));
    }

    pub fn newFrame(bd: *BackendPlatformData) !void {
        var io = c.getIO();

        bd.setDisplaySizeAndScale();

        // DeltaTime
        io.delta_time = if (core.delta_time > 0.0) core.delta_time else 1.0e-6;

        // WantSetMousePos - TODO

        // MouseCursor
        if ((io.config_flags & c.ConfigFlags_NoMouseCursorChange) == 0) {
            const imgui_cursor = c.getMouseCursor();

            if (io.mouse_draw_cursor or imgui_cursor == c.MouseCursor_None) {
                core.setCursorMode(.hidden);
            } else {
                core.setCursorMode(.normal);
                core.setCursorShape(machCursorShape(imgui_cursor));
            }
        }

        // Gamepads - TODO
    }

    pub fn processEvent(bd: *BackendPlatformData, event: core.Event) bool {
        _ = bd;
        var io = c.getIO();
        switch (event) {
            .key_press, .key_repeat => |data| {
                addKeyMods(data.mods);
                const key = imguiKey(data.key);
                io.addKeyEvent(key, true);
                return true;
            },
            .key_release => |data| {
                addKeyMods(data.mods);
                const key = imguiKey(data.key);
                io.addKeyEvent(key, false);
                return true;
            },
            .char_input => |data| {
                io.addInputCharacter(data.codepoint);
                return true;
            },
            .mouse_motion => |data| {
                // TODO - io.addMouseSourceEvent
                io.addMousePosEvent(@floatCast(data.pos.x), @floatCast(data.pos.y));
                return true;
            },
            .mouse_press => |data| {
                const mouse_button = imguiMouseButton(data.button);
                // TODO - io.addMouseSourceEvent
                io.addMouseButtonEvent(mouse_button, true);
                return true;
            },
            .mouse_release => |data| {
                const mouse_button = imguiMouseButton(data.button);
                // TODO - io.addMouseSourceEvent
                io.addMouseButtonEvent(mouse_button, false);
                return true;
            },
            .mouse_scroll => |data| {
                // TODO - io.addMouseSourceEvent
                io.addMouseWheelEvent(data.xoffset, data.yoffset);
                return true;
            },
            .joystick_connected => {},
            .joystick_disconnected => {},
            .framebuffer_resize => {},
            .focus_gained => {
                io.addFocusEvent(true);
                return true;
            },
            .focus_lost => {
                io.addFocusEvent(false);
                return true;
            },
            .close => {},

            // TODO - mouse enter/leave?
        }

        return false;
    }

    fn addKeyMods(mods: core.KeyMods) void {
        var io = c.getIO();
        io.addKeyEvent(c.Mod_Ctrl, mods.control);
        io.addKeyEvent(c.Mod_Shift, mods.shift);
        io.addKeyEvent(c.Mod_Alt, mods.alt);
        io.addKeyEvent(c.Mod_Super, mods.super);
    }

    fn setDisplaySizeAndScale(bd: *BackendPlatformData) void {
        _ = bd;
        var io = c.getIO();

        // DisplaySize
        const window_size = core.size();
        const w: f32 = @floatFromInt(window_size.width);
        const h: f32 = @floatFromInt(window_size.height);
        const display_w: f32 = @floatFromInt(core.descriptor.width);
        const display_h: f32 = @floatFromInt(core.descriptor.height);

        io.display_size = c.Vec2{ .x = w, .y = h };

        // DisplayFramebufferScale
        if (w > 0 and h > 0)
            io.display_framebuffer_scale = c.Vec2{ .x = display_w / w, .y = display_h / h };
    }

    fn imguiMouseButton(button: core.MouseButton) i32 {
        return @intFromEnum(button);
    }

    fn imguiKey(key: core.Key) c.Key {
        return switch (key) {
            .a => c.Key_A,
            .b => c.Key_B,
            .c => c.Key_C,
            .d => c.Key_D,
            .e => c.Key_E,
            .f => c.Key_F,
            .g => c.Key_G,
            .h => c.Key_H,
            .i => c.Key_I,
            .j => c.Key_J,
            .k => c.Key_K,
            .l => c.Key_L,
            .m => c.Key_M,
            .n => c.Key_N,
            .o => c.Key_O,
            .p => c.Key_P,
            .q => c.Key_Q,
            .r => c.Key_R,
            .s => c.Key_S,
            .t => c.Key_T,
            .u => c.Key_U,
            .v => c.Key_V,
            .w => c.Key_W,
            .x => c.Key_X,
            .y => c.Key_Y,
            .z => c.Key_Z,

            .zero => c.Key_0,
            .one => c.Key_1,
            .two => c.Key_2,
            .three => c.Key_3,
            .four => c.Key_4,
            .five => c.Key_5,
            .six => c.Key_6,
            .seven => c.Key_7,
            .eight => c.Key_8,
            .nine => c.Key_9,

            .f1 => c.Key_F1,
            .f2 => c.Key_F2,
            .f3 => c.Key_F3,
            .f4 => c.Key_F4,
            .f5 => c.Key_F5,
            .f6 => c.Key_F6,
            .f7 => c.Key_F7,
            .f8 => c.Key_F8,
            .f9 => c.Key_F9,
            .f10 => c.Key_F10,
            .f11 => c.Key_F11,
            .f12 => c.Key_F12,
            .f13 => c.Key_None,
            .f14 => c.Key_None,
            .f15 => c.Key_None,
            .f16 => c.Key_None,
            .f17 => c.Key_None,
            .f18 => c.Key_None,
            .f19 => c.Key_None,
            .f20 => c.Key_None,
            .f21 => c.Key_None,
            .f22 => c.Key_None,
            .f23 => c.Key_None,
            .f24 => c.Key_None,
            .f25 => c.Key_None,

            .kp_divide => c.Key_KeypadDivide,
            .kp_multiply => c.Key_KeypadMultiply,
            .kp_subtract => c.Key_KeypadSubtract,
            .kp_add => c.Key_KeypadAdd,
            .kp_0 => c.Key_Keypad0,
            .kp_1 => c.Key_Keypad1,
            .kp_2 => c.Key_Keypad2,
            .kp_3 => c.Key_Keypad3,
            .kp_4 => c.Key_Keypad4,
            .kp_5 => c.Key_Keypad5,
            .kp_6 => c.Key_Keypad6,
            .kp_7 => c.Key_Keypad7,
            .kp_8 => c.Key_Keypad8,
            .kp_9 => c.Key_Keypad9,
            .kp_decimal => c.Key_KeypadDecimal,
            .kp_equal => c.Key_KeypadEqual,
            .kp_enter => c.Key_KeypadEnter,

            .enter => c.Key_Enter,
            .escape => c.Key_Escape,
            .tab => c.Key_Tab,
            .left_shift => c.Key_LeftShift,
            .right_shift => c.Key_RightShift,
            .left_control => c.Key_LeftCtrl,
            .right_control => c.Key_RightCtrl,
            .left_alt => c.Key_LeftAlt,
            .right_alt => c.Key_RightAlt,
            .left_super => c.Key_LeftSuper,
            .right_super => c.Key_RightSuper,
            .menu => c.Key_Menu,
            .num_lock => c.Key_NumLock,
            .caps_lock => c.Key_CapsLock,
            .print => c.Key_PrintScreen,
            .scroll_lock => c.Key_ScrollLock,
            .pause => c.Key_Pause,
            .delete => c.Key_Delete,
            .home => c.Key_Home,
            .end => c.Key_End,
            .page_up => c.Key_PageUp,
            .page_down => c.Key_PageDown,
            .insert => c.Key_Insert,
            .left => c.Key_LeftArrow,
            .right => c.Key_RightArrow,
            .up => c.Key_UpArrow,
            .down => c.Key_DownArrow,
            .backspace => c.Key_Backspace,
            .space => c.Key_Space,
            .minus => c.Key_Minus,
            .equal => c.Key_Equal,
            .left_bracket => c.Key_LeftBracket,
            .right_bracket => c.Key_RightBracket,
            .backslash => c.Key_Backslash,
            .semicolon => c.Key_Semicolon,
            .apostrophe => c.Key_Apostrophe,
            .comma => c.Key_Comma,
            .period => c.Key_Period,
            .slash => c.Key_Slash,
            .grave => c.Key_GraveAccent,

            .unknown => c.Key_None,
        };
    }

    fn machCursorShape(imgui_cursor: c.MouseCursor) core.CursorShape {
        return switch (imgui_cursor) {
            c.MouseCursor_Arrow => .arrow,
            c.MouseCursor_TextInput => .ibeam,
            c.MouseCursor_ResizeAll => .resize_all,
            c.MouseCursor_ResizeNS => .resize_ns,
            c.MouseCursor_ResizeEW => .resize_ew,
            c.MouseCursor_ResizeNESW => .resize_nesw,
            c.MouseCursor_ResizeNWSE => .resize_nwse,
            c.MouseCursor_Hand => .pointing_hand,
            c.MouseCursor_NotAllowed => .not_allowed,
            else => unreachable,
        };
    }
};

// ------------------------------------------------------------------------------------------------
// Renderer
// ------------------------------------------------------------------------------------------------

fn alignUp(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

const Uniforms = struct {
    MVP: [4][4]f32,
};

const BackendRendererData = struct {
    device: *gpu.Device,
    queue: *gpu.Queue,
    color_format: gpu.Texture.Format,
    depth_stencil_format: gpu.Texture.Format,
    mag_filter: gpu.FilterMode,
    min_filter: gpu.FilterMode,
    mipmap_filter: gpu.MipmapFilterMode,
    device_resources: ?DeviceResources,
    max_frames_in_flight: u32,
    frame_index: u32,

    pub fn init(
        device: *gpu.Device,
        options: InitOptions,
    ) BackendRendererData {
        var io = c.getIO();
        io.backend_renderer_name = "mach";
        io.backend_flags |= c.BackendFlags_RendererHasVtxOffset;

        return .{
            .device = device,
            .queue = device.getQueue(),
            .color_format = options.color_format orelse core.descriptor.format,
            .depth_stencil_format = options.depth_stencil_format,
            .mag_filter = options.mag_filter,
            .min_filter = options.min_filter,
            .mipmap_filter = options.mipmap_filter,
            .device_resources = null,
            .max_frames_in_flight = options.max_frames_in_flight,
            .frame_index = std.math.maxInt(u32),
        };
    }

    pub fn deinit(bd: *BackendRendererData) void {
        var io = c.getIO();
        io.backend_renderer_name = null;
        io.backend_renderer_user_data = null;

        if (bd.device_resources) |*device_resources| device_resources.deinit();
        bd.queue.release();
    }

    pub fn get() *BackendRendererData {
        std.debug.assert(c.getCurrentContext() != null);

        const io = c.getIO();
        return @ptrCast(@alignCast(io.backend_renderer_user_data));
    }

    pub fn newFrame(bd: *BackendRendererData, allocator: std.mem.Allocator) !void {
        if (bd.device_resources == null) {
            bd.device_resources = try DeviceResources.init(allocator, bd);
        }
    }

    pub fn render(bd: *BackendRendererData, allocator: std.mem.Allocator, draw_data: *c.DrawData, pass_encoder: *gpu.RenderPassEncoder) !void {
        if (draw_data.display_size.x <= 0.0 or draw_data.display_size.y <= 0.0)
            return;

        // FIXME: Assuming that this only gets called once per frame!
        // If not, we can't just re-allocate the IB or VB, we'll have to do a proper allocator.
        if (bd.device_resources) |*device_resources| {
            bd.frame_index = @addWithOverflow(bd.frame_index, 1)[0];
            var fr = &device_resources.frame_resources[bd.frame_index % bd.max_frames_in_flight];

            // Create and grow vertex/index buffers if needed
            if (fr.vertex_buffer == null or fr.vertex_buffer_size < draw_data.total_vtx_count) {
                if (fr.vertex_buffer) |buffer| {
                    //buffer.destroy();
                    buffer.release();
                }
                if (fr.vertices) |x| allocator.free(x);
                fr.vertex_buffer_size = @intCast(draw_data.total_vtx_count + 5000);

                fr.vertex_buffer = bd.device.createBuffer(&.{
                    .label = "Dear ImGui Vertex buffer",
                    .usage = .{ .copy_dst = true, .vertex = true },
                    .size = alignUp(fr.vertex_buffer_size * @sizeOf(c.DrawVert), 4),
                });
                fr.vertices = try allocator.alloc(c.DrawVert, fr.vertex_buffer_size);
            }
            if (fr.index_buffer == null or fr.index_buffer_size < draw_data.total_idx_count) {
                if (fr.index_buffer) |buffer| {
                    //buffer.destroy();
                    buffer.release();
                }
                if (fr.indices) |x| allocator.free(x);
                fr.index_buffer_size = @intCast(draw_data.total_idx_count + 10000);

                fr.index_buffer = bd.device.createBuffer(&.{
                    .label = "Dear ImGui Index buffer",
                    .usage = .{ .copy_dst = true, .index = true },
                    .size = alignUp(fr.index_buffer_size * @sizeOf(c.DrawIdx), 4),
                });
                fr.indices = try allocator.alloc(c.DrawIdx, fr.index_buffer_size);
            }

            // Upload vertex/index data into a single contiguous GPU buffer
            var vtx_dst = fr.vertices.?;
            var idx_dst = fr.indices.?;
            var vb_write_size: usize = 0;
            var ib_write_size: usize = 0;
            for (0..@intCast(draw_data.cmd_lists_count)) |n| {
                const cmd_list = draw_data.cmd_lists.data[n];
                const vtx_size: usize = @intCast(cmd_list.vtx_buffer.size);
                const idx_size: usize = @intCast(cmd_list.idx_buffer.size);
                @memcpy(vtx_dst[0..vtx_size], cmd_list.vtx_buffer.data[0..vtx_size]);
                @memcpy(idx_dst[0..idx_size], cmd_list.idx_buffer.data[0..idx_size]);
                vtx_dst = vtx_dst[vtx_size..];
                idx_dst = idx_dst[idx_size..];
                vb_write_size += vtx_size;
                ib_write_size += idx_size;
            }
            vb_write_size = alignUp(vb_write_size, 4);
            ib_write_size = alignUp(ib_write_size, 4);
            if (vb_write_size > 0)
                bd.queue.writeBuffer(fr.vertex_buffer.?, 0, fr.vertices.?[0..vb_write_size]);
            if (ib_write_size > 0)
                bd.queue.writeBuffer(fr.index_buffer.?, 0, fr.indices.?[0..ib_write_size]);

            // Setup desired render state
            bd.setupRenderState(draw_data, pass_encoder, fr);

            // Render command lists
            var global_vtx_offset: c_uint = 0;
            var global_idx_offset: c_uint = 0;
            const clip_scale = draw_data.framebuffer_scale;
            const clip_off = draw_data.display_pos;
            const fb_width = draw_data.display_size.x * clip_scale.x;
            const fb_height = draw_data.display_size.y * clip_scale.y;
            for (0..@intCast(draw_data.cmd_lists_count)) |n| {
                const cmd_list = draw_data.cmd_lists.data[n];
                for (0..@intCast(cmd_list.cmd_buffer.size)) |cmd_i| {
                    const cmd = &cmd_list.cmd_buffer.data[cmd_i];
                    if (cmd.user_callback != null) {
                        // TODO - c.DrawCallback_ResetRenderState not generating yet
                        cmd.user_callback.?(cmd_list, cmd);
                    } else {
                        // Texture
                        const tex_id = cmd.getTexID();
                        const entry = try device_resources.image_bind_groups.getOrPut(allocator, tex_id);
                        if (!entry.found_existing) {
                            entry.value_ptr.* = bd.device.createBindGroup(
                                &gpu.BindGroup.Descriptor.init(.{
                                    .layout = device_resources.image_bind_group_layout,
                                    .entries = &[_]gpu.BindGroup.Entry{
                                        .{ .binding = 0, .texture_view = @ptrCast(tex_id), .size = 0 },
                                    },
                                }),
                            );
                        }

                        const bind_group = entry.value_ptr.*;
                        pass_encoder.setBindGroup(1, bind_group, &.{});

                        // Scissor
                        const clip_min: c.Vec2 = .{
                            .x = @max(0.0, (cmd.clip_rect.x - clip_off.x) * clip_scale.x),
                            .y = @max(0.0, (cmd.clip_rect.y - clip_off.y) * clip_scale.y),
                        };
                        const clip_max: c.Vec2 = .{
                            .x = @min(fb_width, (cmd.clip_rect.z - clip_off.x) * clip_scale.x),
                            .y = @min(fb_height, (cmd.clip_rect.w - clip_off.y) * clip_scale.y),
                        };
                        if (clip_max.x <= clip_min.x or clip_max.y <= clip_min.y)
                            continue;

                        pass_encoder.setScissorRect(
                            @intFromFloat(clip_min.x),
                            @intFromFloat(clip_min.y),
                            @intFromFloat(clip_max.x - clip_min.x),
                            @intFromFloat(clip_max.y - clip_min.y),
                        );

                        // Draw
                        pass_encoder.drawIndexed(cmd.elem_count, 1, @intCast(cmd.idx_offset + global_idx_offset), @intCast(cmd.vtx_offset + global_vtx_offset), 0);
                    }
                }
                global_idx_offset += @intCast(cmd_list.idx_buffer.size);
                global_vtx_offset += @intCast(cmd_list.vtx_buffer.size);
            }
        }
    }

    fn setupRenderState(
        bd: *BackendRendererData,
        draw_data: *c.DrawData,
        pass_encoder: *gpu.RenderPassEncoder,
        fr: *FrameResources,
    ) void {
        if (bd.device_resources) |device_resources| {
            const L = draw_data.display_pos.x;
            const R = draw_data.display_pos.x + draw_data.display_size.x;
            const T = draw_data.display_pos.y;
            const B = draw_data.display_pos.y + draw_data.display_size.y;

            const uniforms: Uniforms = .{
                .MVP = [4][4]f32{
                    [4]f32{ 2.0 / (R - L), 0.0, 0.0, 0.0 },
                    [4]f32{ 0.0, 2.0 / (T - B), 0.0, 0.0 },
                    [4]f32{ 0.0, 0.0, 0.5, 0.0 },
                    [4]f32{ (R + L) / (L - R), (T + B) / (B - T), 0.5, 1.0 },
                },
            };
            bd.queue.writeBuffer(device_resources.uniforms, 0, &[_]Uniforms{uniforms});

            const width: f32 = @floatFromInt(core.descriptor.width);
            const height: f32 = @floatFromInt(core.descriptor.height);
            const index_format: gpu.IndexFormat = if (@sizeOf(c.DrawIdx) == 2) .uint16 else .uint32;

            pass_encoder.setViewport(0, 0, width, height, 0, 1);
            pass_encoder.setVertexBuffer(0, fr.vertex_buffer.?, 0, fr.vertex_buffer_size * @sizeOf(c.DrawVert));
            pass_encoder.setIndexBuffer(fr.index_buffer.?, index_format, 0, fr.index_buffer_size * @sizeOf(c.DrawIdx));
            pass_encoder.setPipeline(device_resources.pipeline);
            pass_encoder.setBindGroup(0, device_resources.common_bind_group, &.{});
        }
    }
};

const DeviceResources = struct {
    allocator: std.mem.Allocator,
    pipeline: *gpu.RenderPipeline,
    font_texture: *gpu.Texture,
    font_texture_view: *gpu.TextureView,
    sampler: *gpu.Sampler,
    uniforms: *gpu.Buffer,
    common_bind_group: *gpu.BindGroup,
    image_bind_groups: std.AutoArrayHashMapUnmanaged(c.TextureID, *gpu.BindGroup),
    image_bind_group_layout: *gpu.BindGroupLayout,
    frame_resources: []FrameResources,

    pub fn init(allocator: std.mem.Allocator, bd: *BackendRendererData) !DeviceResources {
        // Bind Group layouts
        const common_bind_group_layout = bd.device.createBindGroupLayout(
            &gpu.BindGroupLayout.Descriptor.init(.{
                .entries = &[_]gpu.BindGroupLayout.Entry{
                    .{
                        .binding = 0,
                        .visibility = .{ .vertex = true, .fragment = true },
                        .buffer = .{ .type = .uniform },
                    },
                    .{
                        .binding = 1,
                        .visibility = .{ .fragment = true },
                        .sampler = .{ .type = .filtering },
                    },
                },
            }),
        );
        defer common_bind_group_layout.release();

        const image_bind_group_layout = bd.device.createBindGroupLayout(
            &gpu.BindGroupLayout.Descriptor.init(.{
                .entries = &[_]gpu.BindGroupLayout.Entry{
                    .{
                        .binding = 0,
                        .visibility = .{ .fragment = true },
                        .texture = .{ .sample_type = .float, .view_dimension = .dimension_2d },
                    },
                },
            }),
        );
        errdefer image_bind_group_layout.release();

        // Pipeline layout
        const pipeline_layout = bd.device.createPipelineLayout(
            &gpu.PipelineLayout.Descriptor.init(.{
                .bind_group_layouts = &[2]*gpu.BindGroupLayout{
                    common_bind_group_layout,
                    image_bind_group_layout,
                },
            }),
        );
        defer pipeline_layout.release();

        // Shaders
        const shader_module = bd.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
        defer shader_module.release();

        // Pipeline
        const pipeline = bd.device.createRenderPipeline(
            &.{
                .layout = pipeline_layout,
                .vertex = gpu.VertexState.init(.{
                    .module = shader_module,
                    .entry_point = "vertex_main",
                    .buffers = &[_]gpu.VertexBufferLayout{
                        gpu.VertexBufferLayout.init(.{
                            .array_stride = @sizeOf(c.DrawVert),
                            .step_mode = .vertex,
                            .attributes = &[_]gpu.VertexAttribute{
                                .{
                                    .format = .float32x2,
                                    .offset = @offsetOf(c.DrawVert, "pos"),
                                    .shader_location = 0,
                                },
                                .{
                                    .format = .float32x2,
                                    .offset = @offsetOf(c.DrawVert, "uv"),
                                    .shader_location = 1,
                                },
                                .{
                                    .format = .unorm8x4,
                                    .offset = @offsetOf(c.DrawVert, "col"),
                                    .shader_location = 2,
                                },
                            },
                        }),
                    },
                }),
                .primitive = .{
                    .topology = .triangle_list,
                    .strip_index_format = .undefined,
                    .front_face = .cw,
                    .cull_mode = .none,
                },
                .depth_stencil = if (bd.depth_stencil_format == .undefined) null else &.{
                    .format = bd.depth_stencil_format,
                    .depth_write_enabled = .false,
                    .depth_compare = .always,
                    .stencil_front = .{ .compare = .always },
                    .stencil_back = .{ .compare = .always },
                },
                .multisample = .{
                    .count = 1,
                    .mask = std.math.maxInt(u32),
                    .alpha_to_coverage_enabled = .false,
                },
                .fragment = &gpu.FragmentState.init(.{
                    .module = shader_module,
                    .entry_point = "fragment_main",
                    .targets = &[_]gpu.ColorTargetState{.{
                        .format = bd.color_format,
                        .blend = &.{
                            .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .one_minus_src_alpha },
                            .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
                        },
                        .write_mask = gpu.ColorWriteMaskFlags.all,
                    }},
                }),
            },
        );
        errdefer pipeline.release();

        // Font Texture
        const io = c.getIO();
        var pixels: ?*c_char = undefined;
        var width: c_int = undefined;
        var height: c_int = undefined;
        var size_pp: c_int = undefined;
        io.fonts.?.getTexDataAsRGBA32(&pixels, &width, &height, &size_pp);
        const pixels_data: ?[*]c_char = @ptrCast(pixels);

        const font_texture = bd.device.createTexture(&.{
            .label = "Dear ImGui Font Texture",
            .dimension = .dimension_2d,
            .size = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .depth_or_array_layers = 1,
            },
            .sample_count = 1,
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .usage = .{ .copy_dst = true, .texture_binding = true },
        });
        errdefer font_texture.release();

        const font_texture_view = font_texture.createView(null);
        errdefer font_texture_view.release();

        bd.queue.writeTexture(
            &.{
                .texture = font_texture,
                .mip_level = 0,
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .aspect = .all,
            },
            &.{
                .offset = 0,
                .bytes_per_row = @intCast(width * size_pp),
                .rows_per_image = @intCast(height),
            },
            &.{ .width = @intCast(width), .height = @intCast(height), .depth_or_array_layers = 1 },
            pixels_data.?[0..@intCast(width * size_pp * height)],
        );

        // Sampler
        const sampler = bd.device.createSampler(&.{
            .min_filter = bd.min_filter,
            .mag_filter = bd.mag_filter,
            .mipmap_filter = bd.mipmap_filter,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .max_anisotropy = 1,
        });
        errdefer sampler.release();

        // Uniforms
        const uniforms = bd.device.createBuffer(&.{
            .label = "Dear ImGui Uniform buffer",
            .usage = .{ .copy_dst = true, .uniform = true },
            .size = alignUp(@sizeOf(Uniforms), 16),
        });
        errdefer uniforms.release();

        // Common Bind Group
        const common_bind_group = bd.device.createBindGroup(
            &gpu.BindGroup.Descriptor.init(.{
                .layout = common_bind_group_layout,
                .entries = &[_]gpu.BindGroup.Entry{
                    .{ .binding = 0, .buffer = uniforms, .offset = 0, .size = alignUp(@sizeOf(Uniforms), 16) },
                    .{ .binding = 1, .sampler = sampler, .size = 0 },
                },
            }),
        );
        errdefer common_bind_group.release();

        // Image Bind Group
        const image_bind_group = bd.device.createBindGroup(
            &gpu.BindGroup.Descriptor.init(.{
                .layout = image_bind_group_layout,
                .entries = &[_]gpu.BindGroup.Entry{
                    .{ .binding = 0, .texture_view = font_texture_view, .size = 0 },
                },
            }),
        );
        errdefer image_bind_group.release();

        // Image Bind Groups
        var image_bind_groups = std.AutoArrayHashMapUnmanaged(c.TextureID, *gpu.BindGroup){};
        errdefer image_bind_groups.deinit(allocator);

        try image_bind_groups.put(allocator, font_texture_view, image_bind_group);

        // Frame Resources
        const frame_resources = try allocator.alloc(FrameResources, bd.max_frames_in_flight);
        for (0..bd.max_frames_in_flight) |i| {
            var fr = &frame_resources[i];
            fr.index_buffer = null;
            fr.vertex_buffer = null;
            fr.indices = null;
            fr.vertices = null;
            fr.index_buffer_size = 10000;
            fr.vertex_buffer_size = 5000;
        }

        // ImGui
        io.fonts.?.setTexID(font_texture_view);

        // Result
        return .{
            .allocator = allocator,
            .pipeline = pipeline,
            .font_texture = font_texture,
            .font_texture_view = font_texture_view,
            .sampler = sampler,
            .uniforms = uniforms,
            .common_bind_group = common_bind_group,
            .image_bind_groups = image_bind_groups,
            .image_bind_group_layout = image_bind_group_layout,
            .frame_resources = frame_resources,
        };
    }

    pub fn deinit(dr: *DeviceResources) void {
        var io = c.getIO();
        io.fonts.?.setTexID(null);

        dr.pipeline.release();
        dr.font_texture.release();
        dr.font_texture_view.release();
        dr.sampler.release();
        dr.uniforms.release();
        dr.common_bind_group.release();
        for (dr.image_bind_groups.values()) |x| x.release();
        dr.image_bind_group_layout.release();
        for (dr.frame_resources) |*frame_resources| frame_resources.release(dr.allocator);

        dr.image_bind_groups.deinit(dr.allocator);
        dr.allocator.free(dr.frame_resources);
    }
};

const FrameResources = struct {
    index_buffer: ?*gpu.Buffer,
    vertex_buffer: ?*gpu.Buffer,
    indices: ?[]c.DrawIdx,
    vertices: ?[]c.DrawVert,
    index_buffer_size: usize,
    vertex_buffer_size: usize,

    pub fn release(fr: *FrameResources, allocator: std.mem.Allocator) void {
        if (fr.index_buffer) |x| x.release();
        if (fr.vertex_buffer) |x| x.release();
        if (fr.indices) |x| allocator.free(x);
        if (fr.vertices) |x| allocator.free(x);
    }
};
