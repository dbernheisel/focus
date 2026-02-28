const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BlockType = enum { heading1, heading2, heading3, bullet, code_block, text, quote };

pub const Block = struct {
    block_type: BlockType,
    content: []const u8,
};

pub fn parse(allocator: Allocator, text: ?[]const u8) ![]Block {
    const input = text orelse return try allocator.alloc(Block, 0);
    if (input.len == 0) return try allocator.alloc(Block, 0);

    var blocks: std.ArrayList(Block) = .{};
    defer blocks.deinit(allocator);

    var in_code_block = false;
    var code_lines: std.ArrayList(u8) = .{};
    defer code_lines.deinit(allocator);

    var lines_iter = std.mem.splitSequence(u8, input, "\n");
    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code_block) {
                // Close code block - dupe the accumulated content
                const content = try allocator.dupe(u8, code_lines.items);
                try blocks.append(allocator, .{ .block_type = .code_block, .content = content });
                code_lines.clearRetainingCapacity();
                in_code_block = false;
            } else {
                in_code_block = true;
            }
            continue;
        }

        if (in_code_block) {
            if (code_lines.items.len > 0) {
                try code_lines.append(allocator, '\n');
            }
            try code_lines.appendSlice(allocator, line);
            continue;
        }

        // Outside code block
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "### ")) {
            try blocks.append(allocator, .{ .block_type = .heading3, .content = line[4..] });
        } else if (std.mem.startsWith(u8, line, "## ")) {
            try blocks.append(allocator, .{ .block_type = .heading2, .content = line[3..] });
        } else if (std.mem.startsWith(u8, line, "# ")) {
            try blocks.append(allocator, .{ .block_type = .heading1, .content = line[2..] });
        } else if (std.mem.startsWith(u8, line, "- ")) {
            try blocks.append(allocator, .{ .block_type = .bullet, .content = line[2..] });
        } else if (std.mem.startsWith(u8, line, "* ")) {
            try blocks.append(allocator, .{ .block_type = .bullet, .content = line[2..] });
        } else if (std.mem.startsWith(u8, line, "> ")) {
            try blocks.append(allocator, .{ .block_type = .quote, .content = line[2..] });
        } else {
            try blocks.append(allocator, .{ .block_type = .text, .content = line });
        }
    }

    return try blocks.toOwnedSlice(allocator);
}

pub fn stripInline(allocator: Allocator, text: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        // Check for images: ![alt](url)
        if (i < text.len - 1 and text[i] == '!' and text[i + 1] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 2, ']')) |close_bracket| {
                if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')')) |close_paren| {
                        // Remove image entirely
                        i = close_paren + 1;
                        continue;
                    }
                }
            }
        }

        // Check for links: [text](url)
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close_bracket| {
                if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')')) |close_paren| {
                        // Keep link text only
                        try result.appendSlice(allocator, text[i + 1 .. close_bracket]);
                        i = close_paren + 1;
                        continue;
                    }
                }
            }
        }

        // Check for **bold** or __bold__
        if (i + 3 < text.len and ((text[i] == '*' and text[i + 1] == '*') or (text[i] == '_' and text[i + 1] == '_'))) {
            const marker = text[i];
            // Find closing **
            if (findDoubleMarker(text, i + 2, marker)) |end| {
                try result.appendSlice(allocator, text[i + 2 .. end]);
                i = end + 2;
                continue;
            }
        }

        // Check for _italic_ (single underscore only, not double)
        if (text[i] == '_' and (i + 1 >= text.len or text[i + 1] != '_')) {
            if (i + 2 < text.len) {
                if (findSingleMarker(text, i + 1, '_')) |end| {
                    // Make sure it's not a double underscore at close
                    if (end + 1 >= text.len or text[end + 1] != '_') {
                        try result.appendSlice(allocator, text[i + 1 .. end]);
                        i = end + 1;
                        continue;
                    }
                }
            }
        }

        try result.append(allocator, text[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

fn findDoubleMarker(text: []const u8, start: usize, marker: u8) ?usize {
    var i = start;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == marker and text[i + 1] == marker) {
            return i;
        }
    }
    return null;
}

fn findSingleMarker(text: []const u8, start: usize, marker: u8) ?usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == marker) {
            return i;
        }
    }
    return null;
}

// --- Tests ---

test "parse headings all 3 levels" {
    const input = "# Heading 1\n## Heading 2\n### Heading 3";
    const blocks = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(blocks);

    try std.testing.expectEqual(3, blocks.len);
    try std.testing.expectEqual(.heading1, blocks[0].block_type);
    try std.testing.expectEqualStrings("Heading 1", blocks[0].content);
    try std.testing.expectEqual(.heading2, blocks[1].block_type);
    try std.testing.expectEqualStrings("Heading 2", blocks[1].content);
    try std.testing.expectEqual(.heading3, blocks[2].block_type);
    try std.testing.expectEqualStrings("Heading 3", blocks[2].content);
}

test "parse bullets dash and star" {
    const input = "- item one\n* item two";
    const blocks = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(blocks);

    try std.testing.expectEqual(2, blocks.len);
    try std.testing.expectEqual(.bullet, blocks[0].block_type);
    try std.testing.expectEqualStrings("item one", blocks[0].content);
    try std.testing.expectEqual(.bullet, blocks[1].block_type);
    try std.testing.expectEqualStrings("item two", blocks[1].content);
}

test "parse code block multiline" {
    const input = "```\nline one\nline two\n```";
    const blocks = try parse(std.testing.allocator, input);
    defer {
        for (blocks) |b| {
            if (b.block_type == .code_block) {
                std.testing.allocator.free(b.content);
            }
        }
        std.testing.allocator.free(blocks);
    }

    try std.testing.expectEqual(1, blocks.len);
    try std.testing.expectEqual(.code_block, blocks[0].block_type);
    try std.testing.expectEqualStrings("line one\nline two", blocks[0].content);
}

test "parse skips empty lines" {
    const input = "hello\n\nworld";
    const blocks = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(blocks);

    try std.testing.expectEqual(2, blocks.len);
    try std.testing.expectEqualStrings("hello", blocks[0].content);
    try std.testing.expectEqualStrings("world", blocks[1].content);
}

test "parse null and empty returns empty" {
    const null_blocks = try parse(std.testing.allocator, null);
    defer std.testing.allocator.free(null_blocks);
    try std.testing.expectEqual(0, null_blocks.len);

    const empty_blocks = try parse(std.testing.allocator, "");
    defer std.testing.allocator.free(empty_blocks);
    try std.testing.expectEqual(0, empty_blocks.len);
}

test "parse quote blocks" {
    const input = "> quoted text\n> another quote";
    const blocks = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(blocks);

    try std.testing.expectEqual(2, blocks.len);
    try std.testing.expectEqual(.quote, blocks[0].block_type);
    try std.testing.expectEqualStrings("quoted text", blocks[0].content);
    try std.testing.expectEqual(.quote, blocks[1].block_type);
    try std.testing.expectEqualStrings("another quote", blocks[1].content);
}

test "stripInline removes bold markers" {
    const result = try stripInline(std.testing.allocator, "hello **bold** and __also bold__");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello bold and also bold", result);
}

test "stripInline keeps link text drops URL" {
    const result = try stripInline(std.testing.allocator, "click [here](http://example.com) now");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("click here now", result);
}

test "stripInline removes images entirely" {
    const result = try stripInline(std.testing.allocator, "before ![alt](http://img.png) after");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("before  after", result);
}
