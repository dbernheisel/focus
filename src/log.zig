const std = @import("std");

var log_file: ?std.fs.File = null;
var mutex: std.Thread.Mutex = .{};

pub fn init() void {
    const home = std.posix.getenv("HOME") orelse return;
    var buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&buf, "{s}/.local/share/focus", .{home}) catch return;

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/debug.log", .{dir_path}) catch return;
    log_file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
}

pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    if (log_file) |f| f.close();
    log_file = null;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    mutex.lock();
    defer mutex.unlock();
    const f = log_file orelse return;
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    f.writeAll(msg) catch {};
}
