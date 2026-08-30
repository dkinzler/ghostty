//! Thin EGL bindings via GLAD.
//!
//! Only types and functions used in Ghostty are modelled,
//! although the API design is rather flexible and can be extended
//! to add whatever is required. Drop down to `gl.egl.c` to access
//! raw EGL functions.
//!
//! Call `load()` once before using any EGL extension functions.

const std = @import("std");

pub const c = @import("c");
const glad = @import("glad.zig");

const log = std.log.scoped(.opengl_egl);

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

pub const Error = error{
    NotInitialized,
    BadAccess,
    BadAlloc,
    BadAttribute,
    BadContext,
    BadConfig,
    BadCurrentSurface,
    BadDisplay,
    BadSurface,
    BadMatch,
    BadParameter,
    BadNativePixmap,
    BadNativeWindow,
    ContextLost,
    Unknown,
};

pub fn getError() Error!void {
    return switch (glad.context.GetError.?()) {
        c.EGL_SUCCESS => {},
        c.EGL_NOT_INITIALIZED => error.NotInitialized,
        c.EGL_BAD_ACCESS => error.BadAccess,
        c.EGL_BAD_ALLOC => error.BadAlloc,
        c.EGL_BAD_ATTRIBUTE => error.BadAttribute,
        c.EGL_BAD_CONTEXT => error.BadContext,
        c.EGL_BAD_CONFIG => error.BadConfig,
        c.EGL_BAD_CURRENT_SURFACE => error.BadCurrentSurface,
        c.EGL_BAD_DISPLAY => error.BadDisplay,
        c.EGL_BAD_SURFACE => error.BadSurface,
        c.EGL_BAD_MATCH => error.BadMatch,
        c.EGL_BAD_PARAMETER => error.BadParameter,
        c.EGL_BAD_NATIVE_PIXMAP => error.BadNativePixmap,
        c.EGL_BAD_NATIVE_WINDOW => error.BadNativeWindow,
        c.EGL_CONTEXT_LOST => error.ContextLost,
        else => Error.Unknown,
    };
}

pub fn mustError() Error {
    return if (getError()) |_| Error.Unknown else |e| e;
}

pub fn bindApi(api: c.EGLenum) Error!void {
    if (c.eglBindAPI(api) != c.EGL_TRUE) {
        return mustError();
    }
}

pub const Display = opaque {
    pub fn init(id: c.EGLNativeDisplayType) Error!*Display {
        // This will use MESA, if I try to force the Nvidia driver
        // with the __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
        // env var, eglGetDisplay returns null.
        //
        // const display = c.eglGetDisplay(id) orelse return mustError();

        // This also works to setup a display by selecting a device
        // directly. Just hard-coded here to use the first device which
        // will be the Nvidia card on my system.
        //
        // var eglQueryDevicesEXT: *const fn (c.EGLint, [*c]c.EGLDeviceEXT, [*c]c.EGLint) callconv(.c) c.EGLBoolean = undefined;
        // if (getProcAddress("eglQueryDevicesEXT")) |f| {
        //     eglQueryDevicesEXT = @ptrCast(f);
        //     log.debug("EGL eglQueryDevicesEXT found", .{});
        // } else {
        //     return mustError();
        // }
        // var num_devices: c.EGLint = undefined;
        // var devices: c.EGLDeviceEXT = undefined;
        // if (eglQueryDevicesEXT(1, &devices, &num_devices) != c.EGL_TRUE) {
        //     return mustError();
        // }

        // var eglGetPlatformDisplayEXT: *const fn (platform: c.EGLenum, native_display: ?*anyopaque, attrib_list: [*c]const c.EGLAttrib) callconv(.c) c.EGLDisplay = undefined;
        // if (getProcAddress("eglGetPlatformDisplayEXT")) |f| {
        //     eglGetPlatformDisplayEXT = @ptrCast(f);
        // } else {
        //     return mustError();
        // }

        // This works as well to init a display.
        //
        // const EGL_PLATFORM_DEVICE_EXT: c_int = 0x313f;
        // const display = eglGetPlatformDisplayEXT(
        //     EGL_PLATFORM_DEVICE_EXT,
        //     devices,
        //     null,
        // ) orelse return mustError();

        const EGL_PLATFORM_SURFACELESS_MESA = 0x31dd;

        // Both eglGetPlatformDisplayEXT and eglGetPlatformDisplay
        // seem to work, not sure if this matters. For reference
        // GTK uses eglGetPlatformDisplayEXT on my system but that
        // is with EGL_PLATFORM_WAYLAND_EXT.
        //
        // const display = eglGetPlatformDisplayEXT(
        //     EGL_PLATFORM_SURFACELESS_MESA,
        //     id,
        //     null,
        // ) orelse return mustError();

        const display = c.eglGetPlatformDisplay(
            EGL_PLATFORM_SURFACELESS_MESA,
            id,
            null,
        ) orelse return mustError();

        var major: c.EGLint = undefined;
        var minor: c.EGLint = undefined;
        if (c.eglInitialize(display, &major, &minor) != c.EGL_TRUE) {
            return mustError();
        }
        log.debug("EGL initialized {}.{}", .{ major, minor });

        // Check which vendor was selected.
        const vendor = c.eglQueryString(display, c.EGL_VENDOR);
        const version = c.eglQueryString(display, c.EGL_VERSION);
        const client_apis = c.eglQueryString(display, c.EGL_CLIENT_APIS);
        const extensions = c.eglQueryString(display, c.EGL_EXTENSIONS);
        log.debug("EGL vendor={s} version={s} client_apis={s} extensions={s}", .{ vendor, version, client_apis, extensions });

        return @ptrCast(display);
    }

    /// Make the EGL context current on the calling thread and (re)load
    /// the thread-local GLAD function pointers so subsequent GL work is
    /// valid. Returns an error if the context can't be made current.
    pub fn makeCurrent(self: *Display, draw: ?*Surface, read: ?*Surface, context: ?*Context) Error!void {
        if (c.eglMakeCurrent(self, draw, read, context) != c.EGL_TRUE) {
            return mustError();
        }
    }

    pub fn releaseCurrent(self: *Display) void {
        _ = c.eglMakeCurrent(self, null, null, null);
    }
};

pub const Config = opaque {
    pub fn choose(display: *Display, attrs: [:c.EGL_NONE]const c.EGLint) Error!*Config {
        var config: c.EGLConfig = undefined;
        var num_config: c.EGLint = 0;
        if (c.eglChooseConfig(
            display,
            attrs.ptr,
            &config,
            1,
            &num_config,
        ) != c.EGL_TRUE or num_config == 0) {
            return mustError();
        }
        log.debug("EGL eglChooseConfig num_config={}", .{num_config});
        return @ptrCast(config);
    }
};

pub const Surface = opaque {};

pub const Context = opaque {
    pub fn create(
        display: *Display,
        config: *Config,
        surface: ?*Surface,
        attrs: [:c.EGL_NONE]const c.EGLint,
    ) Error!*Context {
        const context = c.eglCreateContext(
            display,
            config,
            surface,
            attrs.ptr,
        ) orelse return mustError();
        return @ptrCast(context);
    }

    pub fn destroy(self: *Context, display: *Display) Error!void {
        if (c.eglDestroyContext(display, self) != c.EGL_TRUE) {
            return mustError();
        }
    }
};

pub const Image = opaque {
    pub fn create(
        display: *Display,
        context: *Context,
        comptime target: ImageTarget,
        buffer: target.Buffer(),
        attrs: ?[:c.EGL_NONE]c.EGLAttrib,
    ) Error!*Image {
        const image = c.eglCreateImage(
            display,
            context,
            @intFromEnum(target),
            @ptrFromInt(@as(usize, buffer)),
            if (attrs) |a| a.ptr else null,
        ) orelse return mustError();

        return @ptrCast(image);
    }

    pub fn destroy(self: *Image, display: *Display) Error!void {
        if (c.eglDestroyImage(display, self) != c.EGL_TRUE) {
            return mustError();
        }
    }

    pub fn exportDmabufQuery(self: *Image, display: *Display) Error!DmabufQuery {
        var query: DmabufQuery = undefined;
        if (c.eglExportDMABUFImageQueryMESA(
            display,
            self,
            &query.fourcc,
            &query.num_planes,
            &query.modifier,
        ) != c.EGL_TRUE) {
            return mustError();
        }
        return query;
    }

    pub fn exportDmabuf(
        self: *Image,
        display: *Display,
        fds: []c_int,
        strides: []c_int,
        offsets: []c_int,
    ) Error!void {
        if (c.eglExportDMABUFImageMESA(
            display,
            self,
            fds.ptr,
            strides.ptr,
            offsets.ptr,
        ) != c.EGL_TRUE) {
            return mustError();
        }
    }
};

pub const ImageTarget = enum(c.EGLenum) {
    texture_2d = c.EGL_GL_TEXTURE_2D,
    // Many other variants, add when needed

    pub fn Buffer(self: ImageTarget) type {
        return switch (self) {
            // GL texture name
            .texture_2d => u32,
        };
    }
};

pub const DmabufQuery = struct {
    fourcc: c_int,
    num_planes: c_int,
    modifier: u64,
};
