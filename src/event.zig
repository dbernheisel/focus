const std = @import("std");
const vaxis = @import("vaxis");
const issue_mod = @import("issue.zig");

pub const Source = issue_mod.Source;
pub const Issue = issue_mod.Issue;

pub const FetchResult = union(enum) {
    ok: []Issue,
    err: []const u8,
};

pub const DescResult = union(enum) {
    ok: struct { description: []const u8, comments: ?[]issue_mod.Comment = null },
    err: []const u8,
};

pub const WorkflowState = struct {
    id: []const u8,
    name: []const u8,
    state_type: []const u8,
};

pub const Team = struct {
    id: []const u8,
    name: []const u8,
    key: []const u8,
    workspace_idx: usize = 0,
};

pub const TeamsResult = union(enum) {
    ok: struct { viewer_id: []const u8, teams: []Team },
    err: []const u8,
};

pub const TeamStatesResult = union(enum) {
    ok: []WorkflowState,
    err: []const u8,
};

pub const StatusUpdateResult = union(enum) {
    ok: struct {
        issue_key: []const u8,
        new_state_name: []const u8,
        new_state_type: []const u8,
    },
    err: []const u8,
};

pub const CreateResult = union(enum) {
    ok: Issue,
    err: []const u8,
};

pub const NotionStatusOption = struct {
    name: []const u8,
    group: []const u8,
};

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    issues_fetched: struct { source: Source, workspace_idx: usize, result: FetchResult },
    description_fetched: struct { issue_key: []const u8, result: DescResult },
    teams_fetched: struct { workspace_idx: usize, result: TeamsResult },
    team_states_fetched: struct { team_id: []const u8, result: TeamStatesResult },
    status_updated: StatusUpdateResult,
    issue_created: CreateResult,
    poll_tick: void,
};

pub const CreateParams = struct {
    title: []const u8,
    team_id: []const u8,
    description: ?[]const u8 = null,
    state_id: ?[]const u8 = null,
    assignee_id: ?[]const u8 = null,
    priority: u8 = 0,
};

pub const Effect = union(enum) {
    fetch_linear_issues: struct { workspace_idx: usize, api_key: []const u8 },
    fetch_notion_issues: struct { workspace_idx: usize, api_key: []const u8 },
    fetch_description: struct { source: Source, api_key: []const u8, issue_key: []const u8 },
    fetch_teams_and_viewer: struct { workspace_idx: usize, api_key: []const u8 },
    fetch_team_states: struct { api_key: []const u8, team_id: []const u8 },
    update_linear_status: struct { api_key: []const u8, issue_id: []const u8, identifier: []const u8, state_id: []const u8, state_name: []const u8, state_type: []const u8 },
    update_notion_status: struct { api_key: []const u8, page_id: []const u8, status_prop: []const u8, status_name: []const u8, status_group: []const u8 },
    create_issue: struct { api_key: []const u8, params: CreateParams },
    open_url: []const u8,
    quit: void,
};
