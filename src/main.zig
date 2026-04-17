const std = @import("std");
const builtin = @import("builtin");

// Allows formatted output to stdout.
var out: *std.Io.Writer = undefined;

// Provides logging configurable during the runtime (hence the default log level
// "debug") and also the scoped logging (lsd) in this file.
pub const std_options: std.Options = .{ .logFn = logFn, .log_level = .debug };
fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}
var log_level: std.log.Level = .warn;
const log = std.log.scoped(.lsd);

// Initializes the log level.
fn configureLog(allocator: std.mem.Allocator, environ: std.process.Environ) !void {
    // Set the log level from the environment variable LOG_LEVEL.
    if (try environ.containsUnempty(allocator, "LOG_LEVEL")) {
        const log_level_name = try environ.getAlloc(allocator, "LOG_LEVEL");
        defer allocator.free(log_level_name);
        if (log_level_name.len > 0) {
            log_level = std.meta.stringToEnum(std.log.Level, log_level_name) orelse {
                std.log.err("Invalid value of LOG_LEVEL: \"{s}\"", .{log_level_name});
                std.process.exit(1);
            };
        }
    }
}

// Parses the command line arguments and returns program configuration.
fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !struct { path: []const u8 } {
    var iterator = try args.iterateAllocator(allocator);
    defer iterator.deinit();
    // Skip the first argument, which is the executable and read a path
    // from the second argument, defaulting to the current directory.
    _ = iterator.next();
    const path = iterator.next() orelse ".";

    // Print usage instructions if -h or --help is provided instead of a path.
    if (std.mem.eql(u8, path, "-h") or std.mem.eql(u8, path, "--help")) {
        std.debug.print(
            \\Usage: {s} [options] [path]
            \\
            \\Options:
            \\  -h, --help  show this help message and exit
            \\
            \\The default path is the current directory.
        , .{"lsd"});
        std.process.exit(0);
    }

    return .{ .path = path };
}

// Represents a file by its name and size.
const File = struct {
    name: []const u8,
    size: u64,

    fn init(allocator: std.mem.Allocator, name: []const u8, size: u64) !File {
        const dupeName = try allocator.dupe(u8, name);
        return File{ .name = dupeName, .size = size };
    }

    fn deinit(self: File, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

// Deallocates memory used by an array of files including the file structures.
fn freeFiles(allocator: std.mem.Allocator, files: *std.ArrayList(File)) void {
    for (files.items) |file| file.deinit(allocator);
    files.deinit(allocator);
}

// Compares files at first by size and if the size is the same then by name.
fn lessFileBySizeAndName(_: void, left: File, right: File) bool {
    if (left.size != right.size) {
        return left.size < right.size;
    }
    return std.mem.order(u8, left.name, right.name) == .lt;
}

// Prints a file name and size on the same line.
fn printFile(file: File) !void {
    try out.print("{s: <64}\t{d}\n", .{ file.name, file.size });
    try out.flush();
}

// Lists all files in the specified directory.
fn listFiles(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(File) {
    // Open the specified directory to iterate over its contents.
    log.info("Listing directory: \"{s}\".", .{path});
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    // Initialize an array list to hold the files we find in the directory.
    var files = try std.ArrayList(File).initCapacity(allocator, 1024);
    errdefer freeFiles(allocator, &files);

    // Collect names and sizes of all files from the directory.
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == std.Io.File.Kind.file) {
            log.debug("Found file: \"{s}\"", .{entry.name});
            const stat = try dir.statFile(io, entry.name, .{});
            log.debug(" with size: {d}", .{stat.size});
            const file = try File.init(allocator, entry.name, stat.size);
            try files.append(allocator, file);
        }
    }
    log.info("Found {d} files.", .{files.items.len});
    return files;
}

// Prints groups of files with the same size.
fn printDuplicates(files: []File) !void {
    // Print file names and size of files, which have the same size.
    // If the current file has the same size as the previous one, print
    // the previous one and rememeber the current one. Next time, if there's
    // nothing to print, print the last remembered file.
    var lastFile: ?File = null;
    var sameFile: ?File = null;
    var dupes: u64 = 0;
    for (files) |file| {
        if (lastFile != null) {
            if (lastFile.?.size == file.size) {
                try printFile(lastFile.?);
                sameFile = file;
                dupes += 1;
            } else if (sameFile != null) {
                try printFile(sameFile.?);
                sameFile = null;
                dupes += 1;
            }
        }
        lastFile = file;
    }
    if (sameFile != null) {
        try printFile(sameFile.?);
        dupes += 1;
    }
    log.info("Found {d} duplicate files.\n", .{dupes});
}

pub fn main(init: std.process.Init) !void {
    // Use just one general allocator for simplicity.
    var debug_allocator = std.heap.DebugAllocator(.{ .verbose_log = true }){};
    const allocator, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        std.debug.assert(debug_allocator.deinit() == .ok);
    };

    // Configure the log level.
    try configureLog(allocator, init.minimal.environ);

    // Create a writer to the standard output.
    var out_buf: [1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(init.io, &out_buf);
    out = &out_writer.interface;

    // Parse the command line arguments and read program configuration.
    const args = try parseArgs(allocator, init.minimal.args);

    // List all files in the specified directory.
    var files = try listFiles(init.io, allocator, args.path);
    defer freeFiles(allocator, &files);

    // Sort the files by size and name.
    std.mem.sort(File, files.items, {}, lessFileBySizeAndName);

    try printDuplicates(files.items);
}
