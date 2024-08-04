const std = @import("std");
const Route = @import("route.zig").Route;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const log = std.log.scoped(.router);

const RoutingTrie = @import("routing_trie.zig").RoutingTrie;

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: RoutingTrie,

    pub fn init(allocator: std.mem.Allocator) Router {
        const routes = RoutingTrie.init(allocator) catch unreachable;
        return Router{ .allocator = allocator, .routes = routes };
    }

    pub fn deinit(self: Router) void {
        self.routes.deinit();
    }

    pub fn serve_fs_dir(self: *Router, dir_path: []const u8) !void {
        _ = self;
        const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        @panic("TODO");
    }

    pub fn serve_embedded_file(self: *Router, path: []const u8, comptime mime: ?Mime, comptime bytes: []const u8) !void {
        const route = Route.init().get(struct {
            pub fn handler_fn(_: Request) Response {
                return Response.init(.OK, mime, bytes);
            }
        }.handler_fn);

        try self.serve_route(path, route);
    }

    pub fn serve_route(self: *Router, path: []const u8, route: Route) !void {
        try self.routes.add_route(path, route);
    }

    pub fn get_route_from_host(self: Router, host: []const u8) ?Route {
        return self.routes.get_route(host);
    }
};
