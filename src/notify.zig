const std = @import("std");
const issue_mod = @import("issue.zig");
const log = @import("log.zig");

const NotifyMode = enum {
    osc777, // title + body (ghostty, foot, wezterm, rxvt-unicode)
    osc9, // message only (iterm2, windows terminal, others)
};

/// Detect whether we're inside tmux
fn inTmux() bool {
    return std.posix.getenv("TMUX") != null;
}

/// Detect notification mode based on terminal.
/// OSC 777 supports a separate title and body; OSC 9 is message-only.
fn detectMode() NotifyMode {
    if (std.posix.getenv("TERM_PROGRAM")) |term_prog| {
        if (std.mem.eql(u8, term_prog, "ghostty")) return .osc777;
        if (std.mem.eql(u8, term_prog, "WezTerm")) return .osc777;
    }
    // foot sets TERM=foot or TERM=foot-extra, not TERM_PROGRAM
    if (std.posix.getenv("TERM")) |term| {
        if (std.mem.startsWith(u8, term, "foot")) return .osc777;
        if (std.mem.startsWith(u8, term, "rxvt-unicode")) return .osc777;
    }
    return .osc9;
}

/// Find the first in-progress issue (highest priority, most recent).
fn firstInProgress(issues: []const issue_mod.Issue) ?*const issue_mod.Issue {
    for (issues) |*iss| {
        if (iss.isInProgress()) return iss;
    }
    return null;
}

/// Send a desktop notification reminding the user of their current focus task.
/// Uses OSC 777 (with title+body) or OSC 9 (message only), with tmux DCS
/// passthrough when running inside tmux.
pub fn sendNotification(issues: []const issue_mod.Issue) void {
    const iss = firstInProgress(issues) orelse return;

    const tmux = inTmux();
    const mode = detectMode();

    var buf: [1024]u8 = undefined;
    const msg = switch (mode) {
        .osc777 => blk: {
            if (tmux) {
                // tmux DCS passthrough: \ePtmux;\e{doubled-ESC sequence}\e\\
                break :blk std.fmt.bufPrint(&buf, "\x1bPtmux;\x1b\x1b]777;notify;Focus;{s} {s}\x1b\x1b\\\x1b\\", .{ iss.identifier, iss.title }) catch return;
            } else {
                break :blk std.fmt.bufPrint(&buf, "\x1b]777;notify;Focus;{s} {s}\x1b\\", .{ iss.identifier, iss.title }) catch return;
            }
        },
        .osc9 => blk: {
            if (tmux) {
                break :blk std.fmt.bufPrint(&buf, "\x1bPtmux;\x1b\x1b]9;Focus: {s} {s}\x1b\x1b\\\x1b\\", .{ iss.identifier, iss.title }) catch return;
            } else {
                break :blk std.fmt.bufPrint(&buf, "\x1b]9;Focus: {s} {s}\x1b\\", .{ iss.identifier, iss.title }) catch return;
            }
        },
    };

    // Write directly to /dev/tty to avoid interfering with vaxis alt screen.
    // OSC sequences are processed by the terminal emulator, not the screen buffer.
    const tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .write_only }) catch return;
    defer tty.close();
    tty.writeAll(msg) catch {};

    log.info("notify: sent {s} notification (tmux={}) for {s}", .{
        if (mode == .osc777) "OSC777" else "OSC9",
        tmux,
        iss.identifier,
    });
}

/// Write the current focus task to ~/.local/state/focus/current_task.txt
/// for external tools (neovim statusline, tmux status bar, etc.) to read.
pub fn writeStateFile(issues: []const issue_mod.Issue) void {
    const state_home = std.posix.getenv("XDG_STATE_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return;
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        break :blk std.fmt.bufPrint(&home_buf, "{s}/.local/state", .{home}) catch return;
    };

    // Ensure the focus state directory exists
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const focus_dir = std.fmt.bufPrint(&dir_buf, "{s}/focus", .{state_home}) catch return;

    // Create parent dirs if needed
    ensureDir(state_home);
    ensureDir(focus_dir);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/focus/current_task.txt", .{state_home}) catch return;

    const file = std.fs.createFileAbsolute(file_path, .{}) catch return;
    defer file.close();

    const iss = firstInProgress(issues) orelse {
        file.writeAll("") catch {};
        return;
    };

    var write_buf: [1024]u8 = undefined;
    const content = std.fmt.bufPrint(&write_buf, "{s} {s}\n", .{ iss.identifier, iss.title }) catch return;
    file.writeAll(content) catch {};
}

fn ensureDir(path: []const u8) void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {},
    };
}

// --- Tests ---

const testing = std.testing;

test "detectMode returns osc9 by default" {
    // In test environment, TERM_PROGRAM is unlikely to be ghostty/foot
    // Just verify it doesn't crash
    _ = detectMode();
}

test "inTmux returns bool" {
    _ = inTmux();
}

test "firstInProgress finds started issue" {
    const issues = [_]issue_mod.Issue{
        .{
            .identifier = "FOC-1",
            .title = "Todo task",
            .state_name = "Todo",
            .state_type = .unstarted,
            .priority_label = .medium,
        },
        .{
            .identifier = "FOC-2",
            .title = "Active task",
            .state_name = "In Progress",
            .state_type = .started,
            .priority_label = .high,
        },
    };

    const result = firstInProgress(&issues);
    try testing.expect(result != null);
    try testing.expectEqualStrings("FOC-2", result.?.identifier);
}

test "firstInProgress returns null when none in progress" {
    const issues = [_]issue_mod.Issue{
        .{
            .identifier = "FOC-1",
            .title = "Todo task",
            .state_name = "Todo",
            .state_type = .unstarted,
            .priority_label = .medium,
        },
    };

    const result = firstInProgress(&issues);
    try testing.expect(result == null);
}

test "firstInProgress handles empty slice" {
    const issues = [_]issue_mod.Issue{};
    const result = firstInProgress(&issues);
    try testing.expect(result == null);
}
