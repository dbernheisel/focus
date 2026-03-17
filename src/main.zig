const std = @import("std");
const vaxis = @import("vaxis");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const event_mod = @import("event.zig");
const render_mod = @import("render.zig");
const issue_mod = @import("issue.zig");
const linear_api = @import("linear_api.zig");
const notion_api = @import("notion_api.zig");

const notify = @import("notify.zig");
const log = @import("log.zig");

const Event = event_mod.Event;
const Effect = event_mod.Effect;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // CLI mode check
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            runListMode(allocator);
        }
    }

    // Load config
    var cfg = config_mod.loadConfig(allocator) catch |err| {
        const stderr: std.fs.File = .stderr();
        switch (err) {
            error.FileNotFound => stderr.writeAll("Error: config not found at ~/.config/focus/config.json\n") catch {},
            error.NoWorkspaces => stderr.writeAll("Error: no workspaces configured in ~/.config/focus/config.json\n") catch {},
            error.ParseError => stderr.writeAll("Error: failed to parse ~/.config/focus/config.json — check JSON syntax\n") catch {},
            else => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error loading config: {}\n", .{err}) catch "Error loading config\n";
                stderr.writeAll(msg) catch {};
            },
        }
        std.process.exit(1);
    };
    defer cfg.deinit();

    // Init terminal
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    // Init state
    const total_workspaces = cfg.linear.len + cfg.notion.len;
    const pending: u16 = if (total_workspaces <= std.math.maxInt(u16))
        @intCast(total_workspaces)
    else
        std.math.maxInt(u16);

    // Build API key slices for state (referencing config-owned memory)
    var linear_keys = try allocator.alloc([]const u8, cfg.linear.len);
    defer allocator.free(linear_keys);
    var linear_workspaces = try allocator.alloc([]const u8, cfg.linear.len);
    defer allocator.free(linear_workspaces);
    var linear_desktop = try allocator.alloc(bool, cfg.linear.len);
    defer allocator.free(linear_desktop);
    var linear_default_teams = try allocator.alloc([]const u8, cfg.linear.len);
    defer allocator.free(linear_default_teams);

    for (cfg.linear, 0..) |ws, i| {
        linear_keys[i] = ws.api_key;
        linear_workspaces[i] = ws.workspace;
        linear_desktop[i] = ws.desktop_links;
        linear_default_teams[i] = ws.default_team;
    }

    var notion_keys = try allocator.alloc([]const u8, cfg.notion.len);
    defer allocator.free(notion_keys);
    for (cfg.notion, 0..) |ws, i| {
        notion_keys[i] = ws.api_key;
    }

    var app_state = state_mod.State{
        .loading = true,
        .pending_fetches = pending,
        .linear_api_keys = linear_keys,
        .notion_api_keys = notion_keys,
        .linear_workspaces = linear_workspaces,
        .linear_desktop_links = linear_desktop,
        .linear_default_teams = linear_default_teams,
        .default_team = cfg.default_team,
        .allocator = allocator,
    };
    defer cleanupState(allocator, &app_state);

    log.init();
    defer log.deinit();
    log.info("focus started, {d} linear workspaces, {d} notion workspaces", .{ cfg.linear.len, cfg.notion.len });

    // Dispatch initial fetches
    for (cfg.linear, 0..) |ws, i| {
        dispatchEffect(allocator, .{ .fetch_linear_issues = .{ .workspace_idx = i, .api_key = ws.api_key } }, &loop);
    }
    for (cfg.notion, 0..) |_, i| {
        dispatchEffect(allocator, .{ .fetch_notion_issues = .{ .workspace_idx = i, .api_key = cfg.notion[i].api_key } }, &loop);
    }

    // Fetch teams and viewer for all linear workspaces
    for (cfg.linear, 0..) |ws, i| {
        dispatchEffect(allocator, .{ .fetch_teams_and_viewer = .{ .workspace_idx = i, .api_key = ws.api_key } }, &loop);
    }

    // Start poll timer
    const poll_thread = try std.Thread.spawn(.{}, pollTimer, .{&loop});
    poll_thread.detach();

    // Main loop
    while (true) {
        const event = loop.nextEvent();
        const result = state_mod.update(app_state, event);
        app_state = result.state;

        // Handle winsize events by resizing vaxis
        switch (event) {
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
            },
            else => {},
        }

        // Notifications and state file updates
        switch (event) {
            .issues_fetched => {
                if (app_state.pending_fetches == 0) {
                    notify.writeStateFile(app_state.issues);
                }
            },
            .poll_tick => {
                notify.sendNotification(app_state.issues);
            },
            else => {},
        }

        // Dispatch effects
        for (0..result.effect_count) |i| {
            if (result.effects[i]) |eff| {
                switch (eff) {
                    .quit => {
                        // Clean exit: restore terminal, then hard-exit to avoid
                        // errors from detached worker threads during defer cleanup.
                        vx.exitAltScreen(tty.writer()) catch {};
                        vx.deinit(allocator, tty.writer());
                        tty.deinit();
                        log.deinit();
                        std.process.exit(0);
                    },
                    else => dispatchEffect(allocator, eff, &loop),
                }
            }
        }

        // Render
        const win = vx.window();
        render_mod.render(&app_state, win);
        try vx.render(tty.writer());
    }
}

fn cleanupState(allocator: std.mem.Allocator, app_state: *state_mod.State) void {
    // Free all issue strings and the issues slice
    if (app_state.issues.len > 0) {
        issue_mod.freeIssues(allocator, app_state.issues);
    }

    // Free teams
    if (app_state.teams.len > 0) {
        for (app_state.teams) |team| {
            allocator.free(team.id);
            allocator.free(team.name);
            allocator.free(team.key);
        }
        allocator.free(app_state.teams);
    }

    // Free viewer_ids
    for (&app_state.viewer_ids) |*vid| {
        if (vid.*) |v| {
            allocator.free(v);
            vid.* = null;
        }
    }

    // Free team states
    for (app_state.team_states_entries[0..app_state.team_states_count]) |entry_opt| {
        if (entry_opt) |entry| {
            for (entry.states) |ws| {
                allocator.free(ws.id);
                allocator.free(ws.name);
                allocator.free(ws.state_type);
            }
            allocator.free(entry.states);
        }
    }
}

fn runListMode(allocator: std.mem.Allocator) noreturn {
    const stderr: std.fs.File = .stderr();

    // Load config
    var cfg = config_mod.loadConfig(allocator) catch |err| {
        switch (err) {
            error.FileNotFound => stderr.writeAll("Error: config not found at ~/.config/focus/config.json\n") catch {},
            error.NoWorkspaces => stderr.writeAll("Error: no workspaces configured in ~/.config/focus/config.json\n") catch {},
            error.ParseError => stderr.writeAll("Error: failed to parse ~/.config/focus/config.json — check JSON syntax\n") catch {},
            else => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error loading config: {}\n", .{err}) catch "Error loading config\n";
                stderr.writeAll(msg) catch {};
            },
        }
        std.process.exit(1);
    };
    defer cfg.deinit();

    // Fetch issues from all Linear workspaces synchronously
    var all_issues: std.ArrayList(issue_mod.Issue) = .{};
    defer all_issues.deinit(allocator);

    for (cfg.linear, 0..) |ws, i| {
        const issues = linear_api.fetchIssues(allocator, ws.api_key, i) catch |err| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: Linear API request failed: {}\n", .{err}) catch "Error: Linear API request failed\n";
            stderr.writeAll(msg) catch {};
            std.process.exit(1);
        };
        defer allocator.free(issues);

        for (issues) |issue| {
            all_issues.append(allocator, issue) catch {
                stderr.writeAll("Error: out of memory\n") catch {};
                std.process.exit(1);
            };
        }
    }

    // Write JSON to stdout
    writeListJson(allocator, all_issues.items) catch {
        stderr.writeAll("Error: failed to write to stdout\n") catch {};
        std.process.exit(1);
    };
    std.process.exit(0);
}

fn writeListJson(allocator: std.mem.Allocator, issues: []const issue_mod.Issue) !void {
    // Build JSON string in memory, then write all at once
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("[\n");

    for (issues, 0..) |issue, i| {
        try writer.writeAll("  {\n");
        try writer.print("    \"identifier\": \"", .{});
        try writeJsonEscaped(writer, issue.identifier);
        try writer.writeAll("\",\n");

        try writer.writeAll("    \"title\": \"");
        try writeJsonEscaped(writer, issue.title);
        try writer.writeAll("\",\n");

        try writer.writeAll("    \"state_name\": \"");
        try writeJsonEscaped(writer, issue.state_name);
        try writer.writeAll("\",\n");

        try writer.print("    \"state_type\": \"{s}\",\n", .{stateTypeString(issue.state_type)});

        try writer.print("    \"priority_label\": \"{s}\"\n", .{priorityLabelString(issue.priority_label)});

        if (i < issues.len - 1) {
            try writer.writeAll("  },\n");
        } else {
            try writer.writeAll("  }\n");
        }
    }

    try writer.writeAll("]\n");

    const stdout: std.fs.File = .stdout();
    try stdout.writeAll(buf.items);
}

fn priorityLabelString(label: issue_mod.PriorityLabel) []const u8 {
    return switch (label) {
        .urgent => "Urgent",
        .high => "High",
        .medium => "Medium",
        .low => "Low",
        .none => "No priority",
    };
}

fn stateTypeString(st: issue_mod.StateType) []const u8 {
    return switch (st) {
        .started => "started",
        .unstarted => "unstarted",
        .backlog => "backlog",
        .completed => "completed",
    };
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

fn pollTimer(loop: *vaxis.Loop(Event)) void {
    while (true) {
        std.Thread.sleep(15 * 60 * std.time.ns_per_s);
        loop.postEvent(.{ .poll_tick = {} });
    }
}

fn dispatchEffect(allocator: std.mem.Allocator, effect: Effect, loop: *vaxis.Loop(Event)) void {
    switch (effect) {
        .fetch_linear_issues => |data| {
            log.info("effect: fetch_linear_issues ws={d}", .{data.workspace_idx});
            const thread = std.Thread.spawn(.{}, fetchLinearWorker, .{ allocator, data.api_key, data.workspace_idx, loop }) catch return;
            thread.detach();
        },
        .fetch_notion_issues => |data| {
            const thread = std.Thread.spawn(.{}, fetchNotionWorker, .{ allocator, data.api_key, data.workspace_idx, loop }) catch return;
            thread.detach();
        },
        .fetch_description => |data| {
            log.info("effect: fetch_description key={s}", .{data.issue_key});
            switch (data.source) {
                .linear => {
                    const thread = std.Thread.spawn(.{}, fetchLinearDescriptionWorker, .{ allocator, data.api_key, data.issue_key, loop }) catch return;
                    thread.detach();
                },
                .notion => {
                    const thread = std.Thread.spawn(.{}, fetchNotionDescriptionWorker, .{ allocator, data.api_key, data.issue_key, loop }) catch return;
                    thread.detach();
                },
            }
        },
        .fetch_teams_and_viewer => |data| {
            log.info("effect: fetch_teams ws={d}", .{data.workspace_idx});
            const thread = std.Thread.spawn(.{}, fetchTeamsWorker, .{ allocator, data.api_key, data.workspace_idx, loop }) catch return;
            thread.detach();
        },
        .fetch_team_states => |data| {
            log.info("effect: fetch_team_states team={s}", .{data.team_id});
            const thread = std.Thread.spawn(.{}, fetchTeamStatesWorker, .{ allocator, data.api_key, data.team_id, loop }) catch return;
            thread.detach();
        },
        .update_linear_status => |data| {
            log.info("effect: update_linear_status id={s} identifier={s} state_id={s} state_name={s}", .{ data.issue_id, data.identifier, data.state_id, data.state_name });
            const thread = std.Thread.spawn(.{}, updateLinearStatusWorker, .{ allocator, data.api_key, data.issue_id, data.identifier, data.state_id, data.state_name, data.state_type, loop }) catch return;
            thread.detach();
        },
        .update_notion_status => |data| {
            const thread = std.Thread.spawn(.{}, updateNotionStatusWorker, .{ allocator, data.api_key, data.page_id, data.status_prop, data.status_name, data.status_group, loop }) catch return;
            thread.detach();
        },
        .create_issue => |data| {
            log.info("effect: create_issue team={s} title={s} priority={d}", .{ data.params.team_id, data.params.title, data.params.priority });
            // Dupe title/body onto heap since the slices point into stack-owned CreateForm buffers
            var params = data.params;
            params.title = allocator.dupe(u8, data.params.title) catch return;
            params.description = if (data.params.description) |d| (allocator.dupe(u8, d) catch return) else null;
            const thread = std.Thread.spawn(.{}, createIssueWorker, .{ allocator, data.api_key, params, loop }) catch return;
            thread.detach();
        },
        .open_url => |url| {
            const argv = [_][]const u8{ "open", url };
            var child = std.process.Child.init(&argv, allocator);
            _ = child.spawnAndWait() catch {};
            // Free the dynamically allocated URL string
            allocator.free(url);
        },
        .quit => unreachable,
    }
}

fn fetchLinearWorker(allocator: std.mem.Allocator, api_key: []const u8, workspace_idx: usize, loop: *vaxis.Loop(Event)) void {
    const issues = linear_api.fetchIssues(allocator, api_key, workspace_idx) catch {
        log.info("fetch_linear_issues ws={d} ERROR", .{workspace_idx});
        loop.postEvent(.{ .issues_fetched = .{ .source = .linear, .workspace_idx = workspace_idx, .result = .{ .err = "Linear API error" } } });
        return;
    };
    log.info("fetch_linear_issues ws={d} ok, {d} issues", .{ workspace_idx, issues.len });
    loop.postEvent(.{ .issues_fetched = .{ .source = .linear, .workspace_idx = workspace_idx, .result = .{ .ok = issues } } });
}

fn fetchNotionWorker(_: std.mem.Allocator, _: []const u8, workspace_idx: usize, loop: *vaxis.Loop(Event)) void {
    // TODO: implement notion fetch
    loop.postEvent(.{ .issues_fetched = .{ .source = .notion, .workspace_idx = workspace_idx, .result = .{ .ok = &.{} } } });
}

fn fetchLinearDescriptionWorker(allocator: std.mem.Allocator, api_key: []const u8, issue_key: []const u8, loop: *vaxis.Loop(Event)) void {
    const data = linear_api.fetchDescription(allocator, api_key, issue_key) catch {
        loop.postEvent(.{ .description_fetched = .{ .issue_key = issue_key, .result = .{ .err = "Failed to fetch description" } } });
        return;
    };
    loop.postEvent(.{ .description_fetched = .{ .issue_key = issue_key, .result = .{ .ok = .{ .description = data.description, .comments = data.comments } } } });
}

fn fetchNotionDescriptionWorker(allocator: std.mem.Allocator, api_key: []const u8, page_id: []const u8, loop: *vaxis.Loop(Event)) void {
    const content = notion_api.fetchPageContent(allocator, api_key, page_id) catch {
        loop.postEvent(.{ .description_fetched = .{ .issue_key = page_id, .result = .{ .err = "Failed to fetch page content" } } });
        return;
    };
    loop.postEvent(.{ .description_fetched = .{ .issue_key = page_id, .result = .{ .ok = .{ .description = content } } } });
}

fn fetchTeamsWorker(allocator: std.mem.Allocator, api_key: []const u8, workspace_idx: usize, loop: *vaxis.Loop(Event)) void {
    const result = linear_api.fetchTeamsAndViewer(allocator, api_key) catch {
        log.info("fetch_teams ws={d} ERROR", .{workspace_idx});
        loop.postEvent(.{ .teams_fetched = .{ .workspace_idx = workspace_idx, .result = .{ .err = "Failed to fetch teams" } } });
        return;
    };
    log.info("fetch_teams ws={d} ok, {d} teams, viewer={s}", .{ workspace_idx, result.teams.len, result.viewer_id });
    loop.postEvent(.{ .teams_fetched = .{
        .workspace_idx = workspace_idx,
        .result = .{ .ok = .{ .viewer_id = result.viewer_id, .teams = result.teams } },
    } });
}

fn fetchTeamStatesWorker(allocator: std.mem.Allocator, api_key: []const u8, team_id: []const u8, loop: *vaxis.Loop(Event)) void {
    const states = linear_api.fetchTeamStates(allocator, api_key, team_id) catch {
        loop.postEvent(.{ .team_states_fetched = .{ .team_id = team_id, .result = .{ .err = "Failed to fetch team states" } } });
        return;
    };
    loop.postEvent(.{ .team_states_fetched = .{ .team_id = team_id, .result = .{ .ok = states } } });
}

fn updateLinearStatusWorker(allocator: std.mem.Allocator, api_key: []const u8, issue_id: []const u8, identifier: []const u8, state_id: []const u8, state_name: []const u8, state_type: []const u8, loop: *vaxis.Loop(Event)) void {
    log.info("updateLinearStatus: calling API id={s} state_id={s}", .{ issue_id, state_id });
    linear_api.updateIssueState(allocator, api_key, issue_id, state_id) catch {
        log.info("updateLinearStatus: FAILED for {s}", .{identifier});
        loop.postEvent(.{ .status_updated = .{ .err = "Failed to update status" } });
        return;
    };
    log.info("updateLinearStatus: OK {s} -> {s}", .{ identifier, state_name });
    loop.postEvent(.{ .status_updated = .{ .ok = .{
        .issue_key = identifier,
        .new_state_name = state_name,
        .new_state_type = state_type,
    } } });
}

fn updateNotionStatusWorker(allocator: std.mem.Allocator, api_key: []const u8, page_id: []const u8, status_prop: []const u8, status_name: []const u8, status_group: []const u8, loop: *vaxis.Loop(Event)) void {
    notion_api.updatePageStatus(allocator, api_key, page_id, status_prop, status_name) catch {
        loop.postEvent(.{ .status_updated = .{ .err = "Failed to update Notion status" } });
        return;
    };
    // For Notion, use page_id as the issue key
    loop.postEvent(.{ .status_updated = .{ .ok = .{
        .issue_key = page_id,
        .new_state_name = status_name,
        .new_state_type = status_group,
    } } });
}

fn createIssueWorker(allocator: std.mem.Allocator, api_key: []const u8, params: event_mod.CreateParams, loop: *vaxis.Loop(Event)) void {
    defer allocator.free(params.title);
    defer if (params.description) |d| allocator.free(d);
    log.info("createIssueWorker: calling API title={s} team={s}", .{ params.title, params.team_id });
    const issue = linear_api.createIssue(allocator, api_key, params) catch |err| {
        log.info("createIssueWorker: FAILED err={}", .{err});
        loop.postEvent(.{ .issue_created = .{ .err = "Failed to create issue" } });
        return;
    };
    log.info("createIssueWorker: OK identifier={s}", .{issue.identifier});
    loop.postEvent(.{ .issue_created = .{ .ok = issue } });
}

// Pull in all module tests
comptime {
    _ = @import("config.zig");
    _ = @import("issue.zig");
    _ = @import("event.zig");
    _ = @import("markdown.zig");
    _ = @import("state.zig");
    _ = @import("linear_api.zig");
    _ = @import("notion_api.zig");
    _ = @import("render.zig");
    _ = @import("notify.zig");
}

test "smoke" {
    try std.testing.expect(true);
}
