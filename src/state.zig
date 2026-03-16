const std = @import("std");
const vaxis = @import("vaxis");
const log = @import("log.zig");
const event_mod = @import("event.zig");
const issue_mod = @import("issue.zig");
const render = @import("render.zig");

const Event = event_mod.Event;
const Effect = event_mod.Effect;
const Issue = issue_mod.Issue;
const Key = vaxis.Key;

pub const Mode = enum { list, detail, create };

pub const StatusEdit = struct {
    original: []const u8,
    current_idx: usize,
    states: []const event_mod.WorkflowState,
    source: issue_mod.Source,
    identifier: ?[]const u8 = null,
    source_id: ?[]const u8 = null,
    workspace_idx: ?usize = null,
    team_id: ?[]const u8 = null,
    page_id: ?[]const u8 = null,
    group: ?[]const u8 = null,
};

pub const CreateFormField = enum {
    team,
    title,
    body,
    status,
    priority,
    assign_self,
};

pub const CreateForm = struct {
    team_idx: usize = 0,
    title_buf: [256]u8 = [_]u8{0} ** 256,
    title_len: usize = 0,
    body_buf: [4096]u8 = [_]u8{0} ** 4096,
    body_len: usize = 0,
    status_idx: ?usize = null,
    priority: u8 = 0,
    assign_self: bool = true,
    focused_field: CreateFormField = .title,
    title_cursor: usize = 0,
    body_cursor: usize = 0,

    pub fn titleSlice(self: *const CreateForm) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn bodySlice(self: *const CreateForm) []const u8 {
        return self.body_buf[0..self.body_len];
    }
};

pub const MAX_TEAM_STATES = 16;

pub const TeamStateEntry = struct {
    team_id: []const u8,
    states: []const event_mod.WorkflowState,
};

pub const State = struct {
    const max_workspaces = 8;

    mode: Mode = .list,
    issues: []Issue = &.{},
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    loading: bool = true,
    pending_fetches: u16 = 0,
    detail_loading: bool = false,
    error_msg: ?[]const u8 = null,
    editing_status: ?StatusEdit = null,
    teams: []event_mod.Team = &.{},
    viewer_ids: [max_workspaces]?[]const u8 = .{null} ** max_workspaces,
    rows: u16 = 24,
    cols: u16 = 80,
    create_form: ?CreateForm = null,
    ctrl_c_pressed: bool = false,
    allocator: ?std.mem.Allocator = null,

    // Workspace config slices (set during init, reference externally-owned memory)
    linear_api_keys: []const []const u8 = &.{},
    notion_api_keys: []const []const u8 = &.{},
    linear_workspaces: []const []const u8 = &.{},
    linear_desktop_links: []const bool = &.{},
    linear_default_teams: []const []const u8 = &.{},
    default_team: []const u8 = "",
    notion_status_prop: []const u8 = "Status",

    // Team states storage (bounded array)
    team_states_entries: [MAX_TEAM_STATES]?TeamStateEntry = [_]?TeamStateEntry{null} ** MAX_TEAM_STATES,
    team_states_count: usize = 0,

    /// Returns the issue at the given display index (in-progress first, then todo).
    fn issueAtDisplayIndex(self: *const State, target: usize) ?*const Issue {
        var display_idx: usize = 0;
        for (self.issues, 0..) |_, i| {
            if (self.issues[i].isInProgress()) {
                if (display_idx == target) return &self.issues[i];
                display_idx += 1;
            }
        }
        for (self.issues, 0..) |_, i| {
            if (self.issues[i].isTodo()) {
                if (display_idx == target) return &self.issues[i];
                display_idx += 1;
            }
        }
        return null;
    }

    pub fn selectedIssue(self: *const State) ?*const Issue {
        return self.issueAtDisplayIndex(self.selected_index);
    }

    /// Count of visible issues (in-progress + todo, excludes completed).
    pub fn displayCount(self: *const State) usize {
        var count: usize = 0;
        for (self.issues) |iss| {
            if (iss.isInProgress() or iss.isTodo()) count += 1;
        }
        return count;
    }

    /// Find the display index for an issue with the given key.
    pub fn displayIndexForKey(self: *const State, target_key: []const u8) ?usize {
        var display_idx: usize = 0;
        for (self.issues) |iss| {
            if (iss.isInProgress()) {
                if (std.mem.eql(u8, iss.key(), target_key)) return display_idx;
                display_idx += 1;
            }
        }
        for (self.issues) |iss| {
            if (iss.isTodo()) {
                if (std.mem.eql(u8, iss.key(), target_key)) return display_idx;
                display_idx += 1;
            }
        }
        return null;
    }

    pub fn contentWidth(self: *const State) u16 {
        if (self.cols < 4) return 1;
        return self.cols - 4;
    }

    pub fn visibleDetailRows(self: *const State) u16 {
        if (self.rows < 7) return 1;
        return self.rows - 7;
    }

    /// Find the team_id for an issue by matching identifier prefix to team keys.
    pub fn findTeamIdForIssue(self: *const State, iss: *const Issue) ?[]const u8 {
        // Extract prefix from identifier (e.g., "ZES" from "ZES-11")
        const dash_pos = std.mem.indexOf(u8, iss.identifier, "-") orelse return null;
        const prefix = iss.identifier[0..dash_pos];

        for (self.teams) |team| {
            if (std.mem.eql(u8, team.key, prefix)) {
                return team.id;
            }
        }
        return null;
    }

    pub fn clampDetailScroll(self: *State) void {
        if (self.selectedIssue()) |iss| {
            const total_lines = render.countDescriptionLines(iss, self.contentWidth());
            const visible = self.visibleDetailRows();
            if (total_lines > visible) {
                const max_offset = total_lines - visible;
                if (self.scroll_offset > max_offset) {
                    self.scroll_offset = max_offset;
                }
            } else {
                self.scroll_offset = 0;
            }
        }
    }

    pub fn findTeamStates(self: *const State, team_id: []const u8) ?[]const event_mod.WorkflowState {
        for (self.team_states_entries[0..self.team_states_count]) |entry_opt| {
            if (entry_opt) |entry| {
                if (std.mem.eql(u8, entry.team_id, team_id)) {
                    return entry.states;
                }
            }
        }
        return null;
    }
};

pub const MAX_EFFECTS = 8;

pub const UpdateResult = struct {
    state: State,
    effects: [MAX_EFFECTS]?Effect = [_]?Effect{null} ** MAX_EFFECTS,
    effect_count: u8 = 0,

    pub fn withEffect(s: State, eff: Effect) UpdateResult {
        var result = UpdateResult{
            .state = s,
            .effect_count = 1,
        };
        result.effects[0] = eff;
        return result;
    }

    pub fn withEffects2(s: State, eff1: Effect, eff2: Effect) UpdateResult {
        var result = UpdateResult{
            .state = s,
            .effect_count = 2,
        };
        result.effects[0] = eff1;
        result.effects[1] = eff2;
        return result;
    }

    pub fn noEffect(s: State) UpdateResult {
        return .{ .state = s };
    }
};

pub fn update(s: State, evt: Event) UpdateResult {
    return switch (evt) {
        .key_press => |key| handleKey(s, key),
        .winsize => |ws| handleWinsize(s, ws),
        .issues_fetched => |payload| handleIssuesFetched(s, payload),
        .description_fetched => |payload| handleDescriptionFetched(s, payload),
        .poll_tick => handlePollTick(s),
        .status_updated => |payload| handleStatusUpdated(s, payload),
        .teams_fetched => |payload| handleTeamsFetched(s, payload),
        .team_states_fetched => |payload| handleTeamStatesFetched(s, payload),
        .issue_created => |payload| handleIssueCreated(s, payload),
    };
}

fn handleKey(s: State, key: Key) UpdateResult {
    // Ctrl+C twice to quit
    if (key.matches('c', .{ .ctrl = true })) {
        if (s.ctrl_c_pressed) {
            return UpdateResult.withEffect(s, .{ .quit = {} });
        }
        var next = s;
        next.ctrl_c_pressed = true;
        next.error_msg = "Press Ctrl+C again to quit";
        return UpdateResult.noEffect(next);
    }

    var result = blk: {
        if (s.editing_status != null) break :blk handleStatusEditKey(s, key);
        break :blk switch (s.mode) {
            .list => handleListKey(s, key),
            .detail => handleDetailKey(s, key),
            .create => handleCreateKey(s, key),
        };
    };

    // Any other key clears the Ctrl+C state
    if (s.ctrl_c_pressed) {
        result.state.ctrl_c_pressed = false;
        result.state.error_msg = null;
    }

    return result;
}

fn handleWinsize(s: State, ws: vaxis.Winsize) UpdateResult {
    var next = s;
    next.rows = ws.rows;
    next.cols = ws.cols;
    return UpdateResult.noEffect(next);
}

/// Restore selected_index to the issue with the given key, or clamp to bounds.
fn clampSelectedIndex(next: *State, saved_key: []const u8) void {
    if (saved_key.len > 0) {
        if (next.displayIndexForKey(saved_key)) |idx| {
            next.selected_index = idx;
            return;
        }
    }
    const dc = next.displayCount();
    if (dc > 0) {
        if (next.selected_index >= dc) {
            next.selected_index = dc - 1;
        }
    } else {
        next.selected_index = 0;
    }
}

fn handleIssuesFetched(s: State, payload: anytype) UpdateResult {
    var next = s;
    if (next.pending_fetches > 0) {
        next.pending_fetches -= 1;
    }
    if (next.pending_fetches == 0) {
        next.loading = false;
    }

    // Save selected issue key to stack buffer (old issue data may be freed during merge)
    var saved_key_buf: [128]u8 = undefined;
    var saved_key_len: usize = 0;
    if (s.selectedIssue()) |iss| {
        const k = iss.key();
        saved_key_len = @min(k.len, saved_key_buf.len);
        @memcpy(saved_key_buf[0..saved_key_len], k[0..saved_key_len]);
    }

    switch (payload.result) {
        .ok => |new_issues| {
            const alloc = next.allocator orelse {
                // No allocator: fallback to simple replace (tests, etc.)
                next.issues = new_issues;
                clampSelectedIndex(&next, saved_key_buf[0..saved_key_len]);
                return UpdateResult.noEffect(next);
            };

            const old_issues = next.issues;

            if (old_issues.len == 0) {
                // First fetch -- just use the new issues directly
                next.issues = new_issues;
            } else {
                // Count issues to keep (different source or workspace)
                var keep_count: usize = 0;
                for (old_issues) |iss| {
                    const same_source = (iss.source == payload.source);
                    const same_workspace = if (iss.source_workspace_idx) |idx| idx == payload.workspace_idx else false;
                    if (!(same_source and same_workspace)) {
                        keep_count += 1;
                    }
                }

                const merged = alloc.alloc(Issue, keep_count + new_issues.len) catch {
                    // Allocation failed: just use new issues, leaking old
                    next.issues = new_issues;
                    return UpdateResult.noEffect(next);
                };

                // Copy kept issues, preserving descriptions
                var idx: usize = 0;
                for (old_issues) |iss| {
                    const same_source = (iss.source == payload.source);
                    const same_workspace = if (iss.source_workspace_idx) |wi| wi == payload.workspace_idx else false;
                    if (!(same_source and same_workspace)) {
                        merged[idx] = iss;
                        idx += 1;
                    } else {
                        // This issue is being replaced -- transfer cached description
                        // to matching new issue if one exists, then free old strings
                        // Transfer cached description to matching new issue
                        if (iss.description) |cached_desc| {
                            var transferred = false;
                            for (new_issues) |*ni| {
                                if (std.mem.eql(u8, ni.key(), iss.key())) {
                                    if (ni.description == null) {
                                        ni.description = cached_desc;
                                        transferred = true;
                                    }
                                    break;
                                }
                            }
                            if (!transferred) {
                                alloc.free(cached_desc);
                            }
                        }
                        // Transfer cached comments to matching new issue
                        if (iss.comments) |cached_comments| {
                            var transferred = false;
                            for (new_issues) |*ni| {
                                if (std.mem.eql(u8, ni.key(), iss.key())) {
                                    if (ni.comments == null) {
                                        ni.comments = cached_comments;
                                        transferred = true;
                                    }
                                    break;
                                }
                            }
                            if (!transferred) {
                                for (cached_comments) |c| {
                                    alloc.free(c.author);
                                    alloc.free(c.body);
                                    alloc.free(c.created_at);
                                }
                                alloc.free(cached_comments);
                            }
                        }
                        // Free old issue strings (except description/comments, handled above)
                        alloc.free(iss.identifier);
                        alloc.free(iss.title);
                        alloc.free(iss.state_name);
                        if (iss.updated_at) |ua| alloc.free(ua);
                        if (iss.source_id) |sid| alloc.free(sid);
                        if (iss.source_url) |su| alloc.free(su);
                    }
                }

                // Copy new issues
                for (new_issues) |ni| {
                    merged[idx] = ni;
                    idx += 1;
                }

                // Free old slices (the slice itself, not the element strings -- those are handled above)
                alloc.free(old_issues);
                // Free the new_issues slice container (elements are now in merged)
                alloc.free(new_issues);

                // Sort: priority (urgent→high→medium→none→low), then workspace ascending, then updated_at descending
                std.mem.sort(Issue, merged[0..idx], {}, struct {
                    fn cmp(_: void, a: Issue, b: Issue) bool {
                        const a_pri = a.priority_label.sortOrder();
                        const b_pri = b.priority_label.sortOrder();
                        if (a_pri != b_pri) return a_pri < b_pri;
                        const a_ws = a.source_workspace_idx orelse 0;
                        const b_ws = b.source_workspace_idx orelse 0;
                        if (a_ws != b_ws) return a_ws < b_ws;
                        const a_ts = a.updated_at orelse "";
                        const b_ts = b.updated_at orelse "";
                        return std.mem.order(u8, a_ts, b_ts) == .gt;
                    }
                }.cmp);

                next.issues = merged;
            }

            // Restore selection to the same issue, or clamp
            clampSelectedIndex(&next, saved_key_buf[0..saved_key_len]);
        },
        .err => |msg| {
            next.error_msg = msg;
        },
    }

    return UpdateResult.noEffect(next);
}

fn handleDescriptionFetched(s: State, payload: anytype) UpdateResult {
    var next = s;
    next.detail_loading = false;

    switch (payload.result) {
        .ok => |data| {
            // Find the issue by key and update its description + comments
            for (next.issues) |*iss| {
                if (std.mem.eql(u8, iss.key(), payload.issue_key)) {
                    // Free old description/comments if re-fetched
                    if (next.allocator) |alloc| {
                        if (iss.description) |old_desc| alloc.free(old_desc);
                        if (iss.comments) |old_comments| {
                            for (old_comments) |c| {
                                alloc.free(c.author);
                                alloc.free(c.body);
                                alloc.free(c.created_at);
                            }
                            alloc.free(old_comments);
                        }
                    }
                    iss.description = data.description;
                    iss.comments = data.comments;
                    break;
                }
            }
        },
        .err => {
            // Silently ignore description fetch errors
        },
    }

    return UpdateResult.noEffect(next);
}

fn handlePollTick(s: State) UpdateResult {
    var result = UpdateResult{ .state = s, .effect_count = 0 };

    // Queue fetch effects for all workspaces
    for (s.linear_api_keys, 0..) |api_key, i| {
        if (result.effect_count < MAX_EFFECTS) {
            result.effects[result.effect_count] = .{ .fetch_linear_issues = .{ .workspace_idx = i, .api_key = api_key } };
            result.effect_count += 1;
        }
    }
    for (s.notion_api_keys, 0..) |api_key, i| {
        if (result.effect_count < MAX_EFFECTS) {
            result.effects[result.effect_count] = .{ .fetch_notion_issues = .{ .workspace_idx = i, .api_key = api_key } };
            result.effect_count += 1;
        }
    }

    const total_fetches = s.linear_api_keys.len + s.notion_api_keys.len;
    if (total_fetches <= std.math.maxInt(u16)) {
        result.state.pending_fetches = @intCast(total_fetches);
    }

    return result;
}

fn handleStatusUpdated(s: State, payload: event_mod.StatusUpdateResult) UpdateResult {
    switch (payload) {
        .ok => |data| {
            var next = s;
            // Remember which issue is selected before mutation
            const prev_key = if (s.selectedIssue()) |iss| iss.key() else null;

            // Find issue by key and update its state
            for (next.issues) |*iss| {
                if (std.mem.eql(u8, iss.identifier, data.issue_key)) {
                    // Dupe new name so the issue owns it, free the old one
                    if (next.allocator) |alloc| {
                        const duped = alloc.dupe(u8, data.new_state_name) catch break;
                        alloc.free(iss.state_name);
                        iss.state_name = duped;
                    } else {
                        iss.state_name = data.new_state_name;
                    }
                    iss.state_type = issue_mod.StateType.fromString(data.new_state_type);
                    break;
                }
            }

            // Restore selection to the same issue (it may have moved in display order)
            if (prev_key) |key| {
                if (next.displayIndexForKey(key)) |idx| {
                    next.selected_index = idx;
                }
            }

            return UpdateResult.noEffect(next);
        },
        .err => {
            return UpdateResult.noEffect(s);
        },
    }
}

fn freeTeam(alloc: std.mem.Allocator, team: event_mod.Team) void {
    alloc.free(team.id);
    alloc.free(team.name);
    alloc.free(team.key);
}

fn teamSortPriority(team: event_mod.Team, global_default: []const u8, workspace_defaults: []const []const u8) u8 {
    if (global_default.len > 0 and std.mem.eql(u8, team.name, global_default)) return 0;
    if (team.workspace_idx < workspace_defaults.len) {
        const ws_default = workspace_defaults[team.workspace_idx];
        if (ws_default.len > 0 and std.mem.eql(u8, team.name, ws_default)) return 1;
    }
    return 2;
}

fn sortTeams(teams: []event_mod.Team, global_default: []const u8, workspace_defaults: []const []const u8) void {
    if (teams.len <= 1) return;

    const Ctx = struct { gd: []const u8, wd: []const []const u8 };
    std.mem.sort(event_mod.Team, teams, Ctx{ .gd = global_default, .wd = workspace_defaults }, struct {
        fn cmp(ctx: Ctx, a: event_mod.Team, b: event_mod.Team) bool {
            return teamSortPriority(a, ctx.gd, ctx.wd) < teamSortPriority(b, ctx.gd, ctx.wd);
        }
    }.cmp);
}

fn handleTeamsFetched(s: State, payload: anytype) UpdateResult {
    switch (payload.result) {
        .ok => |data| {
            var next = s;
            next.error_msg = null;
            if (payload.workspace_idx < State.max_workspaces) {
                if (next.viewer_ids[payload.workspace_idx]) |old| {
                    if (next.allocator) |alloc| alloc.free(old);
                }
                next.viewer_ids[payload.workspace_idx] = data.viewer_id;
            } else if (next.allocator) |alloc| {
                alloc.free(data.viewer_id);
            }

            // Stamp workspace_idx on incoming teams
            for (data.teams) |*t| {
                t.workspace_idx = payload.workspace_idx;
            }

            // Merge new teams with existing (avoid duplicates by id)
            const old_len = next.teams.len;
            if (old_len == 0) {
                next.teams = data.teams;
            } else if (data.teams.len > 0) {
                if (next.allocator) |alloc| {
                    // Count new teams not already present
                    var new_count: usize = 0;
                    for (data.teams) |new_team| {
                        var found = false;
                        for (next.teams) |existing| {
                            if (std.mem.eql(u8, existing.id, new_team.id)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) new_count += 1;
                    }
                    if (new_count > 0) {
                        const merged = alloc.alloc(event_mod.Team, next.teams.len + new_count) catch {
                            alloc.free(data.teams);
                            return UpdateResult.noEffect(next);
                        };
                        @memcpy(merged[0..next.teams.len], next.teams);
                        var idx: usize = next.teams.len;
                        for (data.teams) |new_team| {
                            var found = false;
                            for (next.teams) |existing| {
                                if (std.mem.eql(u8, existing.id, new_team.id)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                merged[idx] = new_team;
                                idx += 1;
                            } else {
                                freeTeam(alloc, new_team);
                            }
                        }
                        alloc.free(next.teams);
                        next.teams = merged;
                    } else {
                        // All duplicates — free all incoming team strings
                        for (data.teams) |new_team| {
                            freeTeam(alloc, new_team);
                        }
                    }
                    alloc.free(data.teams);
                } else {
                    next.teams = data.teams;
                }
            }

            // Sort teams: global default first, then workspace defaults, then rest
            sortTeams(next.teams, next.default_team, next.linear_default_teams);

            // Fetch team states only for teams belonging to this workspace
            const api_key = if (payload.workspace_idx < next.linear_api_keys.len)
                next.linear_api_keys[payload.workspace_idx]
            else
                null;

            if (api_key) |ak| {
                var result = UpdateResult{ .state = next };
                var effect_idx: usize = 0;
                for (next.teams) |team| {
                    if (team.workspace_idx == payload.workspace_idx and effect_idx < MAX_EFFECTS) {
                        result.effects[effect_idx] = .{ .fetch_team_states = .{
                            .api_key = ak,
                            .team_id = team.id,
                        } };
                        effect_idx += 1;
                    }
                }
                result.effect_count = @intCast(effect_idx);
                if (effect_idx > 0) return result;
            }

            return UpdateResult.noEffect(next);
        },
        .err => {
            return UpdateResult.noEffect(s);
        },
    }
}

fn handleTeamStatesFetched(s: State, payload: anytype) UpdateResult {
    var next = s;
    next.error_msg = null; // Clear any "Loading statuses..." message

    switch (payload.result) {
        .ok => |states| {
            // Check if we already have states for this team, update if so
            var found = false;
            for (next.team_states_entries[0..next.team_states_count]) |*entry_opt| {
                if (entry_opt.*) |*entry| {
                    if (std.mem.eql(u8, entry.team_id, payload.team_id)) {
                        // Free old states before replacing
                        if (next.allocator) |alloc| {
                            for (entry.states) |ws| {
                                alloc.free(ws.id);
                                alloc.free(ws.name);
                                alloc.free(ws.state_type);
                            }
                            alloc.free(entry.states);
                        }
                        entry.states = states;
                        found = true;
                        break;
                    }
                }
            }
            if (!found and next.team_states_count < MAX_TEAM_STATES) {
                next.team_states_entries[next.team_states_count] = .{
                    .team_id = payload.team_id,
                    .states = states,
                };
                next.team_states_count += 1;
            }
        },
        .err => {
            // Silently ignore team states fetch errors
        },
    }

    return UpdateResult.noEffect(next);
}

fn handleIssueCreated(s: State, payload: event_mod.CreateResult) UpdateResult {
    switch (payload) {
        .ok => |created_issue| {
            var next = s;
            // Free the created issue's heap strings (the issue will appear on next refresh)
            if (next.allocator) |alloc| {
                issue_mod.freeIssue(alloc, created_issue);
            }
            next.mode = .list;
            next.create_form = null;
            return UpdateResult.noEffect(next);
        },
        .err => {
            var next = s;
            next.error_msg = "Failed to create issue";
            return UpdateResult.noEffect(next);
        },
    }
}

fn handleListKey(s: State, key: Key) UpdateResult {
    var next = s;
    const len = next.displayCount();

    if (key.matches('j', .{}) or key.matches(Key.down, .{}) or key.matches(Key.tab, .{})) {
        if (len > 0 and next.selected_index < len - 1) {
            next.selected_index += 1;
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('k', .{}) or key.matches(Key.up, .{}) or key.matches(Key.tab, .{ .shift = true })) {
        if (next.selected_index > 0) {
            next.selected_index -= 1;
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('G', .{}) or key.matches('G', .{ .shift = true })) {
        if (len > 0) {
            next.selected_index = len - 1;
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('g', .{})) {
        next.selected_index = 0;
        return UpdateResult.noEffect(next);
    }

    if (key.matches('d', .{ .ctrl = true }) or key.matches(Key.page_down, .{})) {
        if (len > 0) {
            const half = @max(next.rows / 2, 1);
            next.selected_index = @min(next.selected_index + half, len - 1);
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('u', .{ .ctrl = true }) or key.matches(Key.page_up, .{})) {
        const half = @max(next.rows / 2, 1);
        if (next.selected_index >= half) {
            next.selected_index -= half;
        } else {
            next.selected_index = 0;
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches(Key.enter, .{})) {
        next.mode = .detail;
        next.scroll_offset = 0;

        // If selected issue has no description, trigger a fetch
        if (next.selectedIssue()) |iss| {
            if (iss.description == null) {
                next.detail_loading = true;
                // Determine API key based on source
                const api_key = switch (iss.source) {
                    .linear => blk: {
                        const ws_idx = iss.source_workspace_idx orelse 0;
                        if (ws_idx < next.linear_api_keys.len) {
                            break :blk next.linear_api_keys[ws_idx];
                        }
                        break :blk null;
                    },
                    .notion => blk: {
                        const ws_idx = iss.source_workspace_idx orelse 0;
                        if (ws_idx < next.notion_api_keys.len) {
                            break :blk next.notion_api_keys[ws_idx];
                        }
                        break :blk null;
                    },
                };
                if (api_key) |ak| {
                    return UpdateResult.withEffect(next, .{ .fetch_description = .{
                        .source = iss.source,
                        .api_key = ak,
                        .issue_key = iss.key(),
                    } });
                }
            }
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('q', .{}) or key.matches(Key.escape, .{})) {
        return UpdateResult.withEffect(next, .{ .quit = {} });
    }

    if (key.matches('c', .{})) {
        next.mode = .create;
        if (next.create_form == null) {
            next.create_form = CreateForm{};
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('o', .{})) {
        if (next.selectedIssue()) |iss| {
            return openIssueUrl(&next, iss);
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('r', .{})) {
        return handlePollTick(next);
    }

    return UpdateResult.noEffect(next);
}

fn openIssueUrl(next: *State, iss: *const Issue) UpdateResult {
    const alloc = next.allocator orelse return UpdateResult.noEffect(next.*);
    switch (iss.source) {
        .linear => {
            const ws_idx = iss.source_workspace_idx orelse 0;
            if (ws_idx < next.linear_workspaces.len) {
                const workspace = next.linear_workspaces[ws_idx];
                const use_desktop = if (ws_idx < next.linear_desktop_links.len) next.linear_desktop_links[ws_idx] else false;
                const protocol: []const u8 = if (use_desktop) "linear://" else "https://linear.app/";
                const url = std.fmt.allocPrint(alloc, "{s}{s}/issue/{s}", .{ protocol, workspace, iss.identifier }) catch return UpdateResult.noEffect(next.*);
                return UpdateResult.withEffect(next.*, .{ .open_url = url });
            }
        },
        .notion => {
            if (iss.source_url) |url| {
                // Dupe so dispatchEffect can always free the URL
                const duped = alloc.dupe(u8, url) catch return UpdateResult.noEffect(next.*);
                return UpdateResult.withEffect(next.*, .{ .open_url = duped });
            }
        },
    }
    return UpdateResult.noEffect(next.*);
}

fn handleDetailKey(s: State, key: Key) UpdateResult {
    var next = s;

    if (key.matches('q', .{}) or key.matches(Key.backspace, .{})) {
        next.mode = .list;
        return UpdateResult.noEffect(next);
    }

    if (key.matches(Key.escape, .{})) {
        next.mode = .list;
        next.scroll_offset = 0;
        return UpdateResult.noEffect(next);
    }

    if (key.matches('j', .{}) or key.matches(Key.down, .{}) or key.matches(Key.tab, .{})) {
        next.scroll_offset += 1;
        next.clampDetailScroll();
        return UpdateResult.noEffect(next);
    }

    if (key.matches('k', .{}) or key.matches(Key.up, .{}) or key.matches(Key.tab, .{ .shift = true })) {
        if (next.scroll_offset > 0) {
            next.scroll_offset -= 1;
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('f', .{}) or key.matches(Key.space, .{}) or key.matches('d', .{ .ctrl = true }) or key.matches(Key.page_down, .{})) {
        const half: usize = @max(next.rows / 2, 1);
        next.scroll_offset += half;
        next.clampDetailScroll();
        return UpdateResult.noEffect(next);
    }

    if (key.matches('b', .{}) or key.matches('u', .{ .ctrl = true }) or key.matches(Key.page_up, .{})) {
        const half: usize = @max(next.rows / 2, 1);
        if (next.scroll_offset >= half) {
            next.scroll_offset -= half;
        } else {
            next.scroll_offset = 0;
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('s', .{})) {
        // Enter status edit mode
        next.error_msg = null;
        if (next.selectedIssue()) |iss| {
            switch (iss.source) {
                .linear => {
                    if (next.teams.len == 0) {
                        next.error_msg = "Loading teams...";
                        return UpdateResult.noEffect(next);
                    }
                    const team_id = next.findTeamIdForIssue(iss) orelse {
                        next.error_msg = "Team not found for issue";
                        return UpdateResult.noEffect(next);
                    };
                    if (next.findTeamStates(team_id)) |states| {
                        var current_idx: usize = 0;
                        for (states, 0..) |ws, idx| {
                            if (std.mem.eql(u8, ws.name, iss.state_name)) {
                                current_idx = idx;
                                break;
                            }
                        }
                        next.editing_status = .{
                            .original = iss.state_name,
                            .current_idx = current_idx,
                            .states = states,
                            .source = .linear,
                            .identifier = iss.identifier,
                            .source_id = iss.source_id,
                            .workspace_idx = iss.source_workspace_idx,
                            .team_id = team_id,
                        };
                    } else {
                        next.error_msg = "Loading statuses...";
                        const ws_idx = iss.source_workspace_idx orelse 0;
                        if (ws_idx < next.linear_api_keys.len) {
                            return UpdateResult.withEffect(next, .{ .fetch_team_states = .{
                                .api_key = next.linear_api_keys[ws_idx],
                                .team_id = team_id,
                            } });
                        }
                    }
                },
                .notion => {
                    next.error_msg = "Status editing not supported for Notion";
                },
            }
        }
        return UpdateResult.noEffect(next);
    }

    if (key.matches('o', .{})) {
        if (next.selectedIssue()) |iss| {
            return openIssueUrl(&next, iss);
        }
        return UpdateResult.noEffect(next);
    }

    return UpdateResult.noEffect(next);
}

fn handleStatusEditKey(s: State, key: Key) UpdateResult {
    var next = s;
    var edit = next.editing_status.?;
    const num_states = edit.states.len;

    if (key.matches('l', .{}) or key.matches(Key.right, .{})) {
        if (num_states > 0) {
            edit.current_idx = (edit.current_idx + 1) % num_states;
        }
        next.editing_status = edit;
        return UpdateResult.noEffect(next);
    }

    if (key.matches('h', .{}) or key.matches(Key.left, .{})) {
        if (num_states > 0) {
            if (edit.current_idx == 0) {
                edit.current_idx = num_states - 1;
            } else {
                edit.current_idx -= 1;
            }
        }
        next.editing_status = edit;
        return UpdateResult.noEffect(next);
    }

    if (key.matches(Key.enter, .{})) {
        // Confirm: apply the status change and emit an effect
        if (num_states > 0) {
            const selected_state = edit.states[edit.current_idx];
            // Only emit effect if the status actually changed
            if (!std.mem.eql(u8, selected_state.name, edit.original)) {
                next.editing_status = null;
                switch (edit.source) {
                    .linear => {
                        if (edit.source_id) |issue_id| {
                            // Get api key for the issue's workspace
                            const ws_idx = edit.workspace_idx orelse 0;
                            const api_key = if (ws_idx < next.linear_api_keys.len) next.linear_api_keys[ws_idx] else null;
                            if (api_key) |ak| {
                                return UpdateResult.withEffect(next, .{ .update_linear_status = .{
                                    .api_key = ak,
                                    .issue_id = issue_id,
                                    .identifier = edit.identifier orelse issue_id,
                                    .state_id = selected_state.id,
                                    .state_name = selected_state.name,
                                    .state_type = selected_state.state_type,
                                } });
                            }
                        }
                    },
                    .notion => {
                        // TODO: Notion status update
                    },
                }
                return UpdateResult.noEffect(next);
            }
        }
        next.editing_status = null;
        return UpdateResult.noEffect(next);
    }

    // Esc or any other key: cancel
    next.editing_status = null;
    return UpdateResult.noEffect(next);
}

fn handleCreateKey(s: State, key: Key) UpdateResult {
    var next = s;
    var form = next.create_form orelse return UpdateResult.noEffect(next);

    // Esc or q (on non-text fields): back to list, preserve form
    if (key.matches(Key.escape, .{}) or
        (key.matches('q', .{}) and form.focused_field != .title and form.focused_field != .body))
    {
        next.mode = .list;
        return UpdateResult.noEffect(next);
    }

    // Ctrl+S: submit
    if (key.matches('s', .{ .ctrl = true })) {
        // Validate: title must not be empty
        if (form.title_len == 0) {
            return UpdateResult.noEffect(next);
        }
        // Build create params
        const team = if (next.teams.len > 0 and form.team_idx < next.teams.len)
            next.teams[form.team_idx]
        else
            return UpdateResult.noEffect(next);

        const state_id: ?[]const u8 = blk: {
            if (form.status_idx) |sidx| {
                if (next.findTeamStates(team.id)) |states| {
                    if (sidx < states.len) {
                        break :blk states[sidx].id;
                    }
                }
            }
            break :blk null;
        };

        const assignee_id: ?[]const u8 = if (form.assign_self and team.workspace_idx < State.max_workspaces)
            next.viewer_ids[team.workspace_idx]
        else
            null;
        const api_key = if (team.workspace_idx < next.linear_api_keys.len)
            next.linear_api_keys[team.workspace_idx]
        else
            null;

        if (api_key) |ak| {
            // Write form back to next so slices reference returned state memory
            next.create_form = form;
            return UpdateResult.withEffect(next, .{ .create_issue = .{
                .api_key = ak,
                .params = .{
                    .title = next.create_form.?.titleSlice(),
                    .team_id = team.id,
                    .description = if (form.body_len > 0) next.create_form.?.bodySlice() else null,
                    .state_id = state_id,
                    .assignee_id = assignee_id,
                    .priority = form.priority,
                },
            } });
        }
        return UpdateResult.noEffect(next);
    }

    // Tab, Down, or j (on non-text fields): next field
    if (key.matches(Key.tab, .{}) or key.matches(Key.down, .{}) or
        (key.matches('j', .{}) and form.focused_field != .title and form.focused_field != .body))
    {
        form.focused_field = nextField(form.focused_field);
        next.create_form = form;
        return UpdateResult.noEffect(next);
    }

    // Shift-Tab, Up, or k (on non-text fields): prev field
    if (key.matches(Key.tab, .{ .shift = true }) or key.matches(Key.up, .{}) or
        (key.matches('k', .{}) and form.focused_field != .title and form.focused_field != .body))
    {
        form.focused_field = prevField(form.focused_field);
        next.create_form = form;
        return UpdateResult.noEffect(next);
    }

    // Handle field-specific keys
    switch (form.focused_field) {
        .team => {
            if (key.matches('h', .{}) or key.matches(Key.left, .{})) {
                if (next.teams.len > 0) {
                    if (form.team_idx == 0) {
                        form.team_idx = next.teams.len - 1;
                    } else {
                        form.team_idx -= 1;
                    }
                }
            } else if (key.matches('l', .{}) or key.matches(Key.right, .{})) {
                if (next.teams.len > 0) {
                    form.team_idx = (form.team_idx + 1) % next.teams.len;
                }
            }
        },
        .title => {
            if (key.matches(Key.backspace, .{})) {
                if (form.title_cursor > 0 and form.title_len > 0) {
                    // Delete char before cursor
                    const cursor = form.title_cursor;
                    if (cursor < form.title_len) {
                        std.mem.copyForwards(u8, form.title_buf[cursor - 1 .. form.title_len - 1], form.title_buf[cursor..form.title_len]);
                    }
                    form.title_len -= 1;
                    form.title_cursor -= 1;
                }
            } else if (key.matches(Key.left, .{})) {
                if (form.title_cursor > 0) form.title_cursor -= 1;
            } else if (key.matches(Key.right, .{})) {
                if (form.title_cursor < form.title_len) form.title_cursor += 1;
            } else if (key.codepoint >= 32 and key.codepoint < 127 and !key.mods.ctrl and !key.mods.alt) {
                // Insert printable char at cursor
                if (form.title_len < form.title_buf.len) {
                    // Shift chars right
                    const cursor = form.title_cursor;
                    if (cursor < form.title_len) {
                        std.mem.copyBackwards(u8, form.title_buf[cursor + 1 .. form.title_len + 1], form.title_buf[cursor..form.title_len]);
                    }
                    form.title_buf[cursor] = @intCast(key.codepoint);
                    form.title_len += 1;
                    form.title_cursor += 1;
                }
            }
        },
        .body => {
            if (key.matches(Key.backspace, .{})) {
                if (form.body_cursor > 0 and form.body_len > 0) {
                    const cursor = form.body_cursor;
                    if (cursor < form.body_len) {
                        std.mem.copyForwards(u8, form.body_buf[cursor - 1 .. form.body_len - 1], form.body_buf[cursor..form.body_len]);
                    }
                    form.body_len -= 1;
                    form.body_cursor -= 1;
                }
            } else if (key.matches(Key.enter, .{})) {
                // Insert newline
                if (form.body_len < form.body_buf.len) {
                    const cursor = form.body_cursor;
                    if (cursor < form.body_len) {
                        std.mem.copyBackwards(u8, form.body_buf[cursor + 1 .. form.body_len + 1], form.body_buf[cursor..form.body_len]);
                    }
                    form.body_buf[cursor] = '\n';
                    form.body_len += 1;
                    form.body_cursor += 1;
                }
            } else if (key.matches(Key.left, .{})) {
                if (form.body_cursor > 0) form.body_cursor -= 1;
            } else if (key.matches(Key.right, .{})) {
                if (form.body_cursor < form.body_len) form.body_cursor += 1;
            } else if (key.codepoint >= 32 and key.codepoint < 127 and !key.mods.ctrl and !key.mods.alt) {
                if (form.body_len < form.body_buf.len) {
                    const cursor = form.body_cursor;
                    if (cursor < form.body_len) {
                        std.mem.copyBackwards(u8, form.body_buf[cursor + 1 .. form.body_len + 1], form.body_buf[cursor..form.body_len]);
                    }
                    form.body_buf[cursor] = @intCast(key.codepoint);
                    form.body_len += 1;
                    form.body_cursor += 1;
                }
            }
        },
        .status => {
            if (key.matches('h', .{}) or key.matches(Key.left, .{})) {
                if (form.status_idx) |*idx| {
                    if (idx.* > 0) idx.* -= 1;
                } else {
                    form.status_idx = 0;
                }
            } else if (key.matches('l', .{}) or key.matches(Key.right, .{})) {
                if (form.status_idx) |*idx| {
                    idx.* += 1;
                    // Clamp will be done at render time based on available states
                } else {
                    form.status_idx = 1;
                }
            }
        },
        .priority => {
            if (key.matches('h', .{}) or key.matches(Key.left, .{})) {
                if (form.priority > 0) form.priority -= 1;
            } else if (key.matches('l', .{}) or key.matches(Key.right, .{})) {
                if (form.priority < 4) form.priority += 1;
            }
        },
        .assign_self => {
            if (key.matches('h', .{}) or key.matches(Key.left, .{}) or
                key.matches('l', .{}) or key.matches(Key.right, .{}) or
                key.matches(Key.space, .{}))
            {
                form.assign_self = !form.assign_self;
            }
        },
    }

    next.create_form = form;
    return UpdateResult.noEffect(next);
}

fn nextField(f: CreateFormField) CreateFormField {
    return switch (f) {
        .team => .title,
        .title => .status,
        .status => .priority,
        .priority => .assign_self,
        .assign_self => .body,
        .body => .team,
    };
}

fn prevField(f: CreateFormField) CreateFormField {
    return switch (f) {
        .team => .body,
        .title => .team,
        .status => .title,
        .priority => .status,
        .assign_self => .priority,
        .body => .assign_self,
    };
}

// --- Tests ---

const testing = std.testing;

fn makeTestIssue(id: []const u8, title: []const u8) Issue {
    return .{
        .identifier = id,
        .title = title,
        .state_name = "In Progress",
        .state_type = .started,
        .priority_label = .high,
    };
}

fn stateWithIssues(issues: []Issue) State {
    return .{
        .mode = .list,
        .issues = issues,
        .selected_index = 0,
        .loading = false,
    };
}

fn keyEvent(cp: u21) Event {
    return .{ .key_press = .{ .codepoint = cp } };
}

fn keyEventMods(cp: u21, mods: Key.Modifiers) Event {
    return .{ .key_press = .{ .codepoint = cp, .mods = mods } };
}

test "j moves selection down in list mode" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
        makeTestIssue("A-2", "Second"),
        makeTestIssue("A-3", "Third"),
    };
    const s = stateWithIssues(&issues);
    const result = update(s, keyEvent('j'));
    try testing.expectEqual(@as(usize, 1), result.state.selected_index);
}

test "j at end stays at end" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
        makeTestIssue("A-2", "Second"),
    };
    var s = stateWithIssues(&issues);
    s.selected_index = 1;
    const result = update(s, keyEvent('j'));
    try testing.expectEqual(@as(usize, 1), result.state.selected_index);
}

test "k moves up" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
        makeTestIssue("A-2", "Second"),
    };
    var s = stateWithIssues(&issues);
    s.selected_index = 1;
    const result = update(s, keyEvent('k'));
    try testing.expectEqual(@as(usize, 0), result.state.selected_index);
}

test "G jumps to end" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
        makeTestIssue("A-2", "Second"),
        makeTestIssue("A-3", "Third"),
    };
    const s = stateWithIssues(&issues);
    const result = update(s, keyEvent('G'));
    try testing.expectEqual(@as(usize, 2), result.state.selected_index);
}

test "g jumps to start" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
        makeTestIssue("A-2", "Second"),
    };
    var s = stateWithIssues(&issues);
    s.selected_index = 1;
    const result = update(s, keyEvent('g'));
    try testing.expectEqual(@as(usize, 0), result.state.selected_index);
}

test "Enter switches to detail mode" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    var s = stateWithIssues(&issues);
    s.scroll_offset = 5;
    const result = update(s, keyEvent(Key.enter));
    try testing.expectEqual(Mode.detail, result.state.mode);
    try testing.expectEqual(@as(usize, 0), result.state.scroll_offset);
}

test "q in list emits quit effect" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    const s = stateWithIssues(&issues);
    const result = update(s, keyEvent('q'));
    try testing.expectEqual(@as(u8, 1), result.effect_count);
    try testing.expectEqual(Effect{ .quit = {} }, result.effects[0].?);
}

test "q in detail returns to list" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    var s = stateWithIssues(&issues);
    s.mode = .detail;
    const result = update(s, keyEvent('q'));
    try testing.expectEqual(Mode.list, result.state.mode);
}

test "Esc in detail returns to list" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    var s = stateWithIssues(&issues);
    s.mode = .detail;
    const result = update(s, keyEvent(Key.escape));
    try testing.expectEqual(Mode.list, result.state.mode);
    try testing.expectEqual(@as(u8, 0), result.effect_count);
}

test "j in detail scrolls down" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    // Give the issue a description long enough to scroll
    issues[0].description = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\nline16\nline17\nline18\nline19\nline20\nline21\nline22\nline23\nline24\nline25\nline26\nline27\nline28\nline29\nline30";
    var s = stateWithIssues(&issues);
    s.mode = .detail;
    const result = update(s, keyEvent('j'));
    try testing.expectEqual(@as(usize, 1), result.state.scroll_offset);
}

test "k in detail at 0 stays at 0" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    var s = stateWithIssues(&issues);
    s.mode = .detail;
    s.scroll_offset = 0;
    const result = update(s, keyEvent('k'));
    try testing.expectEqual(@as(usize, 0), result.state.scroll_offset);
}

test "Status edit: l cycles right" {
    var workflow_states = [_]event_mod.WorkflowState{
        .{ .id = "s1", .name = "Todo", .state_type = "unstarted" },
        .{ .id = "s2", .name = "In Progress", .state_type = "started" },
        .{ .id = "s3", .name = "Done", .state_type = "completed" },
    };
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    var s = stateWithIssues(&issues);
    s.editing_status = .{
        .original = "Todo",
        .current_idx = 0,
        .states = &workflow_states,
        .source = .linear,
    };
    const result = update(s, keyEvent('l'));
    try testing.expectEqual(@as(usize, 1), result.state.editing_status.?.current_idx);
}

test "Status edit: h wraps left" {
    var workflow_states = [_]event_mod.WorkflowState{
        .{ .id = "s1", .name = "Todo", .state_type = "unstarted" },
        .{ .id = "s2", .name = "In Progress", .state_type = "started" },
        .{ .id = "s3", .name = "Done", .state_type = "completed" },
    };
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    var s = stateWithIssues(&issues);
    s.editing_status = .{
        .original = "Todo",
        .current_idx = 0,
        .states = &workflow_states,
        .source = .linear,
    };
    const result = update(s, keyEvent('h'));
    try testing.expectEqual(@as(usize, 2), result.state.editing_status.?.current_idx);
}

test "Status edit: enter confirms (clears editing_status)" {
    var workflow_states = [_]event_mod.WorkflowState{
        .{ .id = "s1", .name = "Todo", .state_type = "unstarted" },
        .{ .id = "s2", .name = "In Progress", .state_type = "started" },
    };
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    var s = stateWithIssues(&issues);
    s.editing_status = .{
        .original = "Todo",
        .current_idx = 1,
        .states = &workflow_states,
        .source = .linear,
    };
    const result = update(s, keyEvent(Key.enter));
    try testing.expect(result.state.editing_status == null);
}

test "Status edit: esc cancels (clears editing_status)" {
    var workflow_states = [_]event_mod.WorkflowState{
        .{ .id = "s1", .name = "Todo", .state_type = "unstarted" },
        .{ .id = "s2", .name = "In Progress", .state_type = "started" },
    };
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    var s = stateWithIssues(&issues);
    s.editing_status = .{
        .original = "Todo",
        .current_idx = 0,
        .states = &workflow_states,
        .source = .linear,
    };
    const result = update(s, keyEvent(Key.escape));
    try testing.expect(result.state.editing_status == null);
}

test "winsize updates dimensions" {
    const s = State{};
    const result = update(s, .{ .winsize = .{ .rows = 50, .cols = 120, .x_pixel = 0, .y_pixel = 0 } });
    try testing.expectEqual(@as(u16, 50), result.state.rows);
    try testing.expectEqual(@as(u16, 120), result.state.cols);
}

test "Ctrl+D pages down by half screen" {
    var issues_arr: [30]Issue = undefined;
    for (&issues_arr) |*iss| {
        iss.* = makeTestIssue("A-1", "Issue");
    }
    var s = stateWithIssues(&issues_arr);
    s.rows = 24; // half = 12
    s.selected_index = 5;
    const result = update(s, keyEventMods('d', .{ .ctrl = true }));
    try testing.expectEqual(@as(usize, 17), result.state.selected_index); // 5 + 12
}

// --- Task 13 tests ---

test "issues_fetched with ok decrements pending and stores issues" {
    var new_issues = [_]Issue{
        makeTestIssue("B-1", "New Issue"),
    };
    const s = State{
        .loading = true,
        .pending_fetches = 2,
    };
    const result = update(s, .{ .issues_fetched = .{
        .source = .linear,
        .workspace_idx = 0,
        .result = .{ .ok = &new_issues },
    } });
    try testing.expectEqual(@as(u16, 1), result.state.pending_fetches);
    try testing.expect(result.state.loading);
    try testing.expectEqual(@as(usize, 1), result.state.issues.len);
    try testing.expectEqualStrings("B-1", result.state.issues[0].identifier);
}

test "issues_fetched when pending reaches 0 sets loading=false" {
    var new_issues = [_]Issue{
        makeTestIssue("B-1", "New Issue"),
    };
    const s = State{
        .loading = true,
        .pending_fetches = 1,
    };
    const result = update(s, .{ .issues_fetched = .{
        .source = .linear,
        .workspace_idx = 0,
        .result = .{ .ok = &new_issues },
    } });
    try testing.expectEqual(@as(u16, 0), result.state.pending_fetches);
    try testing.expect(!result.state.loading);
}

test "issues_fetched with err sets error_msg" {
    const s = State{
        .loading = true,
        .pending_fetches = 1,
    };
    const result = update(s, .{ .issues_fetched = .{
        .source = .linear,
        .workspace_idx = 0,
        .result = .{ .err = "API failure" },
    } });
    try testing.expect(result.state.error_msg != null);
    try testing.expectEqualStrings("API failure", result.state.error_msg.?);
    try testing.expect(!result.state.loading);
}

test "description_fetched updates issue description" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
        makeTestIssue("A-2", "Second"),
    };
    var s = stateWithIssues(&issues);
    s.detail_loading = true;
    const result = update(s, .{ .description_fetched = .{
        .issue_key = "A-1",
        .result = .{ .ok = .{ .description = "Some description" } },
    } });
    try testing.expect(!result.state.detail_loading);
    try testing.expectEqualStrings("Some description", result.state.issues[0].description.?);
    try testing.expect(result.state.issues[1].description == null);
}

test "status_updated updates issue state" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    const s = stateWithIssues(&issues);
    const result = update(s, .{ .status_updated = .{ .ok = .{
        .issue_key = "A-1",
        .new_state_name = "Done",
        .new_state_type = "completed",
    } } });
    try testing.expectEqualStrings("Done", result.state.issues[0].state_name);
    try testing.expectEqual(issue_mod.StateType.completed, result.state.issues[0].state_type);
}

test "status_updated preserves selection when issue moves between groups" {
    // Setup: 2 in-progress, 2 todo. Selected = index 1 (second in-progress)
    var issues = [_]Issue{
        .{ .identifier = "A-1", .title = "First", .state_name = "In Progress", .state_type = .started, .priority_label = .high },
        .{ .identifier = "A-2", .title = "Second", .state_name = "In Progress", .state_type = .started, .priority_label = .high },
        .{ .identifier = "A-3", .title = "Third", .state_name = "Todo", .state_type = .unstarted, .priority_label = .medium },
        .{ .identifier = "A-4", .title = "Fourth", .state_name = "Todo", .state_type = .unstarted, .priority_label = .low },
    };
    var s = stateWithIssues(&issues);
    s.selected_index = 1; // A-2 (second in-progress)
    try testing.expectEqualStrings("A-2", s.selectedIssue().?.identifier);

    // A-2 changes from In Progress -> Todo
    const result = update(s, .{ .status_updated = .{ .ok = .{
        .issue_key = "A-2",
        .new_state_name = "Backlog",
        .new_state_type = "unstarted",
    } } });

    // A-2 should still be selected, now at display index 3
    // Display order: A-1 (in-progress), A-3 (todo), A-4 (todo), A-2 (now todo)
    try testing.expectEqualStrings("A-2", result.state.selectedIssue().?.identifier);
}

test "selectedIssue uses display order (in-progress first, then todo)" {
    var issues = [_]Issue{
        .{ .identifier = "A-1", .title = "Todo first", .state_name = "Todo", .state_type = .unstarted, .priority_label = .high },
        .{ .identifier = "A-2", .title = "In progress", .state_name = "In Progress", .state_type = .started, .priority_label = .high },
        .{ .identifier = "A-3", .title = "Todo second", .state_name = "Todo", .state_type = .unstarted, .priority_label = .medium },
    };
    var s = stateWithIssues(&issues);
    // Display order: A-2 (in-progress), A-1 (todo), A-3 (todo)
    s.selected_index = 0;
    try testing.expectEqualStrings("A-2", s.selectedIssue().?.identifier);
    s.selected_index = 1;
    try testing.expectEqualStrings("A-1", s.selectedIssue().?.identifier);
    s.selected_index = 2;
    try testing.expectEqualStrings("A-3", s.selectedIssue().?.identifier);
}

test "displayCount excludes completed issues" {
    var issues = [_]Issue{
        .{ .identifier = "A-1", .title = "Started", .state_name = "In Progress", .state_type = .started, .priority_label = .high },
        .{ .identifier = "A-2", .title = "Done", .state_name = "Done", .state_type = .completed, .priority_label = .high },
        .{ .identifier = "A-3", .title = "Todo", .state_name = "Todo", .state_type = .unstarted, .priority_label = .medium },
    };
    const s = stateWithIssues(&issues);
    try testing.expectEqual(@as(usize, 2), s.displayCount());
}

test "handleCreateKey Esc returns to list preserving form" {
    const s = State{
        .mode = .create,
        .loading = false,
        .create_form = CreateForm{},
    };
    const result = update(s, keyEvent(Key.escape));
    try testing.expectEqual(Mode.list, result.state.mode);
    try testing.expect(result.state.create_form != null);
}

test "handleCreateKey typing inserts characters" {
    const s = State{
        .mode = .create,
        .loading = false,
        .create_form = CreateForm{ .focused_field = .title },
    };
    // Type 'H'
    var result = update(s, keyEvent('H'));
    try testing.expectEqual(@as(usize, 1), result.state.create_form.?.title_len);
    try testing.expectEqualStrings("H", result.state.create_form.?.titleSlice());

    // Type 'i'
    result = update(result.state, keyEvent('i'));
    try testing.expectEqual(@as(usize, 2), result.state.create_form.?.title_len);
    try testing.expectEqualStrings("Hi", result.state.create_form.?.titleSlice());
}

test "handleCreateKey backspace deletes character" {
    var s = State{
        .mode = .create,
        .loading = false,
        .create_form = CreateForm{ .focused_field = .title },
    };
    // Type 'AB' then backspace
    s = update(s, keyEvent('A')).state;
    s = update(s, keyEvent('B')).state;
    try testing.expectEqualStrings("AB", s.create_form.?.titleSlice());

    s = update(s, keyEvent(Key.backspace)).state;
    try testing.expectEqualStrings("A", s.create_form.?.titleSlice());
}

test "handleCreateKey tab cycles fields" {
    const s = State{
        .mode = .create,
        .loading = false,
        .create_form = CreateForm{ .focused_field = .team },
    };
    const result = update(s, keyEvent(Key.tab));
    try testing.expectEqual(CreateFormField.title, result.state.create_form.?.focused_field);
}

test "c in list enters create mode" {
    var issues = [_]Issue{
        makeTestIssue("A-1", "First"),
    };
    const s = stateWithIssues(&issues);
    const result = update(s, keyEvent('c'));
    try testing.expectEqual(Mode.create, result.state.mode);
    try testing.expect(result.state.create_form != null);
}

test "teams_fetched stores teams and viewer_id" {
    var teams_data = [_]event_mod.Team{
        .{ .id = "t1", .name = "Engineering", .key = "ENG" },
    };
    const s = State{};
    const result = update(s, .{ .teams_fetched = .{
        .workspace_idx = 0,
        .result = .{ .ok = .{ .viewer_id = "user1", .teams = &teams_data } },
    } });
    try testing.expectEqual(@as(usize, 1), result.state.teams.len);
    try testing.expectEqualStrings("t1", result.state.teams[0].id);
    try testing.expectEqualStrings("user1", result.state.viewer_ids[0].?);
}

test "team_states_fetched stores states" {
    var states_data = [_]event_mod.WorkflowState{
        .{ .id = "s1", .name = "Todo", .state_type = "unstarted" },
        .{ .id = "s2", .name = "In Progress", .state_type = "started" },
    };
    const s = State{};
    const result = update(s, .{ .team_states_fetched = .{
        .team_id = "t1",
        .result = .{ .ok = &states_data },
    } });
    try testing.expectEqual(@as(usize, 1), result.state.team_states_count);
    const found = result.state.findTeamStates("t1");
    try testing.expect(found != null);
    try testing.expectEqual(@as(usize, 2), found.?.len);
}

test "issue_created switches to list mode" {
    const s = State{
        .mode = .create,
        .loading = false,
        .create_form = CreateForm{},
    };
    const result = update(s, .{ .issue_created = .{ .ok = makeTestIssue("NEW-1", "New") } });
    try testing.expectEqual(Mode.list, result.state.mode);
    try testing.expect(result.state.create_form == null);
}

test "poll_tick returns fetch effects without setting loading" {
    const api_keys = [_][]const u8{"key1"};
    const s = State{
        .loading = false,
        .linear_api_keys = &api_keys,
    };
    const result = update(s, .{ .poll_tick = {} });
    try testing.expectEqual(@as(u8, 1), result.effect_count);
    try testing.expect(!result.state.loading);
}

test "refresh: merge issues from two workspaces then refresh" {
    const alloc = testing.allocator;

    // Simulate first load: workspace 0
    var ws0_issues = try alloc.alloc(Issue, 2);
    ws0_issues[0] = .{
        .identifier = try alloc.dupe(u8, "ENG-1"),
        .title = try alloc.dupe(u8, "Fix bug"),
        .state_name = try alloc.dupe(u8, "In Progress"),
        .state_type = .started,
        .priority_label = .high,
        .source = .linear,
        .source_workspace_idx = 0,
    };
    ws0_issues[1] = .{
        .identifier = try alloc.dupe(u8, "ENG-2"),
        .title = try alloc.dupe(u8, "Add feature"),
        .state_name = try alloc.dupe(u8, "Todo"),
        .state_type = .unstarted,
        .priority_label = .medium,
        .source = .linear,
        .source_workspace_idx = 0,
    };

    var s = State{
        .loading = true,
        .pending_fetches = 2,
        .allocator = alloc,
    };

    // First fetch: workspace 0
    var result = update(s, .{ .issues_fetched = .{
        .source = .linear,
        .workspace_idx = 0,
        .result = .{ .ok = ws0_issues },
    } });
    s = result.state;
    try testing.expectEqual(@as(usize, 2), s.issues.len);

    // Second fetch: workspace 1
    var ws1_issues = try alloc.alloc(Issue, 1);
    ws1_issues[0] = .{
        .identifier = try alloc.dupe(u8, "OPS-1"),
        .title = try alloc.dupe(u8, "Deploy"),
        .state_name = try alloc.dupe(u8, "In Progress"),
        .state_type = .started,
        .priority_label = .none,
        .source = .linear,
        .source_workspace_idx = 1,
    };

    result = update(s, .{ .issues_fetched = .{
        .source = .linear,
        .workspace_idx = 1,
        .result = .{ .ok = ws1_issues },
    } });
    s = result.state;
    try testing.expectEqual(@as(usize, 3), s.issues.len);
    try testing.expect(!s.loading);

    // Now simulate refresh: workspace 0 issues arrive again
    var ws0_refresh = try alloc.alloc(Issue, 2);
    ws0_refresh[0] = .{
        .identifier = try alloc.dupe(u8, "ENG-1"),
        .title = try alloc.dupe(u8, "Fix bug v2"),
        .state_name = try alloc.dupe(u8, "Done"),
        .state_type = .completed,
        .priority_label = .high,
        .source = .linear,
        .source_workspace_idx = 0,
    };
    ws0_refresh[1] = .{
        .identifier = try alloc.dupe(u8, "ENG-3"),
        .title = try alloc.dupe(u8, "New task"),
        .state_name = try alloc.dupe(u8, "Todo"),
        .state_type = .unstarted,
        .priority_label = .low,
        .source = .linear,
        .source_workspace_idx = 0,
    };

    s.pending_fetches = 2;
    s.loading = true;
    result = update(s, .{ .issues_fetched = .{
        .source = .linear,
        .workspace_idx = 0,
        .result = .{ .ok = ws0_refresh },
    } });
    s = result.state;
    // Should have 1 ws1 issue + 2 new ws0 issues = 3
    try testing.expectEqual(@as(usize, 3), s.issues.len);

    // Workspace 1 refresh
    var ws1_refresh = try alloc.alloc(Issue, 1);
    ws1_refresh[0] = .{
        .identifier = try alloc.dupe(u8, "OPS-1"),
        .title = try alloc.dupe(u8, "Deploy v2"),
        .state_name = try alloc.dupe(u8, "Done"),
        .state_type = .completed,
        .priority_label = .none,
        .source = .linear,
        .source_workspace_idx = 1,
    };

    result = update(s, .{ .issues_fetched = .{
        .source = .linear,
        .workspace_idx = 1,
        .result = .{ .ok = ws1_refresh },
    } });
    s = result.state;
    try testing.expectEqual(@as(usize, 3), s.issues.len);
    try testing.expect(!s.loading);

    // Cleanup
    issue_mod.freeIssues(alloc, s.issues);
}

test "refresh: teams merge from two workspaces" {
    const alloc = testing.allocator;

    // Workspace 0 teams arrive
    var ws0_teams = try alloc.alloc(event_mod.Team, 2);
    ws0_teams[0] = .{
        .id = try alloc.dupe(u8, "t1"),
        .name = try alloc.dupe(u8, "Engineering"),
        .key = try alloc.dupe(u8, "ENG"),
    };
    ws0_teams[1] = .{
        .id = try alloc.dupe(u8, "t2"),
        .name = try alloc.dupe(u8, "Ops"),
        .key = try alloc.dupe(u8, "OPS"),
    };

    var s = State{ .allocator = alloc };
    var result = update(s, .{ .teams_fetched = .{
        .workspace_idx = 0,
        .result = .{ .ok = .{ .viewer_id = try alloc.dupe(u8, "u1"), .teams = ws0_teams } },
    } });
    s = result.state;
    try testing.expectEqual(@as(usize, 2), s.teams.len);

    // Workspace 1 teams arrive (one overlapping, one new)
    var ws1_teams = try alloc.alloc(event_mod.Team, 2);
    ws1_teams[0] = .{
        .id = try alloc.dupe(u8, "t2"),
        .name = try alloc.dupe(u8, "Ops"),
        .key = try alloc.dupe(u8, "OPS"),
    };
    ws1_teams[1] = .{
        .id = try alloc.dupe(u8, "t3"),
        .name = try alloc.dupe(u8, "Design"),
        .key = try alloc.dupe(u8, "DES"),
    };

    result = update(s, .{ .teams_fetched = .{
        .workspace_idx = 1,
        .result = .{ .ok = .{ .viewer_id = try alloc.dupe(u8, "u1dup"), .teams = ws1_teams } },
    } });
    s = result.state;
    try testing.expectEqual(@as(usize, 3), s.teams.len); // t1, t2, t3
    try testing.expectEqualStrings("u1", s.viewer_ids[0].?);
    try testing.expectEqualStrings("u1dup", s.viewer_ids[1].?);

    // Cleanup — all memory properly owned by state now
    for (s.teams) |team| {
        alloc.free(team.id);
        alloc.free(team.name);
        alloc.free(team.key);
    }
    alloc.free(s.teams);
    for (&s.viewer_ids) |*vid| {
        if (vid.*) |v| alloc.free(v);
    }
}
