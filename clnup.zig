const std = @import("std");

const Action = enum {
    Keep,
    Delete,
};

const Rule = struct {
    pattern: []const u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,
};

// runtime-selected handler → function pointer
const HandlerFn = *const fn (
    path: []const u8,
    is_dir: bool,
    allocator: std.mem.Allocator,
) anyerror!void;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var clnup_path: []const u8 = ".clnup";
    var action: []const u8 = "delete";
    var dry_run = false;

    var args = std.process.args();
    _ = args.next(); // executable

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-file")) {
            clnup_path = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "-action")) {
            action = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "-dry-run")) {
            dry_run = true;
        } else {
            return usage();
        }
    }

    if (dry_run) action = "print";

    const data = try std.fs.cwd().readFileAlloc(allocator, clnup_path, 1 << 20);
    defer allocator.free(data);

    const rules = try parseRules(allocator, data);
    defer {
        for (rules) |r| allocator.free(r.pattern);
        allocator.free(rules);
    }

    const handler: HandlerFn =
        if (std.mem.eql(u8, action, "print"))
            printHandler
        else if (std.mem.eql(u8, action, "delete"))
            deleteHandler
        else if (std.mem.eql(u8, action, "touch"))
            touchHandler
        else
            return usage();

    const root = std.fs.path.dirname(clnup_path) orelse ".";
    try walk(root, rules, handler, allocator);
}

fn usage() !void {
    std.debug.print(
        "Usage: clnup -file <.clnup> [-action=print|delete|touch] [-dry-run]\n",
        .{},
    );
    return error.InvalidArguments;
}

// ------------------------------------------------------------
// Rule parsing
// ------------------------------------------------------------

fn parseRules(allocator: std.mem.Allocator, input: []const u8) ![]Rule {
    var list = std.ArrayList(Rule){};

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

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
// Rule evaluation
// ------------------------------------------------------------

fn evaluate(rel: []const u8, is_dir: bool, rules: []Rule) Action {
    var result: Action = .Keep;
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

        offset += part.?.len + 1; // safe: part is not null here
    }

    return false;
}

// ------------------------------------------------------------
// Simple glob matcher (* and ?)
// ------------------------------------------------------------

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
// Directory walk
// ------------------------------------------------------------

fn walk(
    root: []const u8,
    rules: []Rule,
    handler: HandlerFn,
    allocator: std.mem.Allocator,
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
            try handler(full, is_dir, allocator);
            continue;
        }

        if (is_dir) {
            try walk(full, rules, handler, allocator);
        }
    }
}

// ------------------------------------------------------------
// Handlers
// ------------------------------------------------------------

fn printHandler(path: []const u8, _: bool, _: std.mem.Allocator) !void {
    std.debug.print("{s}\n", .{path});
}

fn deleteHandler(path: []const u8, _: bool, _: std.mem.Allocator) !void {
    std.debug.print("[delete] {s}\n", .{path});
    try std.fs.cwd().deleteTree(path);
}

fn touchHandler(path: []const u8, is_dir: bool, _: std.mem.Allocator) !void {
    if (is_dir) return;

    var file = try std.fs.cwd().createFile(path, .{
        .read = true,
        .truncate = false,
    });
    file.close();
}
