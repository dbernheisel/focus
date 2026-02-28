const std = @import("std");
const http = @import("http.zig");
const issue_mod = @import("issue.zig");
const event_mod = @import("event.zig");

const Issue = issue_mod.Issue;
const PriorityLabel = issue_mod.PriorityLabel;
const StateType = issue_mod.StateType;

const api_url = "https://api.linear.app/graphql";

// --- Parse types for JSON deserialization ---

const IssuesResponseJson = struct {
    data: struct {
        viewer: struct {
            assignedIssues: struct {
                nodes: []const IssueNodeJson,
            },
        },
    },
};

const IssueNodeJson = struct {
    id: []const u8,
    identifier: []const u8,
    title: []const u8,
    updatedAt: []const u8,
    state: struct {
        name: []const u8,
        type: []const u8,
    },
    priority: ?u8 = null,
    priorityLabel: ?[]const u8 = null,
};

const CommentNodeJson = struct {
    body: []const u8,
    user: ?struct { name: []const u8 } = null,
    createdAt: []const u8,
};

const DescriptionResponseJson = struct {
    data: struct {
        issue: struct {
            description: ?[]const u8 = null,
            comments: ?struct {
                nodes: []const CommentNodeJson,
            } = null,
        },
    },
};

const TeamsAndViewerResponseJson = struct {
    data: struct {
        viewer: struct {
            id: []const u8,
        },
        teams: struct {
            nodes: []const TeamNodeJson,
        },
    },
};

const TeamNodeJson = struct {
    id: []const u8,
    name: []const u8,
    key: []const u8,
};

const TeamStatesResponseJson = struct {
    data: struct {
        workflowStates: struct {
            nodes: []const WorkflowStateNodeJson,
        },
    },
};

const WorkflowStateNodeJson = struct {
    id: []const u8,
    name: []const u8,
    type: []const u8,
};

const CreateResponseJson = struct {
    data: struct {
        issueCreate: struct {
            issue: struct {
                identifier: []const u8,
                title: []const u8,
                state: struct {
                    name: []const u8,
                    type: []const u8,
                },
                priorityLabel: ?[]const u8 = null,
            },
        },
    },
};

pub const TeamsAndViewer = struct {
    viewer_id: []const u8,
    teams: []event_mod.Team,
};

// --- Parse functions (testable with fixture JSON) ---

pub fn parseIssuesResponse(allocator: std.mem.Allocator, json: []const u8, workspace_idx: usize) ![]Issue {
    const parsed = try std.json.parseFromSlice(IssuesResponseJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const nodes = parsed.value.data.viewer.assignedIssues.nodes;
    var issues = try allocator.alloc(Issue, nodes.len);

    for (nodes, 0..) |node, i| {
        issues[i] = .{
            .identifier = try allocator.dupe(u8, node.identifier),
            .title = try allocator.dupe(u8, node.title),
            .state_name = try allocator.dupe(u8, node.state.name),
            .state_type = StateType.fromString(node.state.type),
            .priority_label = PriorityLabel.fromString(node.priorityLabel),
            .updated_at = try allocator.dupe(u8, node.updatedAt),
            .source = .linear,
            .source_id = try allocator.dupe(u8, node.id),
            .source_workspace_idx = workspace_idx,
        };
    }

    // Sort by updated_at descending (most recently updated first)
    std.mem.sort(Issue, issues, {}, struct {
        fn cmp(_: void, a: Issue, b: Issue) bool {
            const a_ts = a.updated_at orelse "";
            const b_ts = b.updated_at orelse "";
            return std.mem.order(u8, a_ts, b_ts) == .gt;
        }
    }.cmp);

    return issues;
}

pub const DescriptionData = struct {
    description: []const u8,
    comments: ?[]issue_mod.Comment = null,
};

pub fn parseDescriptionResponse(allocator: std.mem.Allocator, json: []const u8) !DescriptionData {
    const parsed = try std.json.parseFromSlice(DescriptionResponseJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const desc = parsed.value.data.issue.description orelse "";
    const duped_desc = try allocator.dupe(u8, desc);

    // Parse comments if present
    var comments: ?[]issue_mod.Comment = null;
    if (parsed.value.data.issue.comments) |c| {
        if (c.nodes.len > 0) {
            var comment_list = try allocator.alloc(issue_mod.Comment, c.nodes.len);
            for (c.nodes, 0..) |node, i| {
                const author_name = if (node.user) |u| u.name else "Unknown";
                comment_list[i] = .{
                    .author = try allocator.dupe(u8, author_name),
                    .body = try allocator.dupe(u8, node.body),
                    .created_at = try allocator.dupe(u8, node.createdAt),
                };
            }
            comments = comment_list;
        }
    }

    return .{ .description = duped_desc, .comments = comments };
}

pub fn parseTeamsAndViewerResponse(allocator: std.mem.Allocator, json: []const u8) !TeamsAndViewer {
    const parsed = try std.json.parseFromSlice(TeamsAndViewerResponseJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const viewer_id = try allocator.dupe(u8, parsed.value.data.viewer.id);
    const nodes = parsed.value.data.teams.nodes;
    var teams = try allocator.alloc(event_mod.Team, nodes.len);

    for (nodes, 0..) |node, i| {
        teams[i] = .{
            .id = try allocator.dupe(u8, node.id),
            .name = try allocator.dupe(u8, node.name),
            .key = try allocator.dupe(u8, node.key),
        };
    }

    return .{ .viewer_id = viewer_id, .teams = teams };
}

pub fn parseTeamStatesResponse(allocator: std.mem.Allocator, json: []const u8) ![]event_mod.WorkflowState {
    const parsed = try std.json.parseFromSlice(TeamStatesResponseJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const nodes = parsed.value.data.workflowStates.nodes;

    // Count valid states first
    var count: usize = 0;
    for (nodes) |node| {
        if (isValidStateType(node.type)) count += 1;
    }

    var states = try allocator.alloc(event_mod.WorkflowState, count);
    var idx: usize = 0;
    for (nodes) |node| {
        if (isValidStateType(node.type)) {
            states[idx] = .{
                .id = try allocator.dupe(u8, node.id),
                .name = try allocator.dupe(u8, node.name),
                .state_type = try allocator.dupe(u8, node.type),
            };
            idx += 1;
        }
    }

    return states;
}

fn isValidStateType(state_type: []const u8) bool {
    return std.mem.eql(u8, state_type, "backlog") or
        std.mem.eql(u8, state_type, "unstarted") or
        std.mem.eql(u8, state_type, "started");
}

pub fn parseCreateResponse(allocator: std.mem.Allocator, json: []const u8) !Issue {
    const parsed = try std.json.parseFromSlice(CreateResponseJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const issue_data = parsed.value.data.issueCreate.issue;
    return .{
        .identifier = try allocator.dupe(u8, issue_data.identifier),
        .title = try allocator.dupe(u8, issue_data.title),
        .state_name = try allocator.dupe(u8, issue_data.state.name),
        .state_type = StateType.fromString(issue_data.state.type),
        .priority_label = PriorityLabel.fromString(issue_data.priorityLabel),
        .source = .linear,
    };
}

// --- Fetch functions (use http.zig, network dependent) ---

pub fn fetchIssues(allocator: std.mem.Allocator, api_key: []const u8, workspace_idx: usize) ![]Issue {
    const query =
        \\{"query":"{ viewer { assignedIssues(filter: { state: { type: { in: [\"started\", \"unstarted\", \"backlog\"] } } }, orderBy: updatedAt) { nodes { id identifier title updatedAt state { name type } priority priorityLabel } } } }"}
    ;
    const response = try http.postJson(allocator, api_url, api_key, query);
    defer allocator.free(response);

    return parseIssuesResponse(allocator, response, workspace_idx);
}

pub fn fetchDescription(allocator: std.mem.Allocator, api_key: []const u8, identifier: []const u8) !DescriptionData {
    const query = try std.fmt.allocPrint(allocator,
        \\{{"query":"{{ issue(id: \"{s}\") {{ description comments {{ nodes {{ body user {{ name }} createdAt }} }} }} }}"}}
    , .{identifier});
    defer allocator.free(query);

    const response = try http.postJson(allocator, api_url, api_key, query);
    defer allocator.free(response);

    return parseDescriptionResponse(allocator, response);
}

pub fn fetchTeamsAndViewer(allocator: std.mem.Allocator, api_key: []const u8) !TeamsAndViewer {
    const query =
        \\{"query":"{ viewer { id } teams { nodes { id name key } } }"}
    ;
    const response = try http.postJson(allocator, api_url, api_key, query);
    defer allocator.free(response);

    return parseTeamsAndViewerResponse(allocator, response);
}

pub fn fetchTeamStates(allocator: std.mem.Allocator, api_key: []const u8, team_id: []const u8) ![]event_mod.WorkflowState {
    const query = try std.fmt.allocPrint(allocator,
        \\{{"query":"{{ workflowStates(filter: {{ team: {{ id: {{ eq: \"{s}\" }} }} }}) {{ nodes {{ id name type }} }} }}"}}
    , .{team_id});
    defer allocator.free(query);

    const response = try http.postJson(allocator, api_url, api_key, query);
    defer allocator.free(response);

    return parseTeamStatesResponse(allocator, response);
}

pub fn updateIssueState(allocator: std.mem.Allocator, api_key: []const u8, issue_id: []const u8, state_id: []const u8) !void {
    const log = @import("log.zig");
    const query = try std.fmt.allocPrint(allocator,
        \\{{"query":"mutation {{ issueUpdate(id: \"{s}\", input: {{ stateId: \"{s}\" }}) {{ success }} }}"}}
    , .{ issue_id, state_id });
    defer allocator.free(query);

    log.info("updateIssueState query: {s}", .{query});
    const response = try http.postJson(allocator, api_url, api_key, query);
    defer allocator.free(response);
    log.info("updateIssueState response: {s}", .{response});

    // Check for errors in the response
    if (std.mem.indexOf(u8, response, "\"errors\"") != null) {
        return error.ApiError;
    }
}

pub fn createIssue(allocator: std.mem.Allocator, api_key: []const u8, params: event_mod.CreateParams) !Issue {
    const log = @import("log.zig");

    const input = .{
        .teamId = params.team_id,
        .title = params.title,
        .stateId = params.state_id,
        .assigneeId = params.assignee_id,
        .description = params.description,
        .priority = if (params.priority > 0) @as(?u8, params.priority) else null,
    };

    const variables_json = try std.json.Stringify.valueAlloc(allocator, .{ .input = input }, .{ .emit_null_optional_fields = false });
    defer allocator.free(variables_json);

    const query_str =
        \\mutation($input: IssueCreateInput!) { issueCreate(input: $input) { issue { identifier title state { name type } priorityLabel } } }
    ;
    const query_json = try std.json.Stringify.valueAlloc(allocator, query_str, .{});
    defer allocator.free(query_json);

    const body = try std.fmt.allocPrint(allocator, "{{\"query\":{s},\"variables\":{s}}}", .{ query_json, variables_json });
    defer allocator.free(body);

    log.info("createIssue request: {s}", .{body});
    const response = try http.postJson(allocator, api_url, api_key, body);
    defer allocator.free(response);
    log.info("createIssue response: {s}", .{response});

    return parseCreateResponse(allocator, response);
}


// --- Tests ---

test "parseIssuesResponse extracts issues correctly" {
    const json =
        \\{"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"uuid-1","identifier":"ENG-1","title":"Fix bug","updatedAt":"2026-03-10T12:00:00.000Z","state":{"name":"In Progress","type":"started"},"priority":2,"priorityLabel":"High"}]}}}}
    ;
    const issues = try parseIssuesResponse(std.testing.allocator, json, 0);
    defer {
        for (issues) |iss| {
            issue_mod.freeIssue(std.testing.allocator, iss);
        }
        std.testing.allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("ENG-1", issues[0].identifier);
    try std.testing.expectEqualStrings("Fix bug", issues[0].title);
    try std.testing.expectEqualStrings("In Progress", issues[0].state_name);
    try std.testing.expectEqual(StateType.started, issues[0].state_type);
    try std.testing.expectEqual(PriorityLabel.high, issues[0].priority_label);
    try std.testing.expectEqual(issue_mod.Source.linear, issues[0].source);
    try std.testing.expectEqual(@as(?usize, 0), issues[0].source_workspace_idx);
    try std.testing.expectEqualStrings("uuid-1", issues[0].source_id.?);
}

test "parseIssuesResponse handles multiple issues" {
    const json =
        \\{"data":{"viewer":{"assignedIssues":{"nodes":[
        \\{"id":"uuid-1","identifier":"ENG-1","title":"First","updatedAt":"2026-03-09T10:00:00.000Z","state":{"name":"Todo","type":"unstarted"},"priorityLabel":"Low"},
        \\{"id":"uuid-2","identifier":"ENG-2","title":"Second","updatedAt":"2026-03-10T10:00:00.000Z","state":{"name":"Backlog","type":"backlog"},"priorityLabel":"Medium"}
        \\]}}}}
    ;
    const issues = try parseIssuesResponse(std.testing.allocator, json, 2);
    defer {
        for (issues) |iss| {
            issue_mod.freeIssue(std.testing.allocator, iss);
        }
        std.testing.allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 2), issues.len);
    // Sorted by updatedAt descending: ENG-2 (2026-03-10) before ENG-1 (2026-03-09)
    try std.testing.expectEqualStrings("ENG-2", issues[0].identifier);
    try std.testing.expectEqualStrings("ENG-1", issues[1].identifier);
    try std.testing.expectEqual(StateType.backlog, issues[0].state_type);
    try std.testing.expectEqual(StateType.unstarted, issues[1].state_type);
    try std.testing.expectEqual(@as(?usize, 2), issues[0].source_workspace_idx);
    try std.testing.expectEqual(@as(?usize, 2), issues[1].source_workspace_idx);
}

test "parseDescriptionResponse extracts description" {
    const json =
        \\{"data":{"issue":{"description":"# Hello\n\nSome markdown text"}}}
    ;
    const data = try parseDescriptionResponse(std.testing.allocator, json);
    defer std.testing.allocator.free(data.description);

    try std.testing.expectEqualStrings("# Hello\n\nSome markdown text", data.description);
    try std.testing.expect(data.comments == null);
}

test "parseTeamsAndViewerResponse extracts viewer_id and teams" {
    const json =
        \\{"data":{"viewer":{"id":"user123"},"teams":{"nodes":[{"id":"t1","name":"Engineering","key":"ENG"},{"id":"t2","name":"Design","key":"DES"}]}}}
    ;
    const result = try parseTeamsAndViewerResponse(std.testing.allocator, json);
    defer {
        std.testing.allocator.free(result.viewer_id);
        for (result.teams) |t| {
            std.testing.allocator.free(t.id);
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.key);
        }
        std.testing.allocator.free(result.teams);
    }

    try std.testing.expectEqualStrings("user123", result.viewer_id);
    try std.testing.expectEqual(@as(usize, 2), result.teams.len);
    try std.testing.expectEqualStrings("t1", result.teams[0].id);
    try std.testing.expectEqualStrings("Engineering", result.teams[0].name);
    try std.testing.expectEqualStrings("ENG", result.teams[0].key);
    try std.testing.expectEqualStrings("t2", result.teams[1].id);
}

test "parseTeamStatesResponse filters to valid types only" {
    const json =
        \\{"data":{"workflowStates":{"nodes":[
        \\{"id":"s1","name":"Triage","type":"triage"},
        \\{"id":"s2","name":"Todo","type":"unstarted"},
        \\{"id":"s3","name":"In Progress","type":"started"},
        \\{"id":"s4","name":"Done","type":"completed"},
        \\{"id":"s5","name":"Backlog","type":"backlog"},
        \\{"id":"s6","name":"Cancelled","type":"cancelled"}
        \\]}}}
    ;
    const states = try parseTeamStatesResponse(std.testing.allocator, json);
    defer {
        for (states) |s| {
            std.testing.allocator.free(s.id);
            std.testing.allocator.free(s.name);
            std.testing.allocator.free(s.state_type);
        }
        std.testing.allocator.free(states);
    }

    try std.testing.expectEqual(@as(usize, 3), states.len);
    try std.testing.expectEqualStrings("Todo", states[0].name);
    try std.testing.expectEqualStrings("unstarted", states[0].state_type);
    try std.testing.expectEqualStrings("In Progress", states[1].name);
    try std.testing.expectEqualStrings("started", states[1].state_type);
    try std.testing.expectEqualStrings("Backlog", states[2].name);
    try std.testing.expectEqualStrings("backlog", states[2].state_type);
}

test "parseCreateResponse extracts created issue" {
    const json =
        \\{"data":{"issueCreate":{"issue":{"identifier":"ENG-42","title":"New issue","state":{"name":"Backlog","type":"backlog"},"priorityLabel":"Medium"}}}}
    ;
    const iss = try parseCreateResponse(std.testing.allocator, json);
    defer {
        std.testing.allocator.free(iss.identifier);
        std.testing.allocator.free(iss.title);
        std.testing.allocator.free(iss.state_name);
    }

    try std.testing.expectEqualStrings("ENG-42", iss.identifier);
    try std.testing.expectEqualStrings("New issue", iss.title);
    try std.testing.expectEqualStrings("Backlog", iss.state_name);
    try std.testing.expectEqual(StateType.backlog, iss.state_type);
    try std.testing.expectEqual(PriorityLabel.medium, iss.priority_label);
}
