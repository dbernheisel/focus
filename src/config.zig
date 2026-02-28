const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;

pub const ConfigError = error{
    NoWorkspaces,
    FileNotFound,
    ParseError,
};

pub const LinearWorkspace = struct {
    api_key: []const u8,
    workspace: []const u8,
    desktop_links: bool,
    default_team: []const u8,

    pub fn deinit(self: LinearWorkspace, allocator: Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.workspace);
        if (self.default_team.len > 0) allocator.free(self.default_team);
    }
};

pub const NotionWorkspace = struct {
    api_key: []const u8,

    pub fn deinit(self: NotionWorkspace, allocator: Allocator) void {
        allocator.free(self.api_key);
    }
};

pub const Config = struct {
    linear: []LinearWorkspace,
    notion: []NotionWorkspace,
    default_team: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *Config) void {
        if (self.default_team.len > 0) self.allocator.free(self.default_team);

        for (self.linear) |ws| {
            ws.deinit(self.allocator);
        }
        self.allocator.free(self.linear);

        for (self.notion) |ws| {
            ws.deinit(self.allocator);
        }
        self.allocator.free(self.notion);
    }
};

fn stripTrailingCommas(allocator: Allocator, input: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, input.len);
    var o: usize = 0;
    var in_string = false;
    var escape = false;
    for (input) |c| {
        if (escape) {
            out[o] = c;
            o += 1;
            escape = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') escape = true;
            if (c == '"') in_string = false;
            out[o] = c;
            o += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            out[o] = c;
            o += 1;
            continue;
        }
        if ((c == ']' or c == '}') and o > 0) {
            var j = o - 1;
            while (j > 0 and (out[j] == ' ' or out[j] == '\t' or out[j] == '\n' or out[j] == '\r')) : (j -= 1) {}
            if (out[j] == ',') {
                o = j;
            }
        }
        out[o] = c;
        o += 1;
    }
    return allocator.realloc(out, o);
}

pub fn parseConfig(allocator: Allocator, json_bytes: []const u8) ConfigError!Config {
    const clean = stripTrailingCommas(allocator, json_bytes) catch return ConfigError.ParseError;
    defer allocator.free(clean);

    const parsed = json.parseFromSlice(
        JsonConfig,
        allocator,
        clean,
        .{ .ignore_unknown_fields = true },
    ) catch return ConfigError.ParseError;
    defer parsed.deinit();

    const value = parsed.value;

    const linear_src = value.linear orelse &.{};
    const notion_src = value.notion orelse &.{};

    if (linear_src.len == 0 and notion_src.len == 0) {
        return ConfigError.NoWorkspaces;
    }

    var linear = allocator.alloc(LinearWorkspace, linear_src.len) catch return ConfigError.ParseError;
    errdefer {
        // Free any already-initialized entries on error
        allocator.free(linear);
    }
    var linear_init_count: usize = 0;
    errdefer {
        for (linear[0..linear_init_count]) |ws| {
            ws.deinit(allocator);
        }
    }

    for (linear_src, 0..) |src, i| {
        const api_key_src = src.api_key orelse return ConfigError.ParseError;
        const api_key = allocator.dupe(u8, api_key_src) catch return ConfigError.ParseError;
        errdefer allocator.free(api_key);

        const workspace_src = src.workspace orelse "";
        const workspace = allocator.dupe(u8, workspace_src) catch return ConfigError.ParseError;

        const default_team_src = src.default_team orelse "";
        const default_team = if (default_team_src.len > 0)
            allocator.dupe(u8, default_team_src) catch return ConfigError.ParseError
        else
            "";

        linear[i] = .{
            .api_key = api_key,
            .workspace = workspace,
            .desktop_links = src.desktop_links orelse false,
            .default_team = default_team,
        };
        linear_init_count += 1;
    }

    var notion = allocator.alloc(NotionWorkspace, notion_src.len) catch return ConfigError.ParseError;
    errdefer {
        allocator.free(notion);
    }
    var notion_init_count: usize = 0;
    errdefer {
        for (notion[0..notion_init_count]) |ws| {
            ws.deinit(allocator);
        }
    }

    for (notion_src, 0..) |src, i| {
        const api_key_src = src.api_key orelse return ConfigError.ParseError;
        const api_key = allocator.dupe(u8, api_key_src) catch return ConfigError.ParseError;

        notion[i] = .{
            .api_key = api_key,
        };
        notion_init_count += 1;
    }

    const global_default_src = value.default_team orelse "";
    const global_default = if (global_default_src.len > 0)
        allocator.dupe(u8, global_default_src) catch return ConfigError.ParseError
    else
        "";

    return .{
        .linear = linear,
        .notion = notion,
        .default_team = global_default,
        .allocator = allocator,
    };
}

pub fn loadConfig(allocator: Allocator) (ConfigError || std.fs.File.OpenError || std.fs.File.ReadError)!Config {
    const home = std.posix.getenv("HOME") orelse return ConfigError.FileNotFound;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = std.fmt.bufPrint(&path_buf, "{s}/.config/focus/config.json", .{home}) catch return ConfigError.FileNotFound;

    const file = std.fs.openFileAbsolute(config_path, .{}) catch return ConfigError.FileNotFound;
    defer file.close();

    const json_bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch return ConfigError.ParseError;
    defer allocator.free(json_bytes);

    return parseConfig(allocator, json_bytes);
}

// Internal JSON schema types for parsing
const JsonLinearWorkspace = struct {
    api_key: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    desktop_links: ?bool = null,
    default_team: ?[]const u8 = null,
};

const JsonNotionWorkspace = struct {
    api_key: ?[]const u8 = null,
};

const JsonConfig = struct {
    linear: ?[]const JsonLinearWorkspace = null,
    notion: ?[]const JsonNotionWorkspace = null,
    default_team: ?[]const u8 = null,
};

// Tests

test "parse valid config with both linear and notion" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "linear": [
        \\    { "api_key": "lin_api_abc123", "workspace": "my-team", "desktop_links": true }
        \\  ],
        \\  "notion": [
        \\    { "api_key": "ntn_xyz789" }
        \\  ]
        \\}
    ;

    var cfg = try parseConfig(allocator, input);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.linear.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.notion.len);
    try std.testing.expectEqualStrings("lin_api_abc123", cfg.linear[0].api_key);
    try std.testing.expectEqualStrings("my-team", cfg.linear[0].workspace);
    try std.testing.expect(cfg.linear[0].desktop_links);
    try std.testing.expectEqualStrings("ntn_xyz789", cfg.notion[0].api_key);
}

test "parse config with no workspaces returns NoWorkspaces" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "linear": [],
        \\  "notion": []
        \\}
    ;

    const result = parseConfig(allocator, input);
    try std.testing.expectError(ConfigError.NoWorkspaces, result);
}

test "parse config with only linear (no notion key)" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "linear": [
        \\    { "api_key": "lin_api_abc123" }
        \\  ]
        \\}
    ;

    var cfg = try parseConfig(allocator, input);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.linear.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.notion.len);
    try std.testing.expectEqualStrings("lin_api_abc123", cfg.linear[0].api_key);
    try std.testing.expectEqualStrings("", cfg.linear[0].workspace);
    try std.testing.expect(!cfg.linear[0].desktop_links);
}

test "parse config with only notion (no linear key)" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "notion": [
        \\    { "api_key": "ntn_abc" }
        \\  ]
        \\}
    ;

    var cfg = try parseConfig(allocator, input);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 0), cfg.linear.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.notion.len);
    try std.testing.expectEqualStrings("ntn_abc", cfg.notion[0].api_key);
}

test "parse empty object returns NoWorkspaces" {
    const allocator = std.testing.allocator;
    const input = "{}";

    const result = parseConfig(allocator, input);
    try std.testing.expectError(ConfigError.NoWorkspaces, result);
}

test "parse invalid json returns ParseError" {
    const allocator = std.testing.allocator;
    const input = "not valid json";

    const result = parseConfig(allocator, input);
    try std.testing.expectError(ConfigError.ParseError, result);
}

test "parse config with trailing commas" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "linear": [
        \\    { "api_key": "lin_api_abc123", },
        \\  ],
        \\}
    ;

    var cfg = try parseConfig(allocator, input);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.linear.len);
    try std.testing.expectEqualStrings("lin_api_abc123", cfg.linear[0].api_key);
}
