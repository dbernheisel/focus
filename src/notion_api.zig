const std = @import("std");
const http = @import("http.zig");
const issue_mod = @import("issue.zig");

const base_url = "https://api.notion.com/v1";
const notion_version = "2022-06-28";

// --- Types ---

pub const Database = struct {
    id: []const u8,
    title: []const u8,
    status_property: []const u8,
    assignee_property: []const u8,
};

pub const NotionTask = struct {
    page_id: []const u8,
    title: []const u8,
    status_name: []const u8,
    status_group: []const u8,
    url: []const u8,
};

pub const TasksResult = struct {
    tasks: []NotionTask,
    databases: []Database,
};

// --- JSON parse types ---

const SearchResponseJson = struct {
    results: []const SearchResultJson,
};

const SearchResultJson = struct {
    id: []const u8,
    title: ?[]const TitleTextJson = null,
    properties: std.json.Value,
};

const TitleTextJson = struct {
    plain_text: []const u8,
};

const QueryResponseJson = struct {
    results: []const QueryResultJson,
};

const QueryResultJson = struct {
    id: []const u8,
    url: ?[]const u8 = null,
    properties: std.json.Value,
};

const BlocksResponseJson = struct {
    results: []const BlockJson,
};

const BlockJson = struct {
    type: []const u8,
    paragraph: ?RichTextContainer = null,
    heading_1: ?RichTextContainer = null,
    heading_2: ?RichTextContainer = null,
    heading_3: ?RichTextContainer = null,
    bulleted_list_item: ?RichTextContainer = null,
    numbered_list_item: ?RichTextContainer = null,
    code: ?CodeBlock = null,
    quote: ?RichTextContainer = null,
    to_do: ?ToDoBlock = null,
};

const RichTextContainer = struct {
    rich_text: []const RichTextJson,
};

const CodeBlock = struct {
    rich_text: []const RichTextJson,
    language: ?[]const u8 = null,
};

const ToDoBlock = struct {
    rich_text: []const RichTextJson,
    checked: bool = false,
};

const RichTextJson = struct {
    plain_text: []const u8,
};

// --- Status group mapping ---

pub fn mapStatusGroup(group: []const u8) []const u8 {
    if (std.mem.eql(u8, group, "to_do")) return "unstarted";
    if (std.mem.eql(u8, group, "in_progress")) return "started";
    if (std.mem.eql(u8, group, "complete")) return "completed";
    return "unstarted";
}

// --- Parse functions ---

pub fn parseSearchDatabases(allocator: std.mem.Allocator, json: []const u8) ![]Database {
    const parsed = try std.json.parseFromSlice(SearchResponseJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // First pass: count qualifying databases
    var count: usize = 0;
    for (parsed.value.results) |result| {
        const props = result.properties;
        if (props != .object) continue;
        if (findPropertyByType(props.object, "status") != null and
            findPropertyByType(props.object, "people") != null)
        {
            count += 1;
        }
    }

    var databases = try allocator.alloc(Database, count);
    var idx: usize = 0;
    for (parsed.value.results) |result| {
        const props = result.properties;
        if (props != .object) continue;

        const status_prop = findPropertyByType(props.object, "status") orelse continue;
        const assignee_prop = findPropertyByType(props.object, "people") orelse continue;

        // Extract title
        var title: []const u8 = "";
        if (result.title) |title_arr| {
            if (title_arr.len > 0) {
                title = title_arr[0].plain_text;
            }
        }

        databases[idx] = .{
            .id = try allocator.dupe(u8, result.id),
            .title = try allocator.dupe(u8, title),
            .status_property = try allocator.dupe(u8, status_prop),
            .assignee_property = try allocator.dupe(u8, assignee_prop),
        };
        idx += 1;
    }

    return databases;
}

fn findPropertyByType(obj: std.json.ObjectMap, prop_type: []const u8) ?[]const u8 {
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .object) {
            if (entry.value_ptr.object.get("type")) |type_val| {
                if (type_val == .string) {
                    if (std.mem.eql(u8, type_val.string, prop_type)) {
                        return entry.key_ptr.*;
                    }
                }
            }
        }
    }
    return null;
}

pub fn parseQueryResponse(allocator: std.mem.Allocator, json: []const u8, status_property: []const u8) ![]NotionTask {
    const parsed = try std.json.parseFromSlice(QueryResponseJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var tasks: std.ArrayList(NotionTask) = .{};
    defer tasks.deinit(allocator);

    for (parsed.value.results) |result| {
        const props = result.properties;
        if (props != .object) continue;

        // Extract title from properties (look for "title" type property)
        const title = extractTitle(props.object) orelse "";

        // Extract status
        var status_name: []const u8 = "";
        var status_group: []const u8 = "unstarted";
        if (props.object.get(status_property)) |status_val| {
            if (status_val == .object) {
                if (status_val.object.get("status")) |status_obj| {
                    if (status_obj == .object) {
                        if (status_obj.object.get("name")) |name_val| {
                            if (name_val == .string) status_name = name_val.string;
                        }
                        if (status_obj.object.get("color")) |_| {
                            // Status group comes from the group field in the Notion API
                        }
                    }
                }
            }
        }

        // Try to get status group from the status object
        if (props.object.get(status_property)) |status_val| {
            if (status_val == .object) {
                if (status_val.object.get("status")) |status_obj| {
                    if (status_obj == .object) {
                        if (status_obj.object.get("group")) |group_val| {
                            if (group_val == .string) status_group = group_val.string;
                        }
                    }
                }
            }
        }

        const url = result.url orelse "";

        try tasks.append(allocator, .{
            .page_id = try allocator.dupe(u8, result.id),
            .title = try allocator.dupe(u8, title),
            .status_name = try allocator.dupe(u8, status_name),
            .status_group = try allocator.dupe(u8, mapStatusGroup(status_group)),
            .url = try allocator.dupe(u8, url),
        });
    }

    return try tasks.toOwnedSlice(allocator);
}

fn extractTitle(obj: std.json.ObjectMap) ?[]const u8 {
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .object) {
            if (entry.value_ptr.object.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "title")) {
                    if (entry.value_ptr.object.get("title")) |title_arr| {
                        if (title_arr == .array and title_arr.array.items.len > 0) {
                            const first = title_arr.array.items[0];
                            if (first == .object) {
                                if (first.object.get("plain_text")) |pt| {
                                    if (pt == .string) return pt.string;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return null;
}

pub fn parseBlocksToMarkdown(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(BlocksResponseJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    const blocks = parsed.value.results;
    for (blocks, 0..) |block, i| {
        if (i > 0) try buf.appendSlice(allocator, "\n");

        if (std.mem.eql(u8, block.type, "paragraph")) {
            if (block.paragraph) |p| try appendRichText(&buf, allocator, p.rich_text);
        } else if (std.mem.eql(u8, block.type, "heading_1")) {
            try buf.appendSlice(allocator, "# ");
            if (block.heading_1) |h| try appendRichText(&buf, allocator, h.rich_text);
        } else if (std.mem.eql(u8, block.type, "heading_2")) {
            try buf.appendSlice(allocator, "## ");
            if (block.heading_2) |h| try appendRichText(&buf, allocator, h.rich_text);
        } else if (std.mem.eql(u8, block.type, "heading_3")) {
            try buf.appendSlice(allocator, "### ");
            if (block.heading_3) |h| try appendRichText(&buf, allocator, h.rich_text);
        } else if (std.mem.eql(u8, block.type, "bulleted_list_item")) {
            try buf.appendSlice(allocator, "- ");
            if (block.bulleted_list_item) |b| try appendRichText(&buf, allocator, b.rich_text);
        } else if (std.mem.eql(u8, block.type, "numbered_list_item")) {
            try buf.appendSlice(allocator, "1. ");
            if (block.numbered_list_item) |n| try appendRichText(&buf, allocator, n.rich_text);
        } else if (std.mem.eql(u8, block.type, "code")) {
            if (block.code) |c| {
                try buf.appendSlice(allocator, "```");
                if (c.language) |lang| {
                    try buf.appendSlice(allocator, lang);
                }
                try buf.appendSlice(allocator, "\n");
                try appendRichText(&buf, allocator, c.rich_text);
                try buf.appendSlice(allocator, "\n```");
            }
        } else if (std.mem.eql(u8, block.type, "quote")) {
            try buf.appendSlice(allocator, "> ");
            if (block.quote) |q| try appendRichText(&buf, allocator, q.rich_text);
        } else if (std.mem.eql(u8, block.type, "to_do")) {
            if (block.to_do) |td| {
                if (td.checked) {
                    try buf.appendSlice(allocator, "- [x] ");
                } else {
                    try buf.appendSlice(allocator, "- [ ] ");
                }
                try appendRichText(&buf, allocator, td.rich_text);
            }
        } else if (std.mem.eql(u8, block.type, "divider")) {
            try buf.appendSlice(allocator, "---");
        }
    }

    return try buf.toOwnedSlice(allocator);
}

fn appendRichText(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, rich_text: []const RichTextJson) !void {
    for (rich_text) |rt| {
        try buf.appendSlice(allocator, rt.plain_text);
    }
}

// --- Fetch functions (use http.zig, network dependent) ---

fn notionHeaders() [1]std.http.Header {
    return .{.{ .name = "notion-version", .value = notion_version }};
}

fn authHeader(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
}

pub fn fetchMyTasks(allocator: std.mem.Allocator, api_key: []const u8) !TasksResult {
    const auth = try authHeader(allocator, api_key);
    defer allocator.free(auth);

    // Step 1: Search for databases
    const search_body =
        \\{"filter":{"value":"database","property":"object"}}
    ;
    const search_url = base_url ++ "/search";
    const search_resp = try http.postJson(allocator, search_url, auth, search_body);
    defer allocator.free(search_resp);

    const databases = try parseSearchDatabases(allocator, search_resp);

    // Step 2: Query each database for tasks
    var all_tasks: std.ArrayList(NotionTask) = .{};
    defer all_tasks.deinit(allocator);

    for (databases) |db| {
        const query_url = try std.fmt.allocPrint(allocator, base_url ++ "/databases/{s}/query", .{db.id});
        defer allocator.free(query_url);

        const query_body = "{}";
        const query_resp = try http.postJson(allocator, query_url, auth, query_body);
        defer allocator.free(query_resp);

        const tasks = try parseQueryResponse(allocator, query_resp, db.status_property);
        try all_tasks.appendSlice(allocator, tasks);
        allocator.free(tasks);
    }

    return .{
        .tasks = try all_tasks.toOwnedSlice(allocator),
        .databases = databases,
    };
}

pub fn fetchPageContent(allocator: std.mem.Allocator, api_key: []const u8, page_id: []const u8) ![]u8 {
    const auth = try authHeader(allocator, api_key);
    defer allocator.free(auth);

    var extra_hdrs = notionHeaders();

    const url = try std.fmt.allocPrint(allocator, base_url ++ "/blocks/{s}/children", .{page_id});
    defer allocator.free(url);

    const resp = try http.get(allocator, url, auth, &extra_hdrs);
    defer allocator.free(resp);

    return parseBlocksToMarkdown(allocator, resp);
}

pub fn updatePageStatus(allocator: std.mem.Allocator, api_key: []const u8, page_id: []const u8, status_prop: []const u8, status_name: []const u8) !void {
    const auth = try authHeader(allocator, api_key);
    defer allocator.free(auth);

    const body = try std.fmt.allocPrint(allocator,
        \\{{"properties":{{"{s}":{{"status":{{"name":"{s}"}}}}}}}}
    , .{ status_prop, status_name });
    defer allocator.free(body);

    const url = try std.fmt.allocPrint(allocator, base_url ++ "/pages/{s}", .{page_id});
    defer allocator.free(url);

    const resp = try http.patch(allocator, url, auth, body);
    allocator.free(resp);
}

// --- Tests ---

test "parseSearchDatabases finds databases with status+people properties" {
    const json =
        \\{"results":[
        \\  {"id":"db1","title":[{"plain_text":"Tasks"}],"properties":{
        \\    "Status":{"type":"status"},
        \\    "Assignee":{"type":"people"},
        \\    "Name":{"type":"title"}
        \\  }},
        \\  {"id":"db2","title":[{"plain_text":"Notes"}],"properties":{
        \\    "Tags":{"type":"multi_select"},
        \\    "Name":{"type":"title"}
        \\  }},
        \\  {"id":"db3","title":[{"plain_text":"Projects"}],"properties":{
        \\    "State":{"type":"status"},
        \\    "Owner":{"type":"people"},
        \\    "Name":{"type":"title"}
        \\  }}
        \\]}
    ;
    const dbs = try parseSearchDatabases(std.testing.allocator, json);
    defer {
        for (dbs) |db| {
            std.testing.allocator.free(db.id);
            std.testing.allocator.free(db.title);
            std.testing.allocator.free(db.status_property);
            std.testing.allocator.free(db.assignee_property);
        }
        std.testing.allocator.free(dbs);
    }

    try std.testing.expectEqual(@as(usize, 2), dbs.len);
    try std.testing.expectEqualStrings("db1", dbs[0].id);
    try std.testing.expectEqualStrings("Tasks", dbs[0].title);
    try std.testing.expectEqualStrings("Status", dbs[0].status_property);
    try std.testing.expectEqualStrings("Assignee", dbs[0].assignee_property);
    try std.testing.expectEqualStrings("db3", dbs[1].id);
    try std.testing.expectEqualStrings("Projects", dbs[1].title);
}

test "parseQueryResponse extracts tasks with status" {
    const json =
        \\{"results":[{
        \\  "id":"page1",
        \\  "url":"https://notion.so/page1",
        \\  "properties":{
        \\    "Name":{"type":"title","title":[{"plain_text":"My task"}]},
        \\    "Status":{"type":"status","status":{"name":"In Progress","group":"in_progress","color":"blue"}}
        \\  }
        \\}]}
    ;
    const tasks = try parseQueryResponse(std.testing.allocator, json, "Status");
    defer {
        for (tasks) |t| {
            std.testing.allocator.free(t.page_id);
            std.testing.allocator.free(t.title);
            std.testing.allocator.free(t.status_name);
            std.testing.allocator.free(t.status_group);
            std.testing.allocator.free(t.url);
        }
        std.testing.allocator.free(tasks);
    }

    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualStrings("page1", tasks[0].page_id);
    try std.testing.expectEqualStrings("My task", tasks[0].title);
    try std.testing.expectEqualStrings("In Progress", tasks[0].status_name);
    try std.testing.expectEqualStrings("started", tasks[0].status_group);
    try std.testing.expectEqualStrings("https://notion.so/page1", tasks[0].url);
}

test "parseBlocksToMarkdown converts various block types" {
    const json =
        \\{"results":[
        \\  {"type":"heading_1","heading_1":{"rich_text":[{"plain_text":"Title"}]}},
        \\  {"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"Some text"}]}},
        \\  {"type":"bulleted_list_item","bulleted_list_item":{"rich_text":[{"plain_text":"Item one"}]}},
        \\  {"type":"numbered_list_item","numbered_list_item":{"rich_text":[{"plain_text":"Step one"}]}},
        \\  {"type":"code","code":{"rich_text":[{"plain_text":"x = 1"}],"language":"python"}},
        \\  {"type":"quote","quote":{"rich_text":[{"plain_text":"A quote"}]}},
        \\  {"type":"to_do","to_do":{"rich_text":[{"plain_text":"Unchecked"}],"checked":false}},
        \\  {"type":"to_do","to_do":{"rich_text":[{"plain_text":"Checked"}],"checked":true}},
        \\  {"type":"divider"}
        \\]}
    ;
    const md = try parseBlocksToMarkdown(std.testing.allocator, json);
    defer std.testing.allocator.free(md);

    const expected =
        \\# Title
        \\Some text
        \\- Item one
        \\1. Step one
        \\```python
        \\x = 1
        \\```
        \\> A quote
        \\- [ ] Unchecked
        \\- [x] Checked
        \\---
    ;
    try std.testing.expectEqualStrings(expected, md);
}

test "status group mapping works correctly" {
    try std.testing.expectEqualStrings("unstarted", mapStatusGroup("to_do"));
    try std.testing.expectEqualStrings("started", mapStatusGroup("in_progress"));
    try std.testing.expectEqualStrings("completed", mapStatusGroup("complete"));
    try std.testing.expectEqualStrings("unstarted", mapStatusGroup("something_else"));
}
