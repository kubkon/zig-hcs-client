const assert = std.debug.assert;
const mem = std.mem;
const std = @import("std");

var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_allocator.allocator();

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    ret: {
        const msg = std.fmt.allocPrint(gpa, format, args) catch break :ret;
        std.io.getStdErr().writeAll(msg) catch {};
    }
    std.process.exit(1);
}

pub fn main() !void {
    const all_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, all_args);

    doMain(all_args[1..]) catch |err| fatal("unexpected error: {s}", .{@errorName(err)});
}

fn doMain(args: []const []const u8) !void {
    const ArgsIterator = struct {
        args: []const []const u8,
        i: usize = 0,
        fn next(it: *@This()) ?[]const u8 {
            if (it.i >= it.args.len) {
                return null;
            }
            defer it.i += 1;
            return it.args[it.i];
        }
    };

    var args_iter = ArgsIterator{ .args = args };
    var address: ?[]const u8 = null;
    var port: ?u16 = null;

    while (args_iter.next()) |arg| {
        if (mem.eql(u8, arg, "--address")) {
            address = args_iter.next() orelse fatal("expected IP address after {s}", .{arg});
        } else if (mem.eql(u8, arg, "--port")) {
            const port_str = args_iter.next() orelse fatal("expected port number after {s}", .{arg});
            port = try std.fmt.parseInt(u16, port_str, 0);
        } else {
            fatal("unexpected positional argument {s}", .{arg});
        }
    }

    try loop(address orelse "127.0.0.1", port orelse 12345);
}

pub fn loop(address: []const u8, port: u16) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    var repl_buf: [1024]u8 = undefined;

    const ReplCmd = enum {
        update,
        run,
        hot_update,
        help,
        exit,
        invalid,
    };

    var last_cmd: ReplCmd = .invalid;

    var client = std.http.Client{ .allocator = gpa };
    // TODO I think this should work however currently the remote (aka the compiler) simply call process.exit
    // on receiving `exit` message so we do not do any proper cleanup of resources causing this end to panic.
    // defer client.deinit();
    defer client.connection_pool.deinit(gpa);

    var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(gpa);
    defer fifo.deinit();

    const conn = try client.connect(address, port, .plain);

    while (true) {
        switch (last_cmd) {
            .help, .invalid => {},
            .exit => break,
            else => inner: while (true) {
                const hdr = try receiveMessage(conn, &fifo);
                defer fifo.discard(hdr.bytes_len);
                switch (hdr.tag) {
                    .zig_version => try stdout.print("> Zig version: {s}\n", .{fifo.readableSlice(0)}),
                    .error_bundle => {
                        const ErrorBundleHdr = std.zig.Server.Message.ErrorBundle;
                        const bundle_hdr_len = @sizeOf(ErrorBundleHdr);
                        if (fifo.readableLength() < bundle_hdr_len) return error.BrokenPipe;
                        const payload = fifo.readableSlice(0);
                        const bundle_hdr = std.mem.bytesAsValue(ErrorBundleHdr, payload[0..bundle_hdr_len]);
                        var extra_buf: std.ArrayListUnmanaged(u32) = .{};
                        defer extra_buf.deinit(gpa);
                        try extra_buf.appendUnalignedSlice(gpa, std.mem.bytesAsSlice(
                            u32,
                            payload[bundle_hdr_len..][0 .. bundle_hdr.extra_len * @sizeOf(u32)],
                        ));
                        const string_bytes = payload[bundle_hdr_len + bundle_hdr.extra_len * @sizeOf(u32) ..][0..bundle_hdr.string_bytes_len];
                        const bundle: std.zig.ErrorBundle = .{
                            .extra = extra_buf.items,
                            .string_bytes = string_bytes,
                        };
                        if (bundle.errorMessageCount() > 0) {
                            try stderr.writeAll("> ");
                            bundle.renderToStdErr(std.zig.Color.auto.renderOptions());
                        }
                        break :inner;
                    },
                    else => try stdout.print("> TODO: parse {s}\n", .{@tagName(hdr.tag)}),
                }
            },
        }

        try stdout.print("(hcs) ", .{});

        if (stdin.readUntilDelimiterOrEof(&repl_buf, '\n') catch |err| {
            try stderr.print("\nUnable to parse command: {s}\n", .{@errorName(err)});
            last_cmd = .invalid;
            continue;
        }) |line| {
            const actual_line = mem.trimRight(u8, line, "\r\n ");
            const cmd: ReplCmd = blk: {
                if (mem.eql(u8, actual_line, "update")) {
                    break :blk .update;
                } else if (mem.eql(u8, actual_line, "run")) {
                    break :blk .run;
                } else if (mem.eql(u8, actual_line, "hot_update")) {
                    break :blk .hot_update;
                } else if (mem.eql(u8, actual_line, "help")) {
                    break :blk .help;
                } else if (mem.eql(u8, actual_line, "exit")) {
                    break :blk .exit;
                } else if (actual_line.len == 0) {
                    break :blk last_cmd;
                } else {
                    try stderr.print("Unknown command: {s}\n", .{actual_line});
                    last_cmd = .invalid;
                    continue;
                }
            };
            last_cmd = cmd;
            switch (cmd) {
                .help => {
                    try stdout.writeAll("Supported commands: run, help, exit.\n");
                },
                .invalid => {},
                else => {
                    const tag: std.zig.Client.Message.Tag = switch (cmd) {
                        .update => .update,
                        .run => .run,
                        .hot_update => .hot_update,
                        .exit => .exit,
                        else => unreachable,
                    };
                    try conn.writer().writeAll(mem.asBytes(&std.zig.Client.Message.Header{
                        .tag = tag,
                        .bytes_len = 0,
                    }));
                    try conn.flush();
                },
            }
        }
    }
}

pub fn receiveMessage(conn: *std.http.Client.Connection, fifo: *std.fifo.LinearFifo(u8, .Dynamic)) !std.zig.Server.Message.Header {
    const Header = std.zig.Server.Message.Header;
    var last_amt_zero = false;

    while (true) {
        if (fifo.readableLength() != fifo.readableSlice(0).len) {
            // Account for the wrap around.
            // TODO is this needed on the user-side or is this a bug in std.fifo.LinearFifo?
            fifo.realign();
        }
        const buf = fifo.readableSlice(0);
        assert(fifo.readableLength() == buf.len);
        if (buf.len >= @sizeOf(Header)) {
            const header: *align(1) const Header = @ptrCast(buf[0..@sizeOf(Header)]);
            const bytes_len = header.bytes_len;
            const tag = header.tag;

            if (buf.len - @sizeOf(Header) >= bytes_len) {
                fifo.discard(@sizeOf(Header));
                return .{
                    .tag = tag,
                    .bytes_len = bytes_len,
                };
            } else {
                const needed = bytes_len - (buf.len - @sizeOf(Header));
                const write_buffer = try fifo.writableWithSize(needed);
                const amt = try conn.read(write_buffer);
                fifo.update(amt);
                continue;
            }
        }

        const write_buffer = try fifo.writableWithSize(256);
        const amt = try conn.read(write_buffer);
        fifo.update(amt);
        if (amt == 0) {
            if (last_amt_zero) return error.BrokenPipe;
            last_amt_zero = true;
        }
    }
}
