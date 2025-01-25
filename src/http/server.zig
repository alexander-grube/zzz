const std = @import("std");
const builtin = @import("builtin");
const tag = builtin.os.tag;
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/server");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const TLSFileOptions = @import("../tls/lib.zig").TLSFileOptions;
const TLSContext = @import("../tls/lib.zig").TLSContext;
const TLS = @import("../tls/lib.zig").TLS;

const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Capture = @import("router/routing_trie.zig").Capture;
const QueryMap = @import("router/routing_trie.zig").QueryMap;
const SSE = @import("sse.zig").SSE;

const Provision = @import("provision.zig").Provision;
const Mime = @import("mime.zig").Mime;
const Router = @import("router.zig").Router;
const Route = @import("router/route.zig").Route;
const Layer = @import("router/middleware.zig").Layer;
const Middleware = @import("router/middleware.zig").Middleware;
const HTTPError = @import("lib.zig").HTTPError;

const HandlerWithData = @import("router/route.zig").HandlerWithData;

const Next = @import("router/middleware.zig").Next;

pub const Runtime = @import("tardy").Runtime;
pub const Task = @import("tardy").Task;
pub const AsyncIOType = @import("tardy").AsyncIOType;
const TardyCreator = @import("tardy").Tardy;

const Cross = @import("tardy").Cross;
const Pool = @import("tardy").Pool;
const PoolKind = @import("tardy").PoolKind;
const Socket = @import("tardy").Socket;
const ZeroCopy = @import("tardy").ZeroCopy;

const AcceptResult = @import("tardy").AcceptResult;
const RecvResult = @import("tardy").RecvResult;
const SendResult = @import("tardy").SendResult;

/// Security Model to use.
///
/// Default: .plain (plaintext)
pub const Security = union(enum) {
    plain,
    tls: struct {
        cert: TLSFileOptions,
        key: TLSFileOptions,
        cert_name: []const u8 = "CERTIFICATE",
        key_name: []const u8 = "PRIVATE KEY",
    },
};

/// These are various general configuration
/// options that are important for the actual framework.
///
/// This includes various different options and limits
/// for interacting with the underlying network.
pub const ServerConfig = struct {
    security: Security = .plain,
    /// Kernel Backlog Value.
    backlog_count: u31 = 512,
    /// Stack Size
    ///
    /// If you have a large number of middlewares or
    /// create a LOT of stack memory, you may want to increase this.
    ///
    /// P.S: A lot of functions in the standard library do end up allocating
    /// a lot on the stack (such as std.log).
    ///
    /// Default: 1MB
    stack_size: usize = 1024 * 1024,
    /// Number of Maximum Concurrent Connections.
    ///
    /// This is applied PER runtime.
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You can set this to `null` to have no maximum.
    ///
    /// Default: 1024
    connection_count_max: ?usize = 1024,
    /// Amount of allocated memory retained
    /// after an arena is cleared.
    ///
    /// A higher value will increase memory usage but
    /// should make allocators faster.
    ///
    /// A lower value will reduce memory usage but
    /// will make allocators slower.
    ///
    /// Default: 1KB
    connection_arena_bytes_retain: u32 = 1024,
    /// Amount of space on the `recv_buffer` retained
    /// after every send.
    ///
    /// Default: 1KB
    list_recv_bytes_retain: u32 = 1024,
    /// Maximum size (in bytes) of the Recv buffer.
    /// This is mainly a concern when you are reading in
    /// large requests before responding.
    ///
    /// Default: 2MB.
    list_recv_bytes_max: u32 = 1024 * 1024 * 2,
    /// Size of the buffer (in bytes) used for
    /// interacting with the socket.
    ///
    /// Default: 1 KB.
    socket_buffer_bytes: u32 = 1024,
    /// Maximum number of Headers in a Request/Response
    ///
    /// Default: 32
    header_count_max: u16 = 32,
    /// Maximum number of Captures in a Route
    ///
    /// Default: 8
    capture_count_max: u16 = 8,
    /// Maximum number of Queries in a URL
    ///
    /// Default: 8
    query_count_max: u16 = 8,
    /// Maximum size (in bytes) of the Request.
    ///
    /// Default: 2MB.
    request_bytes_max: u32 = 1024 * 1024 * 2,
    /// Maximum size (in bytes) of the Request URI.
    ///
    /// Default: 2KB.
    request_uri_bytes_max: u32 = 1024 * 2,
};

pub const Server = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    config: ServerConfig,
    tls_ctx: ?TLSContext,
    router: *const Router,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Self {
        const tls_ctx = switch (config.security) {
            .tls => |inner| TLSContext.init(allocator, .{
                .cert = inner.cert,
                .cert_name = inner.cert_name,
                .key = inner.key,
                .key_name = inner.key_name,
                .size_tls_buffer_max = config.socket_buffer_bytes * 2,
            }) catch unreachable,
            .plain => null,
        };

        return Self{
            .allocator = allocator,
            .config = config,
            .tls_ctx = tls_ctx,
            .router = undefined,
        };
    }

    pub fn deinit(self: *const Self) void {
        if (self.tls_ctx) |tls| {
            tls.deinit();
        }
    }

    const RequestBodyState = struct {
        content_length: usize,
        current_length: usize,
    };

    const RequestState = union(enum) {
        header,
        body: RequestBodyState,
    };

    const State = union(enum) {
        request: RequestState,
        handler,
        respond,
    };

    pub fn main_frame(
        rt: *Runtime,
        config: ServerConfig,
        router: *const Router,
        server: *const Socket,
        provisions: *Pool(Provision),
    ) !void {
        const socket = try server.accept(rt);
        defer socket.close_blocking();
        try Cross.socket.disable_nagle(socket.handle);

        log.debug("queuing up a new accept request", .{});
        try rt.spawn(.{ rt, config, router, server, provisions }, main_frame, config.stack_size);

        const index = try provisions.borrow();
        defer provisions.release(index);
        const provision = provisions.get_ptr(index);

        if (config.connection_count_max) |connection_max_count| {
            _ = connection_max_count;
            // TODO: reintroduce maximum connections limit
            // make it a ?usize so you're not forced :)
            // dont queue a new accept unless we are under the limit basically.
        }

        // if we are growing, we can handle a newly allocated provision here.
        // otherwise, it should be initalized.
        if (!provision.initalized) {
            log.debug("initalizing new provision", .{});
            provision.recv_buffer = ZeroCopy(u8).init(rt.allocator, config.socket_buffer_bytes) catch {
                @panic("attempting to allocate more memory than available. (ZeroCopyBuffer)");
            };
            provision.arena = std.heap.ArenaAllocator.init(rt.allocator);
            provision.captures = rt.allocator.alloc(Capture, config.capture_count_max) catch {
                @panic("attempting to allocate more memory than available. (Captures)");
            };
            provision.queries = QueryMap.init(rt.allocator, config.query_count_max) catch {
                @panic("attempting to allocate more memory than available. (QueryMap)");
            };
            provision.request = Request.init(rt.allocator, config.header_count_max) catch {
                @panic("attempting to allocate more memory than available. (Request)");
            };
            provision.response = Response.init(rt.allocator, config.header_count_max) catch {
                @panic("attempting to allocate more memory than available. (Response)");
            };

            provision.initalized = true;
        }

        defer if (provision.recv_buffer.len > config.list_recv_bytes_retain)
            provision.recv_buffer.shrink_clear_and_free(config.list_recv_bytes_retain) catch unreachable
        else
            provision.recv_buffer.clear_retaining_capacity();
        defer _ = provision.arena.reset(.{ .retain_with_limit = config.connection_arena_bytes_retain });
        defer provision.queries.clear();
        defer provision.request.clear();
        defer provision.response.clear();

        var state: State = .{ .request = .header };
        provision.buffer = try provision.recv_buffer.get_write_area(config.socket_buffer_bytes);

        // TODO: add a limit to how many times a socket can run a keep-alive
        while (true) switch (state) {
            .request => |*kind| switch (kind.*) {
                .header => {
                    const recv_count = socket.recv(rt, provision.buffer) catch |e| switch (e) {
                        error.Closed => break,
                        else => {
                            log.debug("recv failed on socket | {}", .{e});
                            break;
                        },
                    };

                    provision.recv_buffer.mark_written(recv_count);
                    provision.buffer = try provision.recv_buffer.get_write_area(config.socket_buffer_bytes);
                    if (provision.recv_buffer.len > config.request_bytes_max) break;
                    const search_area_start = (provision.recv_buffer.len - recv_count) -| 4;

                    if (std.mem.indexOf(
                        u8,
                        // Minimize the search area.
                        provision.recv_buffer.subslice(.{ .start = search_area_start }),
                        "\r\n\r\n",
                    )) |header_end| {
                        const real_header_end = header_end + 4;
                        try provision.request.parse_headers(
                            // Add 4 to account for the actual header end sequence.
                            provision.recv_buffer.subslice(.{ .end = real_header_end }),
                            .{
                                .request_bytes_max = config.request_bytes_max,
                                .request_uri_bytes_max = config.request_uri_bytes_max,
                            },
                        );

                        log.info("rt{d} - \"{s} {s}\" {s} ({})", .{
                            rt.id,
                            @tagName(provision.request.method.?),
                            provision.request.uri.?,
                            provision.request.headers.get("User-Agent") orelse "N/A",
                            socket.addr,
                        });

                        const content_length_str = provision.request.headers.get("Content-Length") orelse "0";
                        const content_length = try std.fmt.parseUnsigned(usize, content_length_str, 10);
                        log.debug("content length={d}", .{content_length});

                        if (provision.request.expect_body() and content_length != 0) {
                            state = .{
                                .request = .{
                                    .body = .{
                                        .current_length = provision.recv_buffer.len - real_header_end,
                                        .content_length = content_length,
                                    },
                                },
                            };
                        } else state = .handler;
                    }
                },
                .body => |*info| {
                    if (info.current_length == info.content_length) {
                        state = .handler;
                        continue;
                    }

                    const recv_count = socket.recv(rt, provision.buffer) catch |e| switch (e) {
                        error.Closed => break,
                        else => {
                            log.debug("recv failed on socket | {}", .{e});
                            break;
                        },
                    };

                    provision.recv_buffer.mark_written(recv_count);
                    provision.buffer = try provision.recv_buffer.get_write_area(config.socket_buffer_bytes);
                    if (provision.recv_buffer.len > config.request_bytes_max) break;

                    info.current_length += recv_count;
                    assert(info.current_length <= info.content_length);
                },
            },
            .handler => {
                const found = try router.get_bundle_from_host(
                    provision.request.uri.?,
                    provision.captures,
                    &provision.queries,
                );

                const h_with_data: HandlerWithData = found.bundle.route.get_handler(
                    provision.request.method.?,
                ) orelse {
                    try provision.response.apply(.{
                        .status = .@"Method Not Allowed",
                        .mime = Mime.TEXT,
                        .body = "",
                    });

                    state = .respond;
                    continue;
                };

                const context: Context = .{
                    .runtime = rt,
                    .allocator = provision.arena.allocator(),
                    .request = &provision.request,
                    .address = socket.addr,
                };

                var next: Next = .{
                    .context = context,
                    .middlewares = found.bundle.middlewares,
                    .handler = h_with_data,
                };

                const respond = try next.run();
                try provision.response.apply(respond);
                state = .respond;
            },
            .respond => {
                // we will just use the recv buffer zero copy as an impromptu buffer :)
                const buffer = try provision.recv_buffer.get_write_area(config.socket_buffer_bytes);

                const body = provision.response.body orelse "";
                const content_length = body.len;
                const headers = try provision.response.headers_into_buffer(buffer, content_length);

                var sent: usize = 0;
                const pseudo = Pseudoslice.init(headers, body, buffer);

                while (sent < pseudo.len) {
                    const send_slice = pseudo.get(sent, buffer.len);
                    const sent_length = socket.send_all(rt, send_slice) catch |e| {
                        log.debug("send failed on socket | {}", .{e});
                        break;
                    };
                    if (sent_length != send_slice.len) break;
                    sent += sent_length;
                }

                // keep-alive vs close
                const connection = provision.request.headers.get("Connection") orelse "keep-alive";
                // will be cleaned by defer.
                if (std.mem.eql(u8, connection, "close")) break;

                // if keep-alive
                provision.request.clear();
                provision.response.clear();
                provision.recv_buffer.clear_retaining_capacity();
                _ = provision.arena.reset(.retain_capacity);
                state = .{ .request = .header };
                provision.buffer = try provision.recv_buffer.get_write_area(config.socket_buffer_bytes);
            },
        };

        log.info("connection ({}) closed", .{socket.addr});
    }

    /// Serve an HTTP server.
    pub fn serve(self: *Self, rt: *Runtime, router: *const Router, socket: *const Socket) !void {
        self.router = router;
        log.info("security mode: {s}", .{@tagName(self.config.security)});

        const count = self.config.connection_count_max orelse 1024;
        const pooling: PoolKind = if (self.config.connection_count_max == null) .grow else .static;

        const provision_pool = try rt.allocator.create(Pool(Provision));
        provision_pool.* = try Pool(Provision).init(rt.allocator, count, pooling);

        // initialize first batch of provisions :)
        for (provision_pool.items) |*provision| {
            provision.initalized = true;
            provision.recv_buffer = ZeroCopy(u8).init(rt.allocator, self.config.socket_buffer_bytes) catch {
                @panic("attempting to allocate more memory than available. (ZeroCopy)");
            };
            provision.arena = std.heap.ArenaAllocator.init(rt.allocator);
            provision.captures = rt.allocator.alloc(Capture, self.config.capture_count_max) catch {
                @panic("attempting to allocate more memory than available. (Captures)");
            };
            provision.queries = QueryMap.init(rt.allocator, self.config.query_count_max) catch {
                @panic("attempting to allocate more memory than available. (QueryMap)");
            };
            provision.request = Request.init(rt.allocator, self.config.header_count_max) catch {
                @panic("attempting to allocate more memory than available. (Request)");
            };
            provision.response = Response.init(rt.allocator, self.config.header_count_max) catch {
                @panic("attempting to allocate more memory than available. (Response)");
            };
        }

        try rt.spawn(.{ rt, self.config, router, socket, provision_pool }, main_frame, self.config.stack_size);
    }
};
