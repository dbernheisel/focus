const std = @import("std");
const testing = std.testing;

pub const Source = enum {
    linear,
    notion,
};

pub const StateType = enum {
    started,
    unstarted,
    backlog,
    completed,

    pub fn fromString(s: []const u8) StateType {
        if (std.mem.eql(u8, s, "started")) return .started;
        if (std.mem.eql(u8, s, "unstarted")) return .unstarted;
        if (std.mem.eql(u8, s, "backlog")) return .backlog;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        return .backlog;
    }
};

pub const PriorityLabel = enum {
    none,
    urgent,
    high,
    medium,
    low,

    pub fn icon(self: PriorityLabel) []const u8 {
        return switch (self) {
            .urgent => "!",
            .high => "↑",
            .medium => "-",
            .low => "↓",
            .none => " ",
        };
    }

    pub fn sortOrder(self: PriorityLabel) u8 {
        return switch (self) {
            .urgent => 0,
            .high => 1,
            .medium => 2,
            .none => 3,
            .low => 4,
        };
    }

    pub fn fromString(s: ?[]const u8) PriorityLabel {
        const val = s orelse return .none;
        if (std.mem.eql(u8, val, "Urgent")) return .urgent;
        if (std.mem.eql(u8, val, "High")) return .high;
        if (std.mem.eql(u8, val, "Medium")) return .medium;
        if (std.mem.eql(u8, val, "Low")) return .low;
        if (std.mem.eql(u8, val, "No priority")) return .none;
        return .none;
    }
};

pub const Comment = struct {
    author: []const u8,
    body: []const u8,
    created_at: []const u8,
};

pub const Issue = struct {
    identifier: []const u8,
    title: []const u8,
    state_name: []const u8,
    state_type: StateType,
    priority_label: PriorityLabel,
    description: ?[]const u8 = null,
    comments: ?[]Comment = null,
    updated_at: ?[]const u8 = null,
    source: Source = .linear,
    source_id: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    source_workspace_idx: ?usize = null,
    project_name: ?[]const u8 = null,
    milestone_name: ?[]const u8 = null,

    pub fn key(self: Issue) []const u8 {
        return self.source_id orelse self.identifier;
    }

    pub fn isInReview(self: Issue) bool {
        return self.state_type == .started and std.mem.eql(u8, self.state_name, "In Review");
    }

    pub fn isInProgress(self: Issue) bool {
        return self.state_type == .started and !self.isInReview();
    }

    pub fn isTodo(self: Issue) bool {
        return self.state_type == .unstarted or self.state_type == .backlog;
    }
};

/// Free all heap-allocated strings within a single Issue.
pub fn freeIssue(allocator: std.mem.Allocator, iss: Issue) void {
    allocator.free(iss.identifier);
    allocator.free(iss.title);
    allocator.free(iss.state_name);
    if (iss.updated_at) |u| allocator.free(u);
    if (iss.description) |d| allocator.free(d);
    if (iss.comments) |comments| {
        for (comments) |c| {
            allocator.free(c.author);
            allocator.free(c.body);
            allocator.free(c.created_at);
        }
        allocator.free(comments);
    }
    if (iss.source_id) |s| allocator.free(s);
    if (iss.source_url) |u| allocator.free(u);
    if (iss.project_name) |p| allocator.free(p);
    if (iss.milestone_name) |m| allocator.free(m);
}

/// Free every issue's strings in a slice, then free the slice itself.
pub fn freeIssues(allocator: std.mem.Allocator, issues: []Issue) void {
    for (issues) |iss| {
        freeIssue(allocator, iss);
    }
    allocator.free(issues);
}

// --- Tests ---

fn makeIssue() Issue {
    return .{
        .identifier = "FOC-1",
        .title = "Test issue",
        .state_name = "In Progress",
        .state_type = .started,
        .priority_label = .high,
    };
}

test "key returns source_id when present" {
    var iss = makeIssue();
    iss.source_id = "abc-123";
    try testing.expectEqualStrings("abc-123", iss.key());
}

test "key returns identifier when no source_id" {
    const iss = makeIssue();
    try testing.expectEqualStrings("FOC-1", iss.key());
}

test "priority icons are correct" {
    try testing.expectEqualStrings("!", PriorityLabel.urgent.icon());
    try testing.expectEqualStrings("↑", PriorityLabel.high.icon());
    try testing.expectEqualStrings("-", PriorityLabel.medium.icon());
    try testing.expectEqualStrings("↓", PriorityLabel.low.icon());
    try testing.expectEqualStrings(" ", PriorityLabel.none.icon());
}

test "PriorityLabel.sortOrder matches urgent→high→medium→none→low" {
    try testing.expect(PriorityLabel.urgent.sortOrder() < PriorityLabel.high.sortOrder());
    try testing.expect(PriorityLabel.high.sortOrder() < PriorityLabel.medium.sortOrder());
    try testing.expect(PriorityLabel.medium.sortOrder() < PriorityLabel.none.sortOrder());
    try testing.expect(PriorityLabel.none.sortOrder() < PriorityLabel.low.sortOrder());
}

test "PriorityLabel.fromString parses correctly" {
    try testing.expectEqual(PriorityLabel.urgent, PriorityLabel.fromString("Urgent"));
    try testing.expectEqual(PriorityLabel.high, PriorityLabel.fromString("High"));
    try testing.expectEqual(PriorityLabel.medium, PriorityLabel.fromString("Medium"));
    try testing.expectEqual(PriorityLabel.low, PriorityLabel.fromString("Low"));
    try testing.expectEqual(PriorityLabel.none, PriorityLabel.fromString("No priority"));
    try testing.expectEqual(PriorityLabel.none, PriorityLabel.fromString(null));
    try testing.expectEqual(PriorityLabel.none, PriorityLabel.fromString("unknown"));
}

test "StateType.fromString parses correctly" {
    try testing.expectEqual(StateType.started, StateType.fromString("started"));
    try testing.expectEqual(StateType.unstarted, StateType.fromString("unstarted"));
    try testing.expectEqual(StateType.backlog, StateType.fromString("backlog"));
    try testing.expectEqual(StateType.completed, StateType.fromString("completed"));
    try testing.expectEqual(StateType.backlog, StateType.fromString("unknown"));
}

test "isInProgress, isInReview, and isTodo grouping helpers" {
    var iss = makeIssue();

    iss.state_type = .started;
    iss.state_name = "In Progress";
    try testing.expect(iss.isInProgress());
    try testing.expect(!iss.isInReview());
    try testing.expect(!iss.isTodo());

    iss.state_type = .started;
    iss.state_name = "In Review";
    try testing.expect(!iss.isInProgress());
    try testing.expect(iss.isInReview());
    try testing.expect(!iss.isTodo());

    iss.state_type = .unstarted;
    iss.state_name = "Todo";
    try testing.expect(!iss.isInProgress());
    try testing.expect(!iss.isInReview());
    try testing.expect(iss.isTodo());

    iss.state_type = .backlog;
    iss.state_name = "Backlog";
    try testing.expect(!iss.isInProgress());
    try testing.expect(!iss.isInReview());
    try testing.expect(iss.isTodo());

    iss.state_type = .completed;
    iss.state_name = "Done";
    try testing.expect(!iss.isInProgress());
    try testing.expect(!iss.isInReview());
    try testing.expect(!iss.isTodo());
}
