const std = @import("std");
const builtin = @import("builtin");

// Allows formatted output to stdout.
const out = std.fs.File.stdout().deprecatedWriter();

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
fn initLog(allocator: std.mem.Allocator) !void {
    // Set the log level from the environment variable LOG_LEVEL.
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    const log_level_name = env.get("LOG_LEVEL") orelse "";
    if (log_level_name.len > 0) {
        log_level = std.meta.stringToEnum(std.log.Level, log_level_name) orelse {
            std.log.err("Invalid value of LOG_LEVEL: \"{s}\"", .{log_level_name});
            std.process.exit(1);
        };
    }
}

// Parses the command line arguments and returns program configuration.
fn parseArgs() struct { path: []const u8 } {
    // Skip the first argument, which is the executable and read a path
    // from the second argument, defaulting to the current directory.
    var args = std.process.args();
    _ = args.next();
    const path = args.next() orelse ".";

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
    return std.mem.order(u8, left.name[0..], right.name[0..]) == .lt;
}

// Prints a file name and size on the same line.
fn printFile(file: File) !void {
    try out.print("{s: <64}\t{d}\n", .{ file.name, file.size });
}

// Lists all files in the specified directory.
fn listFiles(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(File) {
    // Open the specified directory to iterate over its contents.
    log.info("Listing directory: \"{s}\".", .{path});
    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(path, .{ .iterate = true });
    defer dir.close();

    // Initialize an array list to hold the files we find in the directory.
    var files = try std.ArrayList(File).initCapacity(allocator, 1024);
    errdefer freeFiles(allocator, &files);

    // Collect names and sizes of all files from the directory.
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == std.fs.File.Kind.file) {
            log.debug("Found file: \"{s}\"", .{entry.name});
            const stat = try dir.statFile(entry.name);
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

pub fn main() !void {
    // Use just one general allocator for simplicity.
    const log_alloc = builtin.mode == .Debug;
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = log_alloc }){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Initialize the log level.
    try initLog(allocator);

    // Parse the command line arguments and read program configuration.
    const args = parseArgs();

    // List all files in the specified directory.
    var files = try listFiles(allocator, args.path);
    defer freeFiles(allocator, &files);

    // Sort the files by size and name.
    std.mem.sort(File, files.items, {}, lessFileBySizeAndName);

    try printDuplicates(files.items);
}
