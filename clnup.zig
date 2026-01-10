const std = @import("std");

const Action = enum {
    Delete,
    Print,
};

const ActionState = struct {
    recursive: bool,
    quiet: bool,
    verbose: bool,
    dry_run: bool,
    clnup_path: []const u8,
    root: []const u8,
};

const ActionResult = enum {
    Keep,
    Delete,
};

const Rule = struct {
    pattern: []const u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,
};

const HandlerFn = *const fn (
    path: []const u8,
    is_dir: bool,
    allocator: std.mem.Allocator,
    quiet: bool,
    verbose: bool,
) anyerror!void;

// ------------------------------------------------------------
// Entry point
// ------------------------------------------------------------
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = try parseArgs(allocator);
    defer {
        if (!std.mem.eql(u8, state.clnup_path, ".clnup"))
            allocator.free(state.clnup_path);
        if (!std.mem.eql(u8, state.root, "."))
            allocator.free(state.root);
    }

    if (state.verbose) {
        std.debug.print("Using rules from: {s}\n", .{state.clnup_path});
        std.debug.print("Target path: {s}\n", .{state.root});
        std.debug.print("Action: {s}\n", .{if (state.dry_run) "dry run (print)" else "delete"});
        if (state.recursive)
            std.debug.print("Recursion: enabled\n", .{});
        if (state.verbose)
            std.debug.print("Verbose: enabled\n", .{});
    }

    const data = try std.fs.cwd().readFileAlloc(allocator, state.clnup_path, 1 << 20);
    defer allocator.free(data);

    const rules = try parseRules(allocator, data);
    defer {
        for (rules) |r| allocator.free(r.pattern);
        allocator.free(rules);
    }

    const handler: HandlerFn = if (state.dry_run) printHandler else deleteHandler;

    if (state.recursive) {
        try walk(state.root, rules, handler, allocator, state);
    } else {
        try processDir(state.root, rules, handler, allocator, state);
    }
}

// ------------------------------------------------------------
// CLI parsing
// ------------------------------------------------------------
fn parseArgs(alloc: std.mem.Allocator) !ActionState {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();

    var recursive = false;
    var quiet = false;
    var verbose = false;
    var dry_run = false;
    var clnup_path: []const u8 = ".clnup";
    var root: []const u8 = ".";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-f")) {
            const p = args.next() orelse usage();
            clnup_path = try alloc.dupe(u8, p);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            usage();
        } else {
            root = try alloc.dupe(u8, arg);
        }
    }

    return ActionState{
        .recursive = recursive,
        .quiet = quiet,
        .verbose = verbose,
        .dry_run = dry_run,
        .clnup_path = clnup_path,
        .root = root,
    };
}

fn usage() noreturn {
    std.debug.print(
        "Usage: clnup [-r] [-f <file>] [-q] [-v] [-d] [path]\n" ++
            "Options:\n" ++
            "  -r       Recurse into subdirectories\n" ++
            "  -f FILE  Specify cleanup rules file (default: .clnup)\n" ++
            "  -q       Quiet mode (suppress normal output)\n" ++
            "  -v       Verbose mode (extra logging)\n" ++
            "  -d       Dry run (print matched paths, no deletion)\n",
        .{},
    );
    std.process.exit(1);
}

// ------------------------------------------------------------
// Rules parsing
// ------------------------------------------------------------
fn parseRules(allocator: std.mem.Allocator, input: []const u8) ![]Rule {
    var list = std.ArrayList(Rule){};

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#')
            continue;

        var r = Rule{
            .pattern = undefined,
            .negated = false,
            .dir_only = false,
            .anchored = false,
        };

        var p = line;

        if (p[0] == '!') {
            r.negated = true;
            p = p[1..];
        }
        if (p.len > 0 and p[0] == '/') {
            r.anchored = true;
            p = p[1..];
        }
        if (p.len > 0 and p[p.len - 1] == '/') {
            r.dir_only = true;
            p = p[0 .. p.len - 1];
        }

        r.pattern = try allocator.dupe(u8, p);
        try list.append(allocator, r);
    }

    return list.toOwnedSlice(allocator);
}

// ------------------------------------------------------------
// Rule evaluation and glob matching
// ------------------------------------------------------------
fn evaluate(rel: []const u8, is_dir: bool, rules: []Rule) ActionResult {
    var result: ActionResult = .Keep;
    for (rules) |r| {
        if (r.dir_only and !is_dir) continue;
        if (matches(r, rel)) {
            result = if (r.negated) .Keep else .Delete;
        }
    }
    return result;
}

fn matches(r: Rule, rel: []const u8) bool {
    if (r.anchored) {
        return fnmatch(r.pattern, rel);
    }

    var it = std.mem.splitScalar(u8, rel, '/');
    var offset: usize = 0;

    while (true) {
        const part = it.next();
        if (part == null) break;

        const sub = rel[offset..];
        if (fnmatch(r.pattern, sub)) return true;
        offset += part.?.len + 1;
    }

    return false;
}

// Basic glob pattern matcher supporting * and ?
fn fnmatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;

    while (pi < pattern.len or ni < name.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            pi += 1;
            if (pi == pattern.len) return true;
            while (ni < name.len) {
                if (fnmatch(pattern[pi..], name[ni..])) return true;
                ni += 1;
            }
            return false;
        } else if (pi < pattern.len and ni < name.len and
            (pattern[pi] == '?' or pattern[pi] == name[ni]))
        {
            pi += 1;
            ni += 1;
        } else {
            return false;
        }
    }
    return pi == pattern.len and ni == name.len;
}

// ------------------------------------------------------------
// Directory traversal
// ------------------------------------------------------------
fn processDir(
    root: []const u8,
    rules: []Rule,
    handler: HandlerFn,
    allocator: std.mem.Allocator,
    state: ActionState,
) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const name = entry.name;
        const is_dir = entry.kind == .directory;
        if (evaluate(name, is_dir, rules) == .Delete) {
            try handler(name, is_dir, allocator, state.quiet, state.verbose);
        }
    }
}

fn walk(
    root: []const u8,
    rules: []Rule,
    handler: HandlerFn,
    allocator: std.mem.Allocator,
    state: ActionState,
) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const name = entry.name;
        const full = try std.fs.path.join(allocator, &.{ root, name });
        defer allocator.free(full);

        const is_dir = entry.kind == .directory;

        if (evaluate(name, is_dir, rules) == .Delete) {
            try handler(full, is_dir, allocator, state.quiet, state.verbose);
            continue;
        }

        if (is_dir) {
            try walk(full, rules, handler, allocator, state);
        }
    }
}

// ------------------------------------------------------------
// Handlers
// ------------------------------------------------------------
fn printHandler(path: []const u8, _: bool, _: std.mem.Allocator, quiet: bool, verbose: bool) !void {
    if (quiet) return;
    if (verbose)
        std.debug.print("[dry-run] {s}\n", .{path})
    else
        std.debug.print("{s}\n", .{path});
}

fn deleteHandler(path: []const u8, is_dir: bool, _: std.mem.Allocator, quiet: bool, verbose: bool) !void {
    if (!quiet) {
        if (verbose)
            std.debug.print("[delete] {s}\n", .{path})
        else
            std.debug.print("{s}\n", .{path});
    }

    if (is_dir)
        try std.fs.cwd().deleteTree(path)
    else
        try std.fs.cwd().deleteFile(path);
}
