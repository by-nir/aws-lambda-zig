//! https://docs.aws.amazon.com/lambda/latest/dg/configuration-metadata-endpoint.html

const std = @import("std");
const HttpClient = @import("../utils/Http.zig");

pub const RuntimeMetadata = struct {
    availability_zone_id: []const u8 = "",
};

pub fn getRuntimeMetadata(
    arena: std.mem.Allocator,
    client: *HttpClient,
    env: *const std.process.Environ.Map,
) !RuntimeMetadata {
    const endpoint = env.get("AWS_LAMBDA_METADATA_API") orelse
        return error.MissingMetadataEndpoint;
    const token = env.get("AWS_LAMBDA_METADATA_TOKEN") orelse
        return error.MissingMetadataToken;

    const uri: std.Uri = try .parse(try std.fmt.allocPrint(
        arena,
        "http://{s}/2026-01-15/metadata/execution-environment",
        .{endpoint},
    ));
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});

    const req = try client.sendUri(arena, uri, null, .{
        .request = .{ .authorization = .{ .override = auth } },
    });

    const body = try std.json.parseFromSliceLeaky(struct {
        AvailabilityZoneID: []const u8,
    }, arena, req.body, .{});

    return .{
        .availability_zone_id = body.AvailabilityZoneID,
    };
}
