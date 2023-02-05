const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = mem.Allocator;
const Ast = std.zig.Ast;

const network = @import("network");
const Address = network.Address;
const EndPoint = network.EndPoint;
const IPv4 = Address.IPv4;
const IPv6 = Address.IPv6;

const Config = @This();

endpoint: EndPoint,
gateways: std.StringHashMapUnmanaged(EndPoint),

pub fn print(self: *Config) void {
    std.log.info("### CONFIGURATION ###", .{});
    std.log.info("* addr: {}", .{self.endpoint.address});
    std.log.info("* port: {}", .{self.endpoint.port});
    std.log.info("* gateways:", .{});

    var it = self.gateways.iterator();
    while (it.next()) |entry| {
        std.log.info("\t - {s} -> {}", .{ entry.key_ptr.*, entry.value_ptr });
    }

    std.log.info("### CONFIGURATION ###\n", .{});
}

pub fn deinit(self: *Config, allocator: Allocator) void {
    self.gateways.deinit(allocator);
}

pub fn load(allocator: Allocator, config_file: []const u8) !Config {
    const file = try fs.cwd().openFile(config_file, .{});
    defer file.close();

    var source: [1024 * 1024]u8 = undefined;
    const len = try file.readAll(&source);

    source[len] = 0;

    var tree = try std.zig.Ast.parse(allocator, source[0..len :0], .zon);
    defer tree.deinit(allocator);

    if (tree.errors.len != 0) return error.ParseError;

    return parse(allocator, tree);
}

pub fn parse(gpa: Allocator, ast: std.zig.Ast) !Config {
    const node_datas = ast.nodes.items(.data);
    const main_node_index = node_datas[0].lhs;

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_instance.deinit();

    var p: Parse = .{
        .gpa = gpa,
        .ast = ast,
        .arena = arena_instance.allocator(),

        .gateways = .{},
        .buf = .{},
    };
    defer p.buf.deinit(gpa);

    try p.parseRoot(main_node_index);

    return .{ .gateways = p.gateways, .endpoint = p.endpoint };
}

const Parse = struct {
    gpa: Allocator,
    ast: std.zig.Ast,
    arena: Allocator,
    buf: std.ArrayListUnmanaged(u8),

    endpoint: EndPoint = undefined,
    gateways: std.StringHashMapUnmanaged(EndPoint),

    fn parseRoot(p: *Parse, node: Ast.Node.Index) !void {
        const ast = p.ast;

        var buf: [2]Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse return error.ParseError;

        var port: ?u16 = null;
        var address: ?[]const u8 = null;

        for (struct_init.ast.fields) |field_init| {
            const name_token = ast.firstToken(field_init) - 2;
            const field_name = try identifierTokenString(p, name_token);
            if (mem.eql(u8, field_name, "gateways")) {
                try parseGateways(p, field_init);
            } else if (mem.eql(u8, field_name, "port")) {
                port = try parseInt(u16, p, field_init);
            } else if (mem.eql(u8, field_name, "address")) {
                address = try parseString(p, field_init);
            }
        }

        const endpoint_list = try network.getEndpointList(p.gpa, address.?, port.?);
        defer endpoint_list.deinit();

        p.endpoint = for (endpoint_list.endpoints) |endpt| break endpt else return error.InvalidEndpoint;
    }

    fn parseGateways(p: *Parse, node: Ast.Node.Index) !void {
        const ast = p.ast;

        var buf: [2]Ast.Node.Index = undefined;
        const array_init = ast.fullArrayInit(&buf, node) orelse return error.ParseError;

        for (array_init.ast.elements) |field_init| {
            try parseGateway(p, field_init);
        }
    }

    fn parseGateway(p: *Parse, node: Ast.Node.Index) !void {
        const ast = p.ast;

        var buf: [2]Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse return error.ParseError;

        var hostname: ?[]const u8 = null;
        var address: ?[]const u8 = null;
        var port: ?u16 = null;

        for (struct_init.ast.fields) |field_init| {
            const name_token = ast.firstToken(field_init) - 2;
            const field_name = try identifierTokenString(p, name_token);
            if (mem.eql(u8, field_name, "hostname")) {
                hostname = try parseString(p, field_init);
            } else if (mem.eql(u8, field_name, "address")) {
                address = try parseString(p, field_init);
            } else if (mem.eql(u8, field_name, "port")) {
                port = try parseInt(u16, p, field_init);
            }
        }

        const endpoint_list = try network.getEndpointList(p.gpa, address.?, port.?);
        defer endpoint_list.deinit();

        const endpoint = for (endpoint_list.endpoints) |endpt| break endpt else return error.InvalidGateway;

        try p.gateways.put(p.gpa, hostname.?, endpoint);
    }

    fn parseString(p: *Parse, node: Ast.Node.Index) ![]const u8 {
        const ast = p.ast;
        const node_tags = ast.nodes.items(.tag);
        const main_tokens = ast.nodes.items(.main_token);
        if (node_tags[node] != .string_literal) return error.ParseError;
        const str_lit_token = main_tokens[node];
        const token_bytes = ast.tokenSlice(str_lit_token);
        p.buf.clearRetainingCapacity();
        try parseStrLit(p, &p.buf, token_bytes, 0);
        const duped = try p.arena.dupe(u8, p.buf.items);
        return duped;
    }

    fn parseInt(comptime T: type, p: *Parse, node: Ast.Node.Index) !T {
        const ast = p.ast;
        const node_tags = ast.nodes.items(.tag);
        const main_tokens = ast.nodes.items(.main_token);
        if (node_tags[node] != .number_literal) return error.ParseError;
        const num_lit_token = main_tokens[node];
        const token_bytes = ast.tokenSlice(num_lit_token);
        p.buf.clearRetainingCapacity();
        return try std.fmt.parseInt(T, token_bytes, 0);
    }

    /// TODO: try to DRY this with AstGen.identifierTokenString
    fn identifierTokenString(
        p: *Parse,
        token: Ast.TokenIndex,
    ) ![]const u8 {
        const ast = p.ast;
        const ident_name = ast.tokenSlice(token);
        if (!mem.startsWith(u8, ident_name, "@")) {
            return ident_name;
        }
        p.buf.clearRetainingCapacity();
        try parseStrLit(p, &p.buf, ident_name, 1);
        const duped = try p.arena.dupe(u8, p.buf.items);
        return duped;
    }

    /// TODO: try to DRY this with AstGen.parseStrLit
    fn parseStrLit(
        p: *Parse,
        buf: *std.ArrayListUnmanaged(u8),
        bytes: []const u8,
        offset: u32,
    ) !void {
        const raw_string = bytes[offset..];
        var buf_managed = buf.toManaged(p.gpa);
        _ = try std.zig.string_literal.parseWrite(buf_managed.writer(), raw_string);
        buf.* = buf_managed.moveToUnmanaged();
    }
};
