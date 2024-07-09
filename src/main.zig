const std = @import("std");
const builtin = @import("builtin");

// Init scoped logger.
const log = std.log.scoped(.main);

// Init our custom logger handler.
pub const std_options = .{
    .log_level = .debug,
    .logFn = logFn,
};

const block_hash_length = std.crypto.hash.sha2.Sha256.digest_length;
const nonce_length: usize = 256;

// We use it to wait in threads loops until os signal will be received.
// Note: in case of using two variables to wait for os signal: for example we are using separate bool variable and a mutex,
// so we need to wait for this bool variable changes in main function (thread) in the separate thread,
// otherwise deadlock, because mutex will be acquired in the same thread.
var wait_signal = std.atomic.Value(bool).init(true);

fn handle_signal(
    signal: i32,
    _: *const std.posix.siginfo_t,
    _: ?*anyopaque,
) callconv(.C) void {
    log.debug("os signal received: {d}", .{signal});
    wait_signal.store(false, std.builtin.AtomicOrder.monotonic);
}

const State = struct {
    blocks: std.ArrayList(Block),
};

const Block = struct {
    index: u128,
    hash: [block_hash_length]u8,
    prev_hash: [block_hash_length]u8,
    timestamp: i64,
    complexity: u8,
    nonce: [nonce_length]u8,
};

pub fn main() !void {
    switch (builtin.os.tag) {
        .macos => {},
        else => {
            log.err("at the moment software is not working on any system except macOS", .{});
            return;
        },
    }

    const allocator = std.heap.page_allocator;

    var rnd = std.rand.DefaultPrng.init(0);
    var state = State{ .blocks = std.ArrayList(Block).init(allocator) };
    // Init genesis block.
    try state.blocks.append(Block{
        .index = 0,
        .hash = [_]u8{0} ** block_hash_length,
        .prev_hash = [_]u8{0} ** block_hash_length,
        .timestamp = std.time.milliTimestamp(),
        .complexity = 0,
        .nonce = [_]u8{0} ** nonce_length,
    });

    const http_server_thread = try std.Thread.spawn(.{}, http_server, .{});
    const tcp_server_thread = try std.Thread.spawn(.{}, tcp_server, .{});
    const mining_loop_thread = try std.Thread.spawn(.{}, mining_loop, .{ @as(*std.rand.Xoshiro256, &rnd), @as(*State, &state) });
    const broadcast_loop_thread = try std.Thread.spawn(.{}, broadcast_loop, .{});

    var act = std.posix.Sigaction{
        .handler = .{ .sigaction = handle_signal },
        .mask = std.posix.empty_sigset,
        .flags = (std.posix.SA.SIGINFO),
    };
    var oact: std.posix.Sigaction = undefined;
    try std.posix.sigaction(std.posix.SIG.INT, &act, &oact);

    wait_signal_loop();

    // Waiting for other threads to be stopped.
    http_server_thread.join();
    tcp_server_thread.join();
    mining_loop_thread.join();
    broadcast_loop_thread.join();

    log.debug("current blocks length is {d} and last index is {d}", .{
        state.blocks.items.len,
        state.blocks.getLast().index,
    });
    std.debug.assert(state.blocks.items.len - 1 == state.blocks.getLast().index);

    log.info("final successfully exiting...", .{});
}

fn wait_signal_loop() void {
    log.info("starting to wait for os signal", .{});
    while (should_wait()) {}
    log.info("exiting os signal waiting loop", .{});
}

fn http_server() void {
    log.info("starting http server", .{});
    while (should_wait()) {}
    log.info("http server stopped", .{});
}

fn tcp_server() void {
    log.info("starting tcp server", .{});
    while (should_wait()) {}
    log.info("tcp server stopped", .{});
}

fn mining_loop(rnd: *std.rand.Xoshiro256, state: *State) !void {
    log.info("starting mining loop", .{});
    var nonce: [nonce_length]u8 = [_]u8{0} ** nonce_length;
    while (should_wait()) {
        std.time.sleep(1_000_000_000); // 1s
        fill_buf_random(rnd, &nonce);
        try state.blocks.append(Block{
            .index = state.blocks.getLast().index + 1,
            .hash = [_]u8{0} ** block_hash_length,
            .prev_hash = [_]u8{0} ** block_hash_length,
            .timestamp = std.time.milliTimestamp(),
            .complexity = 0,
            .nonce = nonce,
        });
    }
    log.info("mining loop stopped", .{});
}

fn broadcast_loop() void {
    log.info("starting broadcast loop", .{});
    while (should_wait()) {}
    log.info("broadcast loop stopped", .{});
}

fn should_wait() bool {
    const wait_signal_state = wait_signal.load(std.builtin.AtomicOrder.monotonic);
    if (wait_signal_state) {
        // To not overload cpu.
        std.time.sleep(5_000_000); // 5ms
    }
    return wait_signal_state;
}

fn fill_buf_random(rnd: *std.rand.Xoshiro256, nonce: *[nonce_length]u8) void {
    for (0..nonce_length) |i| {
        nonce[i] = rnd.random().int(u8);
    }
}

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Print the message to stderr, silently ignoring any errors.
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(
        "{d} " ++ "[" ++ comptime level.asText() ++ "] " ++ "(" ++ @tagName(scope) ++ ") " ++ format ++ "\n",
        .{std.time.milliTimestamp()} ++ args,
    ) catch return;
}
