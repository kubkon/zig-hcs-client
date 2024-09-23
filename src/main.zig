const std = @import("std");
const mem = std.mem;

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

    var buf: [1024 * 20]u8 = undefined;

    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const conn = try client.connect(address, port, .plain);

    while (true) {
        switch (last_cmd) {
            .help, .invalid => {},
            else => {
                const amt = try conn.read(&buf);
                try stdout.print("> {s}\n", .{buf[0..amt]});

                if (last_cmd == .exit) break;
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
                    try conn.writer().writeAll(mem.asBytes(&std.zig.Client.Message.Header{ .tag = tag, .bytes_len = 0 }));
                },
            }
        }
    }
}
