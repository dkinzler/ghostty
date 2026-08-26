//! EGL bindings via GLAD.
//!
//! Core EGL functions (eglGetDisplay, eglCreateContext, etc.) are linked
//! directly from libEGL and available via `c.egl*`. Extension functions
//! (such as `eglExportDMABUFImageMESA`) are loaded by GLAD at runtime
//! and are also accessed via `c.egl*` — GLAD `#define`s each extension
//! function name to its internal function-pointer global, so the same
//! call syntax works for both core and extension functions.
//!
//! Call `load()` once before using any EGL extension functions.

const std = @import("std");
const c = @cImport({
    @cInclude("glad/glad_egl.h");
});

const log = std.log.scoped(.opengl_egl);

/// The maximum number of planes in a DMABUF that we support.
pub const max_planes = 4;

/// A dma-buf frame produced by exporting a GL texture via EGL. This is
/// what the render thread hands to the apprt for compositing.
pub const ExportedFrame = struct {
    /// Width of the texture in pixels (device pixels).
    width: u32,
    /// Height of the texture in pixels (device pixels).
    height: u32,
    /// DRM fourcc of the pixel format. Ghostty renders RGBA/BGRA8
    /// premultiplied.
    fourcc: u32,
    /// DRM modifier of the format.
    modifier: u64,
    /// Whether the data is premultiplied. Ghostty's GL renderers output
    /// premultiplied alpha; GDK composites accordingly.
    premultiplied: bool = true,
    planes: Planes,

    /// The dma-buf planes for a presented frame. The caller owns the fds
    /// and must release them (or hand them to a compositor).
    pub const Planes = struct {
        /// Number of planes. Valid planes are `planes[0..count]`.
        count: u8,

        /// File descriptor for each plane. The consumer (compositor or
        /// `GdkDmabufTexture`) takes ownership of these fds.
        fds: [max_planes]std.posix.fd_t,

        /// Offset into the dma-buf where each plane starts, in bytes.
        offsets: [max_planes]c_int,

        /// Strides of each plane, in bytes.
        strides: [max_planes]c_int,

        /// Close all valid fds.
        pub fn deinit(self: Planes) void {
            for (self.fds[0..self.count]) |fd| {
                if (fd >= 0) _ = std.posix.system.close(fd);
            }
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        self.planes.deinit();
    }
};

/// Load EGL extension function pointers via GLAD. Must be called before
/// using any EGL extension functions (e.g. dmabuf export). Core EGL
/// functions are linked directly and don't require loading.
pub fn load() error{EglInitFailed}!void {
    if (c.gladLoadEGL() == 0) return error.EglInitFailed;
}

/// Wraps `eglGetProcAddress` for GLAD. GLAD's `gladLoadGLContext` expects
/// a loader returning `?*anyopaque`, but `eglGetProcAddress` returns
/// `?*const fn () callconv(.c) void`. This adapter bridges the types.
pub fn getProcAddress(name: [*c]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return c.eglGetProcAddress(name);
}

/// An owned EGL display and context.
///
/// EGL contexts can only be current on one thread at a time. The caller
/// is responsible for calling `makeCurrent`/`releaseCurrent` on the
/// appropriate thread.
pub const Context = struct {
    display: *anyopaque,
    context: *anyopaque,

    /// Create an EGL display and context and make the context current on
    /// the calling thread so that GL function pointers can be loaded. After
    /// this returns, the caller should release the context
    /// (`releaseCurrent`) so it can be bound to the render thread.
    ///
    /// This assumes `EGL_KHR_surfaceless_context` is always available since
    /// we want to render headlessly, not to a native window surface.
    /// Despite being an optional extension it is implemented practically
    /// universally by all graphics drivers that also support our minimum
    /// OpenGL version of 4.3, so we shouldn't even need to query for support
    /// here.
    pub fn init(
        gl_major: c.EGLint,
        gl_minor: c.EGLint,
    ) error{EglInitializeFailed}!Context {
        // Get the default display.
        const display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY) orelse {
            log.err("failed to get EGL display err=0x{x}", .{c.eglGetError()});
            return error.EglInitializeFailed;
        };

        var major: c.EGLint = undefined;
        var minor: c.EGLint = undefined;
        if (c.eglInitialize(display, &major, &minor) != c.EGL_TRUE) {
            log.err("failed to initialize EGL display err=0x{x}", .{c.eglGetError()});
            return error.EglInitializeFailed;
        }
        log.debug("EGL initialized {}.{}", .{ major, minor });

        // We want a desktop OpenGL context.
        if (c.eglBindAPI(c.EGL_OPENGL_API) != c.EGL_TRUE) {
            log.err("failed to bind OpenGL API to EGL err=0x{x}", .{c.eglGetError()});
            return error.EglInitializeFailed;
        }

        // Choose a config. We need a config that is renderable with
        // OpenGL and a RGBA8 color buffer. No surface type is
        // needed since we use surfaceless context.
        const config_attribs = [_]c.EGLint{
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_NONE,
        };
        var config: c.EGLConfig = undefined;
        var num_config: c.EGLint = 0;
        if (c.eglChooseConfig(
            display,
            &config_attribs,
            &config,
            1,
            &num_config,
        ) != c.EGL_TRUE or num_config == 0) {
            log.err("failed to choose EGL config err=0x{x}", .{c.eglGetError()});
            return error.EglInitializeFailed;
        }

        // Create our context.
        const context_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION,       gl_major,
            c.EGL_CONTEXT_MINOR_VERSION,       gl_minor,
            c.EGL_CONTEXT_OPENGL_PROFILE_MASK, c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            c.EGL_NONE,
        };
        const context = c.eglCreateContext(display, config, null, &context_attribs) orelse {
            log.err("failed to create EGL context err=0x{x}", .{c.eglGetError()});
            return error.EglInitializeFailed;
        };
        errdefer _ = c.eglDestroyContext(display, context);

        if (c.eglMakeCurrent(display, null, null, context) != c.EGL_TRUE) {
            log.err("failed to make EGL context current err=0x{x}", .{c.eglGetError()});
            return error.EglInitializeFailed;
        }

        var result: Context = .{
            .display = display,
            .context = context,
        };

        // Release the context from this thread so it can be bound
        // elsewhere. EGL contexts can only be current on one thread.
        result.releaseCurrent();
        return result;
    }

    /// Tear down the EGL context. Safe to call from any thread.
    /// The caller must ensure the context is not in use.
    /// After this returns the `Context` is invalid and must not be reused.
    pub fn deinit(self: *Context) void {
        _ = c.eglMakeCurrent(self.display, null, null, null);
        _ = c.eglDestroyContext(self.display, self.context);

        // Note: we intentionally do NOT call `eglTerminate` here.
        // All surfaces share `EGL_DEFAULT_DISPLAY`; terminating it when
        // one surface closes would invalidate every other surface's context
        // and every attempt to export will fail with `EGL_BAD_MATCH`.
        // The display lives for the process lifetime and is cleaned up
        // by the OS on exit.
    }

    /// Make the EGL context current on the calling thread and (re)load
    /// the thread-local GLAD function pointers so subsequent GL work is
    /// valid. Returns an error if the context can't be made current.
    pub fn makeCurrent(self: *const Context) !void {
        if (c.eglMakeCurrent(self.display, null, null, self.context) != c.EGL_TRUE) {
            log.err("failed to make EGL context current err=0x{x}", .{c.eglGetError()});
            return error.EglMakeCurrentFailed;
        }
    }

    /// Release the context from the calling thread.
    pub fn releaseCurrent(self: *const Context) void {
        _ = c.eglMakeCurrent(self.display, null, null, null);
    }

    /// Export a 2D OpenGL texture as an `ExportedFrame` (DMABUF) via
    /// `EGL_MESA_image_dma_buf_export`.
    ///
    /// `texture_id` is the GL texture name. `width` and `height` are the
    /// texture dimensions in pixels (included in the returned frame). The
    /// caller owns the fds in the returned frame's planes and must release
    /// them or hand them to a compositor.
    pub fn exportDmabuf(
        self: *const Context,
        texture_id: u32,
        width: u32,
        height: u32,
    ) !ExportedFrame {
        // Create an EGL image from the texture.
        const image = c.eglCreateImage(
            self.display,
            self.context,
            c.EGL_GL_TEXTURE_2D,
            @ptrFromInt(@as(usize, texture_id)),
            null,
        ) orelse {
            log.err("failed to create EGLImage from texture err=0x{x}", .{c.eglGetError()});
            return error.EglImageFailed;
        };
        defer _ = c.eglDestroyImage(self.display, image);

        // Query the dma-buf metadata.
        var fourcc: c_int = undefined;
        var num_planes: c_int = undefined;
        var modifier: u64 = undefined;
        if (c.eglExportDMABUFImageQueryMESA(
            self.display,
            image,
            &fourcc,
            &num_planes,
            &modifier,
        ) != c.EGL_TRUE) {
            log.err("eglExportDMABUFImageQueryMESA failed err=0x{x}", .{c.eglGetError()});
            return error.DmabufQueryFailed;
        }

        if (num_planes < 1 or num_planes > max_planes) {
            log.err("dma-buf has unsupported plane count {}", .{num_planes});
            return error.UnsupportedPlaneCount;
        }

        // Export the fd(s).
        var fds: [max_planes]c_int = undefined;
        var strides: [max_planes]c_int = undefined;
        var offsets: [max_planes]c_int = undefined;
        if (c.eglExportDMABUFImageMESA(
            self.display,
            image,
            &fds,
            &strides,
            &offsets,
        ) != c.EGL_TRUE) {
            log.err("eglExportDMABUFImageMESA failed err=0x{x}", .{c.eglGetError()});
            return error.DmabufExportFailed;
        }

        // If any fd came back invalid close the rest and bail; the caller
        // expects fd ownership to be transferred only on success.
        var n_valid: usize = 0;
        while (n_valid < num_planes) : (n_valid += 1) {
            if (fds[n_valid] < 0) {
                for (fds[0..n_valid]) |bad| _ = std.posix.system.close(bad);
                log.err("dma-buf export returned an invalid fd", .{});
                return error.DmabufInvalidFd;
            }
        }

        return .{
            .width = width,
            .height = height,
            .fourcc = @intCast(fourcc),
            .modifier = modifier,
            .premultiplied = true,
            .planes = .{
                .count = @intCast(num_planes),
                .fds = fds,
                .offsets = offsets,
                .strides = strides,
            },
        };
    }
};
