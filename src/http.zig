const std = @import("std");
const http = std.http;

pub const HttpError = error{
    Unauthorized,
    RateLimited,
    ServerError,
    UnexpectedStatus,
};

fn checkStatus(status: http.Status) HttpError!void {
    const code: u10 = @intFromEnum(status);
    if (code >= 200 and code < 300) return;
    if (code == 401 or code == 403) return HttpError.Unauthorized;
    if (code == 429) return HttpError.RateLimited;
    if (code >= 500) return HttpError.ServerError;
    return HttpError.UnexpectedStatus;
}

pub fn postJson(allocator: std.mem.Allocator, url: []const u8, auth_header: []const u8, body: []const u8) ![]u8 {
    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var send_body = try req.sendBodyUnflushed(&.{});
    try send_body.writer.writeAll(body);
    try send_body.end();
    try req.connection.?.flush();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    try checkStatus(response.head.status);
    var transfer_buf: [8 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [1 << 16]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    return try reader.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024));
}

/// GET request with authorization header and optional extra headers. Returns allocated response body.
pub fn get(allocator: std.mem.Allocator, url: []const u8, auth_header: []const u8, extra_headers: ?[]const http.Header) ![]u8 {
    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // Build headers list: always include authorization, plus any extras
    var headers_buf: [16]http.Header = undefined;
    var header_count: usize = 0;
    headers_buf[header_count] = .{ .name = "authorization", .value = auth_header };
    header_count += 1;
    if (extra_headers) |extras| {
        for (extras) |h| {
            headers_buf[header_count] = h;
            header_count += 1;
        }
    }

    var req = try client.request(.GET, uri, .{
        .extra_headers = headers_buf[0..header_count],
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    try checkStatus(response.head.status);
    var transfer_buf2: [8 * 1024]u8 = undefined;
    var decompress2: std.http.Decompress = undefined;
    var decompress_buf2: [16 * 1024]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf2, &decompress2, &decompress_buf2);
    return try reader.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024));
}

pub fn patch(allocator: std.mem.Allocator, url: []const u8, auth_header: []const u8, body: []const u8) ![]u8 {
    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.PATCH, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var send_body = try req.sendBodyUnflushed(&.{});
    try send_body.writer.writeAll(body);
    try send_body.end();
    try req.connection.?.flush();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    try checkStatus(response.head.status);
    var transfer_buf3: [8 * 1024]u8 = undefined;
    var decompress3: std.http.Decompress = undefined;
    var decompress_buf3: [16 * 1024]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf3, &decompress3, &decompress_buf3);
    return try reader.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024));
}
