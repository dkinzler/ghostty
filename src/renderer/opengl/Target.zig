//! Represents a render target.
//!
//! In this case, a texture-backed framebuffer. The color attachment is a
//! `GL_TEXTURE_2D` texture instead of a renderbuffer so that we can create
//! an EGLImage from it and export the rendered frame as a dma-buf for
//! presentation by the apprt.
//!
//! We use two textures:
//!
//!   - `texture`: `GL_SRGB8_ALPHA8`. We render to this. With
//!     `GL_FRAMEBUFFER_SRGB` enabled, the GPU automatically converts linear
//!     shader output to sRGB on write. This is required for the
//!     linear-blending color pipeline to produce correct output.
//!
//!   - `export_texture`: `GL_RGBA8`. This is the texture we actually export
//!     as a dma-buf. Mesa cannot export `GL_SRGB8_ALPHA8` textures to
//!     dma-buf, so we blit the rendered sRGB texture into this plain RGBA8
//!     texture (the blit copies the already-sRGB-encoded pixel values
//!     verbatim) and export that instead.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;

const Dmabuf = @import("../Dmabuf.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a Target
pub const Options = struct {
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,
};

/// The framebuffer we render to (attached to `texture`).
framebuffer: gl.Framebuffer,

/// The sRGB color attachment texture we render to.
texture: gl.Texture,

/// A plain RGBA8 texture + framebuffer that we blit `texture` into for
/// dma-buf export. Mesa can't export sRGB textures, so we blit the
/// already-sRGB-encoded pixels into this non-sRGB texture and export it.
export_texture: gl.Texture,
export_framebuffer: gl.Framebuffer,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    // --- Render texture (sRGB) ---
    const texture = try gl.Texture.create();
    errdefer texture.destroy();
    {
        const bound_tex = try texture.bind(.@"2d");
        defer bound_tex.unbind();
        try bound_tex.parameter(.min_filter, .nearest);
        try bound_tex.parameter(.mag_filter, .nearest);
        try bound_tex.parameter(.wrap_s, .clamp_to_edge);
        try bound_tex.parameter(.wrap_t, .clamp_to_edge);
        try bound_tex.image2D(
            0,
            .srgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound_tex.parameter(.base_level, 0);
        try bound_tex.parameter(.max_level, 0);
    }

    const fbo = try gl.Framebuffer.create();
    errdefer fbo.destroy();
    {
        const bound_fbo = try fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2d", texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("render framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }

    // --- Export texture (plain RGBA8, for dma-buf export) ---
    const export_texture = try gl.Texture.create();
    errdefer export_texture.destroy();
    {
        const bound_tex = try export_texture.bind(.@"2d");
        defer bound_tex.unbind();
        try bound_tex.parameter(.min_filter, .nearest);
        try bound_tex.parameter(.mag_filter, .nearest);
        try bound_tex.parameter(.wrap_s, .clamp_to_edge);
        try bound_tex.parameter(.wrap_t, .clamp_to_edge);
        try bound_tex.image2D(
            0,
            .rgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound_tex.parameter(.base_level, 0);
        try bound_tex.parameter(.max_level, 0);
    }

    const export_fbo = try gl.Framebuffer.create();
    errdefer export_fbo.destroy();
    {
        const bound_fbo = try export_fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2d", export_texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("export framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }

    return .{
        .framebuffer = fbo,
        .texture = texture,
        .export_texture = export_texture,
        .export_framebuffer = export_fbo,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    self.export_framebuffer.destroy();
    self.export_texture.destroy();
    self.framebuffer.destroy();
    self.texture.destroy();
}

pub fn exportDmabuf(self: *const Self, display: *egl.Display, context: *egl.Context) !Dmabuf {
    // We unfortunately cannot reuse the image here
    // as it causes horrendous artifacts.
    const image: *egl.Image = try .create(
        display,
        context,
        .texture_2d,
        self.export_texture.id,
        null,
    );
    defer image.destroy(display) catch |err| {
        log.err("failed to destroy image while exporting DMABUF err={}", .{err});
    };

    const query = try image.exportDmabufQuery(display);

    if (query.num_planes < 1 or query.num_planes > Dmabuf.max_planes) {
        log.err("DMABUF has too many planes={}", .{query.num_planes});
        return error.BadMatch;
    }

    var planes: Dmabuf.Planes = .{ .count = @intCast(query.num_planes) };
    try image.exportDmabuf(
        display,
        &planes.fds,
        &planes.strides,
        &planes.offsets,
    );

    planes.validate() catch {
        log.err("DMABUF export returned an invalid fd", .{});
        return error.BadMatch;
    };

    return .{
        .width = @intCast(self.width),
        .height = @intCast(self.height),
        // bitCast instead of intCast since the numerical value of fourccs
        // is rather meaningless, and we only care about the bit pattern
        .fourcc = @bitCast(query.fourcc),
        .modifier = query.modifier,
        .premultiplied = true,
        .planes = planes,
    };
}
