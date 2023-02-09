// $$$$$$$$\ $$\      $$\  $$$$$$\
// \____$$ | $$$\    $$$ |$$  __$$\
//     $$  / $$$$\  $$$$ |$$ /  \__|
//    $$  /  $$\$$\$$ $$ |$$ |
//   $$  /   $$ \$$$  $$ |$$ |
//  $$  /    $$ |\$  /$$ |$$ |  $$\
// $$$$$$$$\ $$ | \_/ $$ |\$$$$$$  |
// \________|\__|     \__| \______/
//
// Simple Minecraft Reverse Proxy written in ZIG

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const process = std.process;

const Allocator = mem.Allocator;

const Config = @import("Config.zig");

// https://github.com/MasterQ32/zig-network
const network = @import("network");
const AddressFamily = network.AddressFamily;
const Socket = network.Socket;
const SocketSet = network.SocketSet;

// The buffer size in bytes
const buffer_size = 1024 * 10;

const version = "0.0.1";

const ClientList = std.TailQueue(void);

pub const Client = struct {
    node: ClientList.Node = .{ .data = {} },

    // The client socket
    socket: Socket,
    // The gateway server
    gateway: Socket = undefined,

    // If the client already handshaked
    handshaked: bool = false,
};

pub fn main() !void {
    std.debug.print(
        \\ $$$$$$$$\ $$\      $$\  $$$$$$\
        \\ \____$$ | $$$\    $$$ |$$  __$$\
        \\     $$  / $$$$\  $$$$ |$$ /  \__|
        \\    $$  /  $$\$$\$$ $$ |$$ |
        \\   $$  /   $$ \$$$  $$ |$$ |
        \\  $$  /    $$ |\$  /$$ |$$ |  $$\
        \\ $$$$$$$$\ $$ | \_/ $$ |\$$$$$$  |
        \\ \________|\__|     \__| \______/
        \\
    , .{});

    std.log.info("Running ZMC version " ++ version ++ "\n", .{});

    // Initialize an allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try process.argsWithAllocator(allocator);
    _ = arg_it.skip();

    const config_file = arg_it.next() orelse "config.zon";

    std.log.info("Loading configuration from {s}\n", .{config_file});

    // Load the config from config.zon
    var config = try Config.load(allocator, config_file);
    defer config.deinit(allocator);

    // Print the configuration
    config.print();

    // Initialize the I/O logic
    var clients = ClientList{};
    try network.init();
    defer network.deinit();
    var server = try network.Socket.create(@as(AddressFamily, config.endpoint.address), .tcp);
    defer server.close();
    var socket_set = try network.SocketSet.init(allocator);
    defer socket_set.deinit();

    // Look for a non reserved port
    while (true) : (config.endpoint.port += 1) {
        server.bind(config.endpoint) catch {
            std.log.warn("Port {} not available! Trying another one.", .{config.endpoint.port});
            continue;
        };

        break;
    }

    std.log.info("Listening on {}\n", .{
        config.endpoint,
    });

    try server.listen();

    try socket_set.add(server, .{
        .read = true,
        .write = false,
    });

    while (true) {
        var n = try network.waitForSocketEvent(&socket_set, null);

        // Accept incoming connections
        if (socket_set.isReadyRead(server)) {
            const socket = try server.accept();

            try socket_set.add(socket, .{
                .read = true,
                .write = false,
            });

            const client = try allocator.create(Client);
            client.socket = socket;

            clients.append(&client.node);

            std.log.info("[+] Client {} from {}", .{
                client.socket.internal,
                try client.socket.getLocalEndPoint(),
            });

            n -= 1;
        }

        if (n == 0) continue;

        var it = clients.first;
        while (it) |node| {
            it = node.next;

            const client = @fieldParentPtr(Client, "node", node);

            processEvents(
                config,
                client,
                &socket_set,
                &n,
            ) catch |e| {
                switch (e) {
                    error.Close => {
                        std.log.info("[-] Client {}", .{
                            client.socket.internal,
                        });
                    },
                    else => std.log.info("[-] Client {}: {}", .{
                        client.socket.internal,
                        e,
                    }),
                }

                clients.remove(node);

                socket_set.remove(client.socket);
                client.socket.close();

                if (client.handshaked) {
                    socket_set.remove(client.gateway);
                    client.gateway.close();
                }

                allocator.destroy(client);
            };

            if (n == 0) break;
        }
    }
}

/// Handle I/O events
fn processEvents(
    config: Config,
    client: *Client,
    socket_set: *network.SocketSet,
    n: *usize,
) !void {
    if (client.handshaked) {
        if (socket_set.isReadyRead(client.socket)) {
            try pipe(client.socket, client.gateway);

            n.* -= 1;
        }
        if (socket_set.isReadyRead(client.gateway)) {
            try pipe(client.gateway, client.socket);

            n.* -= 1;
        }
    } else {
        if (socket_set.isReadyRead(client.socket)) {
            try handshake(config, client, socket_set);

            n.* -= 1;
        }
    }
}

/// Read from 'src' and write the buffer to 'dest'
fn pipe(src: Socket, dest: Socket) !void {
    var buffer: [buffer_size]u8 = undefined;
    const len = try src.receive(&buffer);
    if (len == 0) return error.Close;

    _ = try dest.send(buffer[0..len]);
}

/// Connect to gateway
fn gatewayConnect(
    config: Config,
    hostname: []const u8,
) !network.Socket {
    const gateway = config.gateways.get(hostname) orelse
        (config.fallback orelse return error.GatewayNotFound);

    std.log.debug("Connecting to gateway {}", .{gateway});

    var socket = try Socket.create(@as(AddressFamily, gateway.address), .tcp);

    socket.connect(gateway) catch {
        socket.close();
        return error.GatewayUnreachable;
    };

    return socket;
}

/// Handle first packet
fn handshake(
    config: Config,
    client: *Client,
    socket_set: *SocketSet,
) !void {
    var buffer: [buffer_size]u8 = undefined;
    const len = try client.socket.receive(&buffer);
    if (len == 0) return error.Close;

    const slice = buffer[0..len];

    var offset: usize = 0;

    // Discard packet length
    _ = try readVarInt(slice, &offset);

    // Capture the packet id
    const packet_id = slice[offset];
    offset += 1;

    // The first packet should always be 0x0
    if (packet_id != 0x0) return error.Close;

    // Discard version
    _ = try readVarInt(slice, &offset);

    // Capture the hostname
    const hostname_l = @intCast(usize, try readVarInt(slice, &offset));
    const hostname = slice[offset .. offset + hostname_l];

    std.log.debug("Client {} -> {s}", .{ client.socket.internal, hostname });

    client.gateway = try gatewayConnect(config, hostname);

    try socket_set.add(client.gateway, .{
        .read = true,
        .write = false,
    });

    _ = try client.gateway.send(buffer[0..len]);

    client.handshaked = true;
}

/// Parse a varint
inline fn readVarInt(buf: []const u8, offset: *usize) !i32 {
    const SEGMENT_BITS = 0x7F;
    const CONTINUE_BIT = 0x80;

    var value: i32 = 0;

    var i: u3 = 0;
    return while (i < 5) : (i += 1) {
        var currentByte: u8 = buf[offset.*];
        offset.* += 1;

        value |= (currentByte & SEGMENT_BITS) << i * 7;

        if ((currentByte & CONTINUE_BIT) == 0)
            break value;
    } else error.TOO_BIG;
}
