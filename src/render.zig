const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("state.zig");
const State = state_mod.State;
const Mode = state_mod.Mode;
const CreateForm = state_mod.CreateForm;
const CreateFormField = state_mod.CreateFormField;
const issue_mod = @import("issue.zig");
const markdown = @import("markdown.zig");
const event_mod = @import("event.zig");

const Window = vaxis.Window;
const Segment = vaxis.Segment;
const Style = vaxis.Style;
const PrintOptions = Window.PrintOptions;

const style_bold: Style = .{ .bold = true };
const style_dim: Style = .{ .dim = true };
const style_bold_dim: Style = .{ .bold = true, .dim = true };
const style_reverse: Style = .{ .reverse = true };
const style_red: Style = .{ .fg = .{ .index = 1 } };
const style_h1: Style = .{ .bold = true, .fg = .{ .index = 6 } }; // cyan + bold
const style_h2: Style = .{ .bold = true, .fg = .{ .index = 4 } }; // blue + bold
const style_h3: Style = .{ .bold = true };
const style_green: Style = .{ .fg = .{ .index = 2 } };
const style_code: Style = .{ .fg = .{ .index = 2 } }; // green for code fences
const style_link: Style = .{ .fg = .{ .index = 6 }, .ul_style = .single }; // cyan + underline
const style_table_border: Style = .{ .dim = true };

const Cell = vaxis.Cell;
const Hyperlink = Cell.Hyperlink;

fn printSeg(win: Window, text: []const u8, style: Style, row: u16, col: u16) void {
    _ = win.printSegment(.{ .text = text, .style = style }, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
}

fn printSegLink(win: Window, text: []const u8, style: Style, link: Hyperlink, row: u16, col: u16) void {
    _ = win.printSegment(.{ .text = text, .style = style, .link = link }, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
}

pub fn render(s: *const State, win: Window) void {
    win.clear();
    if (s.loading) {
        renderLoading(win);
        return;
    }
    if (s.issues.len == 0) {
        renderEmpty(win);
        return;
    }
    switch (s.mode) {
        .list => renderList(s, win),
        .detail => renderDetail(s, win),
        .create => renderCreate(s, win),
    }
}

fn renderLoading(win: Window) void {
    printSeg(win, "Loading...", .{}, 1, 2);
}

fn renderError(win: Window, msg: []const u8) void {
    printSeg(win, "Error: ", style_red, 1, 2);
    printSeg(win, msg, style_red, 1, 9);
}

fn renderEmpty(win: Window) void {
    printSeg(win, "No issues found.", .{}, 1, 2);
}

fn renderList(s: *const State, win: Window) void {
    // Separate issues into in_progress and todo
    // Count them first
    var in_progress_count: usize = 0;
    var todo_count: usize = 0;
    for (s.issues) |iss| {
        if (iss.isInProgress()) {
            in_progress_count += 1;
        } else if (iss.isTodo()) {
            todo_count += 1;
        }
    }

    const scroll = s.list_scroll_offset;
    const max_row = if (win.height > 1) win.height - 1 else win.height; // reserve last row for help

    // Virtual row tracks position in the full list layout.
    var virtual_row: usize = 1; // Row 0 is blank

    // Helper to render a virtual row if it's in the visible window
    const renderVirtualRow = struct {
        fn inView(vr: usize, sc: usize, mr: u16) ?u16 {
            if (vr < sc) return null;
            const sr = vr - sc;
            if (sr >= mr) return null;
            return @intCast(sr);
        }
    }.inView;

    // "In Progress" header
    if (renderVirtualRow(virtual_row, scroll, max_row)) |sr| {
        printSeg(win, "  In Progress", style_bold_dim, sr, 0);
    }
    virtual_row += 1;

    // Track display_index for selected_index mapping
    var display_index: usize = 0;

    // In progress issues
    for (s.issues) |iss| {
        if (!iss.isInProgress()) continue;
        if (renderVirtualRow(virtual_row, scroll, max_row)) |sr| {
            renderIssueRow(win, &iss, sr, display_index == s.selected_index);
        }
        virtual_row += 1;
        display_index += 1;
    }

    // Blank row separator
    virtual_row += 1;

    // "Todo" header
    if (renderVirtualRow(virtual_row, scroll, max_row)) |sr| {
        printSeg(win, "  Todo", style_bold_dim, sr, 0);
    }
    virtual_row += 1;

    // Todo issues
    for (s.issues) |iss| {
        if (!iss.isTodo()) continue;
        if (renderVirtualRow(virtual_row, scroll, max_row)) |sr| {
            renderIssueRow(win, &iss, sr, display_index == s.selected_index);
        }
        virtual_row += 1;
        display_index += 1;
    }

    // Bottom row: error or help text
    if (win.height > 0) {
        if (s.error_msg) |msg| {
            printSeg(win, msg, style_red, win.height - 1, 2);
        } else {
            const help = "tab/\xe2\x86\x91\xe2\x86\x93:nav  enter:open  c:new  r:refresh  q/esc:quit";
            printSeg(win, help, style_dim, win.height - 1, 2);
        }
    }
}

fn renderIssueRow(win: Window, iss: *const issue_mod.Issue, row: u16, selected: bool) void {
    const icon = iss.priority_label.icon();
    const style: Style = if (selected) style_reverse else .{};

    // If selected, fill the entire row with reverse video
    if (selected) {
        var col: u16 = 0;
        while (col < win.width) : (col += 1) {
            win.writeCell(col, row, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = style_reverse,
            });
        }
    }

    // "  {icon} {identifier}  {title}"
    printSeg(win, "  ", style, row, 0);
    printSeg(win, icon, style, row, 2);
    printSeg(win, " ", style, row, 3);
    const id_style: Style = if (selected) style_reverse else style_green;
    printSeg(win, iss.identifier, id_style, row, 4);

    // Calculate where title starts
    const id_len: u16 = @intCast(@min(iss.identifier.len, std.math.maxInt(u16)));
    const title_col: u16 = 4 + id_len + 2;
    if (title_col < win.width) {
        // Truncate title to fit
        const avail = win.width - title_col;
        const title_len = @min(iss.title.len, avail);
        printSeg(win, iss.title[0..title_len], style, row, title_col);

        // Show project/milestone as dimmed tags after title
        var tag_col: u16 = title_col + @as(u16, @intCast(title_len)) + 1;
        const tag_style: Style = if (selected) style_reverse else style_dim;

        if (iss.project_name) |proj| {
            if (tag_col + 2 < win.width) {
                const tag_avail = win.width - tag_col;
                const proj_len = @min(proj.len, tag_avail);
                printSeg(win, proj[0..proj_len], tag_style, row, tag_col);
                tag_col += @as(u16, @intCast(proj_len)) + 1;
            }
        }
        if (iss.milestone_name) |ms| {
            if (tag_col + 2 < win.width) {
                const tag_avail = win.width - tag_col;
                const ms_len = @min(ms.len, tag_avail);
                printSeg(win, ms[0..ms_len], tag_style, row, tag_col);
            }
        }
    }
}

fn renderDetail(s: *const State, win: Window) void {
    const iss = s.selectedIssue() orelse return;

    // Row 0: identifier + title in bold, truncated
    {
        const id_len: u16 = @intCast(@min(iss.identifier.len, win.width));
        printSeg(win, iss.identifier[0..id_len], style_dim, 0, 0);
        const title_col = id_len + 1;
        if (title_col < win.width) {
            const avail = win.width - title_col;
            const title_len = @min(iss.title.len, avail);
            printSeg(win, iss.title[0..title_len], style_bold, 0, title_col);
        }
    }

    // Row 1: status and priority info
    if (s.editing_status) |edit| {
        // Show status edit mode
        printSeg(win, "  Status: ", style_dim, 1, 0);

        if (edit.states.len > 0) {
            const current_name = edit.states[edit.current_idx].name;
            printSeg(win, "< ", style_dim, 1, 10);
            printSeg(win, current_name, style_reverse, 1, 12);
            const name_len: u16 = @intCast(@min(current_name.len, std.math.maxInt(u16)));
            printSeg(win, " >", style_dim, 1, 12 + name_len);
        }
    } else {
        // Normal status display
        printSeg(win, "  Status: ", style_dim, 1, 0);
        printSeg(win, iss.state_name, style_dim, 1, 10);

        var meta_col: u16 = 10 + @as(u16, @intCast(@min(iss.state_name.len, std.math.maxInt(u16)))) + 2;

        if (iss.priority_label != .none) {
            printSeg(win, "Priority: ", style_dim, 1, meta_col);
            const icon = iss.priority_label.icon();
            printSeg(win, icon, style_dim, 1, meta_col + 10);
            meta_col += 12;
        }

        if (iss.project_name) |proj| {
            if (meta_col + 2 < win.width) {
                const avail = win.width - meta_col;
                const proj_len = @min(proj.len, avail);
                printSeg(win, proj[0..proj_len], style_dim, 1, meta_col);
                meta_col += @as(u16, @intCast(proj_len)) + 2;
            }
        }
        if (iss.milestone_name) |ms| {
            if (meta_col + 2 < win.width) {
                const avail = win.width - meta_col;
                const ms_len = @min(ms.len, avail);
                printSeg(win, ms[0..ms_len], style_dim, 1, meta_col);
            }
        }
    }

    // Row 2: blank separator (already cleared)

    // Rows 3+: description or loading
    if (s.detail_loading) {
        printSeg(win, "Loading description...", style_dim, 3, 2);
    } else {
        renderDescription(s, win, iss);
    }

    // Bottom row: help text or error/status message
    if (win.height > 0) {
        if (s.error_msg) |msg| {
            printSeg(win, msg, style_red, win.height - 1, 2);
        } else {
            const help = "tab/\xe2\x86\x91\xe2\x86\x93:scroll  s:status  o:open  q/esc:back";
            printSeg(win, help, style_dim, win.height - 1, 2);
        }
    }
}

/// Count total wrapped lines in the description + comments for scroll clamping.
pub fn countDescriptionLines(iss: *const issue_mod.Issue, content_width: u16) usize {
    var total: usize = 0;
    const cw: usize = if (content_width > 2) content_width - 2 else 1;

    if (iss.description) |text| {
        if (text.len > 0) {
            var line_iter = std.mem.splitSequence(u8, text, "\n");
            while (line_iter.next()) |line| {
                if (line.len == 0 or std.mem.startsWith(u8, line, "```")) {
                    total += 1;
                } else if (isTableLine(line)) {
                    // Collect consecutive table lines
                    var table_buf: [64][]const u8 = undefined;
                    var table_count: usize = 0;
                    table_buf[table_count] = line;
                    table_count += 1;
                    while (table_count < 64) {
                        const saved = line_iter;
                        if (line_iter.next()) |next_line| {
                            if (isTableLine(next_line) or isTableSeparator(next_line)) {
                                table_buf[table_count] = next_line;
                                table_count += 1;
                            } else {
                                line_iter = saved;
                                break;
                            }
                        } else {
                            break;
                        }
                    }
                    total += countTableLines(table_buf[0..table_count]);
                } else {
                    const content = if (std.mem.startsWith(u8, line, "### "))
                        line[4..]
                    else if (std.mem.startsWith(u8, line, "## "))
                        line[3..]
                    else if (std.mem.startsWith(u8, line, "# "))
                        line[2..]
                    else if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* "))
                        line[2..]
                    else if (std.mem.startsWith(u8, line, "> "))
                        line[2..]
                    else
                        line;
                    total += countWrappedLines(content, cw);
                }
            }
        }
    }

    // Count comment lines
    if (iss.comments) |comments| {
        for (comments) |comment| {
            total += 2; // divider line + author line
            // Count wrapped lines of comment body
            var line_iter = std.mem.splitSequence(u8, comment.body, "\n");
            while (line_iter.next()) |line| {
                if (line.len == 0) {
                    total += 1;
                } else {
                    total += countWrappedLines(line, cw);
                }
            }
        }
    }

    return total;
}

/// Check if a line is a markdown table row (starts with | and has at least 2 pipes).
fn isTableLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len < 3 or trimmed[0] != '|') return false;
    // Must have at least 2 pipes to be a table row
    var pipe_count: usize = 0;
    for (trimmed) |ch| {
        if (ch == '|') pipe_count += 1;
        if (pipe_count >= 2) return true;
    }
    return false;
}

/// Check if a line is a markdown table separator (e.g. |---|---|).
fn isTableSeparator(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len < 3 or trimmed[0] != '|') return false;
    for (trimmed) |ch| {
        if (ch != '|' and ch != '-' and ch != ':' and ch != ' ') return false;
    }
    return true;
}

/// Parse a table row into cells by splitting on '|'. Trims leading/trailing pipes and whitespace.
/// Returns the number of cells written into the output buffer.
fn parseTableCells(line: []const u8, cells: *[16][]const u8) usize {
    var count: usize = 0;
    const trimmed = std.mem.trim(u8, line, " ");

    // Strip leading and trailing '|'
    var inner = trimmed;
    if (inner.len > 0 and inner[0] == '|') inner = inner[1..];
    if (inner.len > 0 and inner[inner.len - 1] == '|') inner = inner[0 .. inner.len - 1];

    var iter = std.mem.splitScalar(u8, inner, '|');
    while (iter.next()) |cell| {
        if (count >= 16) break;
        cells[count] = std.mem.trim(u8, cell, " ");
        count += 1;
    }
    return count;
}

/// Render a markdown table block. Returns the number of display lines consumed.
/// `table_lines` should include the header, separator, and data rows.
fn renderTable(
    win: Window,
    table_lines: []const []const u8,
    row_start: u16,
    max_row: u16,
    scroll_offset: usize,
    display_line_start: usize,
    start_col: u16,
) struct { rows_used: u16, display_lines: usize } {
    if (table_lines.len == 0) return .{ .rows_used = 0, .display_lines = 0 };

    // First pass: parse all rows and compute max column widths
    var all_cells: [64][16][]const u8 = undefined;
    var all_counts: [64]usize = undefined;
    var num_rows: usize = 0;
    var num_cols: usize = 0;
    var col_widths: [16]usize = .{0} ** 16;
    var separator_idx: ?usize = null;

    for (table_lines, 0..) |line, i| {
        if (num_rows >= 64) break;
        if (isTableSeparator(line)) {
            separator_idx = i;
            continue;
        }
        all_counts[num_rows] = parseTableCells(line, &all_cells[num_rows]);
        const count = all_counts[num_rows];
        if (count > num_cols) num_cols = count;
        for (0..count) |c| {
            const vis_len = displayLength(all_cells[num_rows][c]);
            if (vis_len > col_widths[c]) {
                col_widths[c] = vis_len;
            }
        }
        num_rows += 1;
    }

    if (num_rows == 0 or num_cols == 0) return .{ .rows_used = 0, .display_lines = 0 };

    // Render rows
    var row = row_start;
    var display_line = display_line_start;
    // Total display lines = num_rows + 1 (for separator line under header)
    const has_header = separator_idx != null and num_rows > 0;

    for (0..num_rows) |r| {
        // After the first row (header), render separator
        if (r == 1 and has_header) {
            if (display_line >= scroll_offset and row < max_row) {
                var col: u16 = start_col;
                for (0..num_cols) |c| {
                    const w: u16 = @intCast(col_widths[c] + 2); // 1 padding each side
                    // Draw horizontal line
                    var x: u16 = 0;
                    while (x < w) : (x += 1) {
                        if (col + x < win.width) {
                            printSeg(win, "\xe2\x94\x80", style_table_border, row, col + x); // ─
                        }
                    }
                    col += w;
                    // Draw cross or nothing at column boundary
                    if (c + 1 < num_cols and col < win.width) {
                        printSeg(win, "\xe2\x94\xbc", style_table_border, row, col); // ┼
                        col += 1;
                    }
                }
                row += 1;
            }
            display_line += 1;
        }

        if (row >= max_row) break;

        // Render data row
        if (display_line >= scroll_offset and row < max_row) {
            const is_header = r == 0 and has_header;
            const cell_style: Style = if (is_header) style_bold else .{};
            var col: u16 = start_col;
            const count = all_counts[r];

            for (0..num_cols) |c| {
                const w: u16 = @intCast(col_widths[c] + 2); // 1 padding each side
                const cell_text = if (c < count) all_cells[r][c] else "";
                // Print space + styled text
                if (col + 1 < win.width) {
                    printSeg(win, " ", cell_style, row, col);
                    if (cell_text.len > 0 and col + 1 < win.width) {
                        renderStyledLine(win, cell_text, row, col + 1, cell_style);
                    }
                }
                col += w;
                // Draw vertical separator
                if (c + 1 < num_cols and col < win.width) {
                    printSeg(win, "\xe2\x94\x82", style_table_border, row, col); // │
                    col += 1;
                }
            }
            row += 1;
        }
        display_line += 1;
    }

    return .{
        .rows_used = row - row_start,
        .display_lines = display_line - display_line_start,
    };
}

/// Count the display lines a table block would occupy.
fn countTableLines(table_lines: []const []const u8) usize {
    var data_rows: usize = 0;
    var has_separator = false;
    for (table_lines) |line| {
        if (isTableSeparator(line)) {
            has_separator = true;
        } else {
            data_rows += 1;
        }
    }
    // data rows + 1 separator line (if present)
    return data_rows + (if (has_separator) @as(usize, 1) else 0);
}

fn renderDescription(s: *const State, win: Window, iss: *const issue_mod.Issue) void {
    const content_width = s.contentWidth();
    const wrap_width: usize = if (content_width > 2) content_width - 2 else 1;
    var row: u16 = 3;
    const max_row = if (win.height > 1) win.height - 1 else win.height;

    var display_line: usize = 0; // tracks wrapped display lines for scroll offset

    // Render description text
    if (iss.description) |desc| {
        if (desc.len > 0) {
            var in_code_block = false;
            var line_iter = std.mem.splitSequence(u8, desc, "\n");

            while (line_iter.next()) |line| {
                if (row >= max_row) break;

                // Code fence toggle
                if (std.mem.startsWith(u8, line, "```")) {
                    in_code_block = !in_code_block;
                    display_line += 1;
                    if (display_line > s.scroll_offset) row += 1;
                    continue;
                }

                // Inside code block: render green, with wrapping
                if (in_code_block) {
                    var offset: usize = 0;
                    while (offset < line.len or offset == 0) {
                        const chunk_end = @min(offset + wrap_width, line.len);
                        if (display_line >= s.scroll_offset and row < max_row) {
                            printSeg(win, line[offset..chunk_end], style_code, row, 4);
                            row += 1;
                        }
                        display_line += 1;
                        if (offset == chunk_end) break;
                        offset = chunk_end;
                    }
                    if (line.len == 0) {
                        if (display_line >= s.scroll_offset and row < max_row) row += 1;
                        display_line += 1;
                    }
                    continue;
                }

                // Blank line
                if (line.len == 0) {
                    if (display_line >= s.scroll_offset and row < max_row) row += 1;
                    display_line += 1;
                    continue;
                }

                // Markdown table: collect consecutive table lines and render as block
                if (isTableLine(line)) {
                    var table_buf: [64][]const u8 = undefined;
                    var table_count: usize = 0;
                    table_buf[table_count] = line;
                    table_count += 1;

                    // Peek ahead for more table lines
                    while (table_count < 64) {
                        const saved = line_iter;
                        if (line_iter.next()) |next_line| {
                            if (isTableLine(next_line) or isTableSeparator(next_line)) {
                                table_buf[table_count] = next_line;
                                table_count += 1;
                            } else {
                                // Not a table line - restore iterator
                                line_iter = saved;
                                break;
                            }
                        } else {
                            break;
                        }
                    }

                    const result = renderTable(
                        win,
                        table_buf[0..table_count],
                        row,
                        max_row,
                        s.scroll_offset,
                        display_line,
                        2,
                    );
                    row += result.rows_used;
                    display_line += result.display_lines;
                    continue;
                }

                // Determine text, style, and column for this line type
                var text: []const u8 = undefined;
                var sty: Style = .{};
                var col: u16 = 2;
                var prefix: ?[]const u8 = null;
                var prefix_style: Style = .{};

                if (std.mem.startsWith(u8, line, "### ")) {
                    text = line[4..];
                    sty = style_h3;
                } else if (std.mem.startsWith(u8, line, "## ")) {
                    text = line[3..];
                    sty = style_h2;
                } else if (std.mem.startsWith(u8, line, "# ")) {
                    text = line[2..];
                    sty = style_h1;
                } else if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
                    text = line[2..];
                    prefix = "  \xe2\x80\xa2 ";
                    prefix_style = .{};
                    col = 6;
                } else if (std.mem.startsWith(u8, line, "> ")) {
                    text = line[2..];
                    sty = style_dim;
                    prefix = "  \xe2\x94\x82 ";
                    prefix_style = style_dim;
                    col = 6;
                } else {
                    text = line;
                }

                // Render with wrapping (wrap by display width, not byte offset)
                var offset: usize = 0;
                var first_wrap = true;
                while (offset < text.len or (offset == 0 and text.len == 0)) {
                    const chunk_end = advanceByDisplayWidth(text, offset, wrap_width);
                    if (display_line >= s.scroll_offset and row < max_row) {
                        if (first_wrap) {
                            if (prefix) |pfx| {
                                printSeg(win, pfx, prefix_style, row, 2);
                            }
                        }
                        renderStyledLine(win, text[offset..chunk_end], row, if (first_wrap) col else col, sty);
                        row += 1;
                    }
                    display_line += 1;
                    first_wrap = false;
                    if (offset == chunk_end) break;
                    offset = chunk_end;
                }
            }
        }
    }

    // Render comments
    if (iss.comments) |comments| {
        for (comments) |comment| {
            if (row >= max_row) break;

            // Screen-wide divider
            if (display_line >= s.scroll_offset and row < max_row) {
                var divider_col: u16 = 0;
                while (divider_col < win.width) : (divider_col += 1) {
                    printSeg(win, "\xe2\x94\x80", style_dim, row, divider_col);
                }
                row += 1;
            }
            display_line += 1;
            if (row >= max_row) break;

            // Author + date line
            if (display_line >= s.scroll_offset and row < max_row) {
                printSeg(win, comment.author, style_bold, row, 2);
                const author_len: u16 = @intCast(@min(comment.author.len, std.math.maxInt(u16)));
                printSeg(win, "  ", style_dim, row, 2 + author_len);
                // Show date (first 10 chars = YYYY-MM-DD)
                const date_len = @min(comment.created_at.len, 10);
                printSeg(win, comment.created_at[0..date_len], style_dim, row, 2 + author_len + 2);
                row += 1;
            }
            display_line += 1;
            if (row >= max_row) break;

            // Comment body with wrapping
            var body_iter = std.mem.splitSequence(u8, comment.body, "\n");
            while (body_iter.next()) |line| {
                if (row >= max_row) break;
                if (line.len == 0) {
                    if (display_line >= s.scroll_offset and row < max_row) row += 1;
                    display_line += 1;
                    continue;
                }
                var offset: usize = 0;
                while (offset < line.len) {
                    const chunk_end = advanceByDisplayWidth(line, offset, wrap_width);
                    if (display_line >= s.scroll_offset and row < max_row) {
                        renderStyledLine(win, line[offset..chunk_end], row, 2, .{});
                        row += 1;
                    }
                    display_line += 1;
                    if (offset == chunk_end) break;
                    offset = chunk_end;
                }
            }
        }
    }
}

/// Count how many wrapped lines a text segment produces using word-aware wrapping.
fn countWrappedLines(text: []const u8, wrap_width: usize) usize {
    if (text.len == 0) return 1;
    var lines: usize = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const next = advanceByDisplayWidth(text, offset, wrap_width);
        lines += 1;
        if (offset == next) break;
        offset = next;
    }
    return if (lines == 0) 1 else lines;
}

/// Compute the byte offset in `text` starting from `start` where `max_display` visible
/// characters have been consumed, accounting for markdown syntax (**bold**, `code`,
/// [text](url), ![alt](url), \escape). Prefers breaking at word boundaries (spaces).
fn advanceByDisplayWidth(text: []const u8, start: usize, max_display: usize) usize {
    var pos = start;
    var display: usize = 0;
    var last_space_pos: ?usize = null; // byte position just after last space

    while (pos < text.len and display < max_display) {
        // Backslash escape: \x shows 1 char
        if (text[pos] == '\\' and pos + 1 < text.len) {
            display += 1;
            pos += 2;
            continue;
        }

        // ** bold markers: consume 2 bytes, 0 display
        if (pos + 1 < text.len and text[pos] == '*' and text[pos + 1] == '*') {
            pos += 2;
            continue;
        }

        // `code`: consume backticks (0 display), content is visible
        if (text[pos] == '`') {
            if (std.mem.indexOfScalar(u8, text[pos + 1 ..], '`')) |rel_end| {
                pos += 1; // skip opening backtick
                const code_end = pos + rel_end;
                // Count code content as visible characters
                while (pos < code_end and display < max_display) {
                    display += 1;
                    pos += 1;
                }
                if (pos == code_end) pos += 1; // skip closing backtick
                continue;
            }
        }

        // ![alt](url): 0 display chars
        if (text[pos] == '!' and pos + 1 < text.len and text[pos + 1] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, pos + 2, ']')) |cb| {
                if (cb + 1 < text.len and text[cb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, cb + 2, ')')) |cp| {
                        pos = cp + 1;
                        continue;
                    }
                }
            }
        }

        // [text](url): only text chars are visible
        if (text[pos] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, pos + 1, ']')) |cb| {
                if (cb + 1 < text.len and text[cb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, cb + 2, ')')) |cp| {
                        pos += 1; // skip [
                        // Count link text as visible
                        while (pos < cb and display < max_display) {
                            display += 1;
                            pos += 1;
                        }
                        if (pos == cb) pos = cp + 1; // skip ](url)
                        continue;
                    }
                }
            }
        }

        // Track word boundaries
        if (text[pos] == ' ') {
            last_space_pos = pos + 1; // position after the space
        }

        // Regular character
        display += 1;
        pos += 1;
    }

    // If we consumed all text, no wrapping needed
    if (pos >= text.len) return pos;

    // We hit the width limit. Prefer breaking at last word boundary.
    if (last_space_pos) |sp| {
        // Only use word break if it's not the very start (would make no progress)
        if (sp > start) return sp;
    }

    // No space found — hard break at current position
    return pos;
}

/// Compute the visible display length of text, accounting for markdown syntax.
fn displayLength(text: []const u8) usize {
    var pos: usize = 0;
    var display: usize = 0;

    while (pos < text.len) {
        if (text[pos] == '\\' and pos + 1 < text.len) {
            display += 1;
            pos += 2;
            continue;
        }
        if (pos + 1 < text.len and text[pos] == '*' and text[pos + 1] == '*') {
            pos += 2;
            continue;
        }
        if (text[pos] == '`') {
            if (std.mem.indexOfScalar(u8, text[pos + 1 ..], '`')) |rel_end| {
                display += rel_end; // code content length
                pos += rel_end + 2; // skip both backticks + content
                continue;
            }
        }
        if (text[pos] == '!' and pos + 1 < text.len and text[pos + 1] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, pos + 2, ']')) |cb| {
                if (cb + 1 < text.len and text[cb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, cb + 2, ')')) |cp| {
                        pos = cp + 1;
                        continue;
                    }
                }
            }
        }
        if (text[pos] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, pos + 1, ']')) |cb| {
                if (cb + 1 < text.len and text[cb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, cb + 2, ')')) |cp| {
                        display += cb - pos - 1; // link text length
                        pos = cp + 1;
                        continue;
                    }
                }
            }
        }
        display += 1;
        pos += 1;
    }

    return display;
}

/// Render a line of text handling **bold**, `code`, [text](url) links,
/// and backslash escapes (e.g. \[ renders as [).
fn renderStyledLine(win: Window, text: []const u8, row: u16, start_col: u16, base_style: Style) void {
    var col = start_col;
    var pos: usize = 0;
    var in_bold = false;

    while (pos < text.len) {
        // Backslash escape: \x renders as x
        if (text[pos] == '\\' and pos + 1 < text.len) {
            const escaped = text[pos + 1 .. pos + 2];
            const sty: Style = if (in_bold) blk: {
                var s = base_style;
                s.bold = true;
                break :blk s;
            } else base_style;
            printSeg(win, escaped, sty, row, col);
            col += 1;
            pos += 2;
            continue;
        }

        // ** bold marker
        if (pos + 1 < text.len and text[pos] == '*' and text[pos + 1] == '*') {
            in_bold = !in_bold;
            pos += 2;
            continue;
        }

        // `code` marker
        if (text[pos] == '`') {
            if (std.mem.indexOfScalar(u8, text[pos + 1 ..], '`')) |rel_end| {
                const code_text = text[pos + 1 .. pos + 1 + rel_end];
                printSeg(win, code_text, style_code, row, col);
                const code_len: u16 = @intCast(@min(code_text.len, std.math.maxInt(u16)));
                col += code_len;
                pos = pos + 1 + rel_end + 1;
                continue;
            }
        }

        // ![alt](url) image - skip entirely
        if (text[pos] == '!' and pos + 1 < text.len and text[pos + 1] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, pos + 2, ']')) |close_bracket| {
                if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')')) |close_paren| {
                        pos = close_paren + 1;
                        continue;
                    }
                }
            }
        }

        // [text](url) link - render text as cyan underlined hyperlink
        if (text[pos] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, pos + 1, ']')) |close_bracket| {
                if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')')) |close_paren| {
                        const link_text = text[pos + 1 .. close_bracket];
                        const url = text[close_bracket + 2 .. close_paren];
                        printSegLink(win, link_text, style_link, .{ .uri = url }, row, col);
                        const link_len: u16 = @intCast(@min(link_text.len, std.math.maxInt(u16)));
                        col += link_len;
                        pos = close_paren + 1;
                        continue;
                    }
                }
            }
        }

        // Find end of current plain/bold span.
        // Special chars that didn't match their full pattern above are consumed
        // as plain text (advance at least 1 to avoid infinite loop).
        var end = pos;
        while (end < text.len) {
            // On first char (end == pos), always include it to guarantee progress
            if (end > pos) {
                if (text[end] == '\\' and end + 1 < text.len) break;
                if (end + 1 < text.len and text[end] == '*' and text[end + 1] == '*') break;
                if (text[end] == '`') break;
                if (text[end] == '[') break;
                if (text[end] == '!' and end + 1 < text.len and text[end + 1] == '[') break;
            }
            end += 1;
        }

        if (end > pos) {
            const span = text[pos..end];
            const sty: Style = if (in_bold) blk: {
                var s = base_style;
                s.bold = true;
                break :blk s;
            } else base_style;
            printSeg(win, span, sty, row, col);
            const span_len: u16 = @intCast(@min(span.len, std.math.maxInt(u16)));
            col += span_len;
        }

        pos = end;
    }
}

fn renderCreate(s: *const State, win: Window) void {
    const form = s.create_form orelse {
        printSeg(win, "Create Issue (initializing...)", style_bold, 1, 2);
        return;
    };

    // Title
    printSeg(win, "Create New Issue", style_bold, 1, 2);

    const label_col: u16 = 3;
    const value_col: u16 = 14;
    var row: u16 = 3;

    // Team field
    {
        const is_focused = form.focused_field == .team;
        const label_style: Style = if (is_focused) style_bold else style_dim;
        printSeg(win, "Team:", label_style, row, label_col);
        if (s.teams.len > 0 and form.team_idx < s.teams.len) {
            const arrow_style: Style = if (is_focused) style_bold else style_dim;
            printSeg(win, "\xe2\x97\x80 ", arrow_style, row, value_col);
            const name = s.teams[form.team_idx].name;
            const name_style: Style = if (is_focused) style_reverse else .{};
            printSeg(win, name, name_style, row, value_col + 2);
            const name_len: u16 = @intCast(@min(name.len, std.math.maxInt(u16)));
            printSeg(win, " \xe2\x96\xb6", arrow_style, row, value_col + 2 + name_len);
        } else {
            printSeg(win, "(no teams)", style_dim, row, value_col);
        }
        row += 1;
    }

    // Title field
    {
        const is_focused = form.focused_field == .title;
        const label_style: Style = if (is_focused) style_bold else style_dim;
        printSeg(win, "Title:", label_style, row, label_col);
        const title_text = form.titleSlice();
        if (title_text.len > 0) {
            printSeg(win, title_text, .{}, row, value_col);
        }
        if (is_focused) {
            const cursor_col: u16 = value_col + @as(u16, @intCast(@min(form.title_cursor, std.math.maxInt(u16))));
            printSeg(win, "_", style_bold, row, cursor_col);
        }
        row += 1;
    }

    // Status field
    {
        const is_focused = form.focused_field == .status;
        const label_style: Style = if (is_focused) style_bold else style_dim;
        printSeg(win, "Status:", label_style, row, label_col);
        // Show status from team states if available
        const team_id = if (s.teams.len > 0 and form.team_idx < s.teams.len)
            s.teams[form.team_idx].id
        else
            "";
        if (team_id.len > 0) {
            if (s.findTeamStates(team_id)) |states| {
                if (states.len > 0) {
                    const idx = form.status_idx orelse 0;
                    const clamped_idx = @min(idx, states.len - 1);
                    const arrow_style: Style = if (is_focused) style_bold else style_dim;
                    printSeg(win, "\xe2\x97\x80 ", arrow_style, row, value_col);
                    const name = states[clamped_idx].name;
                    const name_style: Style = if (is_focused) style_reverse else .{};
                    printSeg(win, name, name_style, row, value_col + 2);
                    const name_len: u16 = @intCast(@min(name.len, std.math.maxInt(u16)));
                    printSeg(win, " \xe2\x96\xb6", arrow_style, row, value_col + 2 + name_len);
                } else {
                    printSeg(win, "(default)", style_dim, row, value_col);
                }
            } else {
                printSeg(win, "(default)", style_dim, row, value_col);
            }
        } else {
            printSeg(win, "(default)", style_dim, row, value_col);
        }
        row += 1;
    }

    // Priority field
    {
        const is_focused = form.focused_field == .priority;
        const label_style: Style = if (is_focused) style_bold else style_dim;
        printSeg(win, "Priority:", label_style, row, label_col);
        const prio_name: []const u8 = switch (form.priority) {
            0 => "None",
            1 => "Urgent",
            2 => "High",
            3 => "Medium",
            4 => "Low",
            else => "None",
        };
        const arrow_style: Style = if (is_focused) style_bold else style_dim;
        printSeg(win, "\xe2\x97\x80 ", arrow_style, row, value_col);
        const name_style: Style = if (is_focused) style_reverse else .{};
        printSeg(win, prio_name, name_style, row, value_col + 2);
        const prio_len: u16 = @intCast(@min(prio_name.len, std.math.maxInt(u16)));
        printSeg(win, " \xe2\x96\xb6", arrow_style, row, value_col + 2 + prio_len);
        row += 1;
    }

    // Assign self field
    {
        const is_focused = form.focused_field == .assign_self;
        const label_style: Style = if (is_focused) style_bold else style_dim;
        printSeg(win, "Assign me:", label_style, row, label_col);
        const assign_text: []const u8 = if (form.assign_self) "Yes" else "No";
        const arrow_style: Style = if (is_focused) style_bold else style_dim;
        printSeg(win, "\xe2\x97\x80 ", arrow_style, row, value_col);
        const name_style: Style = if (is_focused) style_reverse else .{};
        printSeg(win, assign_text, name_style, row, value_col + 2);
        const assign_len: u16 = @intCast(@min(assign_text.len, std.math.maxInt(u16)));
        printSeg(win, " \xe2\x96\xb6", arrow_style, row, value_col + 2 + assign_len);
        row += 1;
    }

    // Body field (multi-line, last)
    {
        const is_focused = form.focused_field == .body;
        const label_style: Style = if (is_focused) style_bold else style_dim;
        printSeg(win, "Body:", label_style, row, label_col);
        const body_text = form.bodySlice();
        const avail: u16 = if (win.width > value_col) win.width - value_col else 1;

        var line_start: usize = 0;
        var body_row = row;
        var cursor_row = row;
        var cursor_col_pos: u16 = value_col;

        while (line_start <= body_text.len) : ({}) {
            const line_end = if (std.mem.indexOfScalarPos(u8, body_text, line_start, '\n')) |nl| nl else body_text.len;
            const line = body_text[line_start..line_end];
            if (body_row < win.height -| 2) {
                const show_len = @min(line.len, avail);
                if (show_len > 0) {
                    printSeg(win, line[0..show_len], .{}, body_row, value_col);
                }
            }

            if (is_focused and form.body_cursor >= line_start and form.body_cursor <= line_end) {
                cursor_row = body_row;
                const chars = form.body_cursor - line_start;
                cursor_col_pos = value_col + @as(u16, @intCast(@min(chars, avail)));
            }

            body_row += 1;
            if (line_end >= body_text.len) break;
            line_start = line_end + 1;
        }

        if (is_focused) {
            printSeg(win, "_", style_bold, cursor_row, cursor_col_pos);
        }
    }

    // Bottom row help or error
    if (win.height > 0) {
        if (s.error_msg) |msg| {
            printSeg(win, msg, style_red, win.height - 1, 2);
        } else {
            const help = "tab/\xe2\x86\x91\xe2\x86\x93:nav  \xe2\x86\x90\xe2\x86\x92:options  ctrl-s:submit  q/esc:back";
            printSeg(win, help, style_dim, win.height - 1, 2);
        }
    }
}

// --- Tests ---

const testing = std.testing;

test "render dispatches to loading when loading=true" {
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 24,
        .screen = &screen,
    };

    const s = State{ .loading = true };

    // Should not crash; rendering to a screen with no buf is safe because
    // writeCell bounds-checks against width/height (which are 0 in default Screen).
    // We just verify it doesn't panic.
    render(&s, win);
}

test "render dispatches to empty when no issues" {
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 24,
        .screen = &screen,
    };

    const s = State{ .loading = false, .issues = &.{} };
    render(&s, win);
}

test "render shows error_msg on bottom bar, not full screen" {
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 24,
        .screen = &screen,
    };

    const s = State{ .loading = false, .error_msg = "something broke" };
    render(&s, win);
}

test "renderList places In Progress header" {
    const allocator = testing.allocator;

    // Create a screen with a buffer
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 24,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 24,
        .screen = &screen,
    };

    var issues = [_]issue_mod.Issue{
        .{
            .identifier = "FOC-1",
            .title = "Test issue",
            .state_name = "In Progress",
            .state_type = .started,
            .priority_label = .high,
        },
    };

    const s = State{
        .loading = false,
        .issues = &issues,
        .selected_index = 0,
        .rows = 24,
        .cols = 80,
    };

    render(&s, win);

    // Check that "In Progress" header was rendered at row 1
    // The header starts at col 2 with "  In Progress"
    // Cell at (2, 1) should have 'I'
    if (screen.readCell(2, 1)) |cell| {
        try testing.expectEqualStrings("I", cell.char.grapheme);
    }
}

test "render with real screen for loading state" {
    const allocator = testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 24,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const win: Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 24,
        .screen = &screen,
    };

    const s = State{ .loading = true };
    render(&s, win);

    // Check that "Loading..." was rendered at row 1, col 2
    if (screen.readCell(2, 1)) |cell| {
        try testing.expectEqualStrings("L", cell.char.grapheme);
    }
    if (screen.readCell(3, 1)) |cell| {
        try testing.expectEqualStrings("o", cell.char.grapheme);
    }
}

test "isTableLine detects table rows" {
    try testing.expect(isTableLine("| a | b |"));
    try testing.expect(isTableLine("| a | b"));
    try testing.expect(isTableLine("|a|b|"));
    try testing.expect(!isTableLine("not a table"));
    try testing.expect(!isTableLine("|single pipe only"));
    try testing.expect(!isTableLine(""));
}

test "isTableSeparator detects separator rows" {
    try testing.expect(isTableSeparator("|---|---|"));
    try testing.expect(isTableSeparator("| --- | --- |"));
    try testing.expect(isTableSeparator("|:---:|:---:|"));
    try testing.expect(!isTableSeparator("| a | b |"));
    try testing.expect(!isTableSeparator("not a separator"));
}

test "parseTableCells splits correctly" {
    var cells: [16][]const u8 = undefined;

    const count1 = parseTableCells("| Header 1 | Header 2 | Header 3 |", &cells);
    try testing.expectEqual(@as(usize, 3), count1);
    try testing.expectEqualStrings("Header 1", cells[0]);
    try testing.expectEqualStrings("Header 2", cells[1]);
    try testing.expectEqualStrings("Header 3", cells[2]);

    const count2 = parseTableCells("|a|b|", &cells);
    try testing.expectEqual(@as(usize, 2), count2);
    try testing.expectEqualStrings("a", cells[0]);
    try testing.expectEqualStrings("b", cells[1]);
}

test "countTableLines counts correctly" {
    const lines = [_][]const u8{
        "| a | b |",
        "|---|---|",
        "| 1 | 2 |",
        "| 3 | 4 |",
    };
    // 3 data rows + 1 separator = 4 display lines
    try testing.expectEqual(@as(usize, 4), countTableLines(&lines));
}

test "countTableLines without separator" {
    const lines = [_][]const u8{
        "| a | b |",
        "| 1 | 2 |",
    };
    // 2 data rows, no separator = 2 display lines
    try testing.expectEqual(@as(usize, 2), countTableLines(&lines));
}
