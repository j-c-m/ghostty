//! JetBrains Mono official `calt` ASCII ligatures.
//!
//! https://github.com/JetBrains/JetBrainsMono/wiki/List-of-supported-symbols
//!
//! Indexed longest-first. `spanLength` is a table scan, not a typesetter.
//! `====` is not `===` (`repeatTouchesSame`).

const programming_ligatures = @This();

const std = @import("std");
const terminal = @import("../terminal/main.zig");
const page = terminal.page;

/// JetBrains Mono `calt` ligatures (official list). Copied from Jetty
/// `ProgrammingLigatures.raw`.
pub const raw: []const []const u8 = &.{
    "--",   "---",  "==",  "===", "!=",   "!==",  "=!=", "=:=",  "=/=",
    "<=",   ">=",   "&&",  "&&&", "&=",   "++",   "+++", "***",  ";;",
    "!!",   "??",   "???", "?:",  "?.",   "?=",   "<:",  ":<",   ":>",
    ">:",   "<:<",  "<>",  "<<<", ">>>",  "<<",   ">>",  "||",   "-|",
    "_|_",  "|-",   "||-", "|=",  "||=",  "##",   "###", "####", "#{",
    "#[",   "]#",   "#(",  "#?",  "#_",   "#_(",  "#:",  "#!",   "#=",
    "^=",   "<$>",  "<$",  "$>",  "<+>",  "<+",   "+>",  "<*>",  "<*",
    "*>",   "</",   "</>", "/>",  "<!--", "<#--", "-->", "->",   "->>",
    "<<-",  "<-",   "<=<", "=<<", "<<=",  "<==",  "<=>", "<==>", "==>",
    "=>",   "=>>",  ">=>", ">>=", ">>-",  ">-",   "-<",  "-<<",  ">->",
    "<-<",  "<-|",  "<=|", "|=>", "|->",  "<->",  "<<~", "<~~",  "<~",
    "<~>",  "~~",   "~~>", "~>",  "~-",   "-~",   "~@",  "[||]", "|]",
    "[|",   "|}",   "{|",  "[<",  ">]",   "|>",   "<|",  "||>",  "<||",
    "|||>", "<|||", "<|>", "...", "..",   ".=",   "..<", ".?",   "::",
    ":::",  ":=",   "::=", ":?",  ":?>",  "//",   "///", "/*",   "*/",
    "/=",   "//=",  "/==", "@_",  "__",   ";;;",
};

fn tableLessThan(_: void, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len > b.len;
    return std.mem.order(u8, a, b) == .lt;
}

/// `raw` sorted longest first, then lexicographic.
pub const table: [raw.len][]const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [raw.len][]const u8 = undefined;
    for (raw, 0..) |s, i| t[i] = s;
    std.mem.sort([]const u8, &t, {}, tableLessThan);
    break :blk t;
};

/// Context for `spanLength`. `styleBits(i)` is `(bold ? 1 : 0) | (italic ? 2 : 0)`.
pub const NoStyle = struct {
    pub fn styleBits(_: NoStyle, _: usize) u2 {
        return 0;
    }
};

/// Length of the table hit at `x`, or 0.
///
/// `ctx` must provide `fn styleBits(self, i: usize) u2`. Breaks on
/// sprite-ineligible content are handled by the caller; this scan rejects
/// wide, grapheme, and bold/italic changes inside the pattern.
pub fn spanLength(
    cells: []const page.Cell,
    x: usize,
    ctx: anytype,
) usize {
    if (x >= cells.len) return 0;
    const cell0 = cells[x];
    if (!isSpanStart(cell0)) return 0;
    const p0: u8 = @intCast(cell0.codepoint());
    for (table) |pat| {
        if (pat.len < 2 or pat[0] != p0) continue;
        if (match(cells, x, pat, ctx) and
            !repeatTouchesSame(cells, x, pat))
        {
            return pat.len;
        }
    }
    return 0;
}

fn isSpanStart(cell: page.Cell) bool {
    if (cell.content_tag != .codepoint) return false;
    if (cell.wide != .narrow) return false;
    const p = cell.codepoint();
    return p >= 0x21 and p <= 0x7E;
}

fn isNarrowScalar(cell: page.Cell) bool {
    return cell.content_tag == .codepoint and cell.wide == .narrow;
}

/// `===` / `---` / `####` only when the run is exactly `pat` (JetBrains `calt`).
fn repeatTouchesSame(
    cells: []const page.Cell,
    x: usize,
    pat: []const u8,
) bool {
    if (pat.len == 0) return false;
    const b = pat[0];
    for (pat[1..]) |c| {
        if (c != b) return false;
    }
    if (x > 0) {
        const cell = cells[x - 1];
        if (isNarrowScalar(cell) and cell.codepoint() == b) return true;
    }
    if (x + pat.len < cells.len) {
        const cell = cells[x + pat.len];
        if (isNarrowScalar(cell) and cell.codepoint() == b) return true;
    }
    return false;
}

/// Bytes of `pat` at `x`, same bold/italic, no wide/grapheme.
fn match(
    cells: []const page.Cell,
    x: usize,
    pat: []const u8,
    ctx: anytype,
) bool {
    if (pat.len == 0 or x + pat.len > cells.len) return false;
    const a0 = ctx.styleBits(x);
    for (pat, 0..) |byte, i| {
        const cell = cells[x + i];
        if (!isNarrowScalar(cell)) return false;
        if (cell.codepoint() != byte) return false;
        if (ctx.styleBits(x + i) != a0) return false;
    }
    return true;
}

fn asciiCell(ch: u8) page.Cell {
    return .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = .{ .data = ch } },
        .wide = .narrow,
    };
}

fn span(s: []const u8) usize {
    var buf: [16]page.Cell = undefined;
    std.debug.assert(s.len <= buf.len);
    for (s, 0..) |c, i| buf[i] = asciiCell(c);
    return spanLength(buf[0..s.len], 0, NoStyle{});
}

test "table is longest first, unique, and contains official ligatures" {
    const testing = std.testing;

    try testing.expectEqual(raw.len, table.len);

    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(testing.allocator);
    for (table, 0..) |s, i| {
        if (i + 1 < table.len) {
            try testing.expect(table[i].len >= table[i + 1].len);
        }
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(s);
        const gop = try seen.getOrPut(testing.allocator, hasher.final());
        try testing.expect(!gop.found_existing);
    }
    try testing.expectEqual(raw.len, seen.count());

    const has = struct {
        fn has(want: []const u8) bool {
            for (table) |s| {
                if (std.mem.eql(u8, s, want)) return true;
            }
            return false;
        }
    }.has;

    try testing.expect(has("=>"));
    try testing.expect(has("!=="));
    try testing.expect(has("///"));
    try testing.expect(has("<=>"));
    try testing.expect(has("||="));
    try testing.expect(has("<!--"));
    try testing.expect(has("####"));
    try testing.expect(has("__"));

    const idx = struct {
        fn idx(want: []const u8) usize {
            for (table, 0..) |s, i| {
                if (std.mem.eql(u8, s, want)) return i;
            }
            unreachable;
        }
    }.idx;

    try testing.expect(idx("!==") < idx("=="));
    try testing.expect(idx("///") < idx("//"));
    try testing.expect(idx("<=>") < idx("<="));
    try testing.expect(idx("<==>") < idx("<=>"));
    try testing.expect(idx("||=") < idx("||"));
    try testing.expect(idx("####") < idx("###"));
    try testing.expect(idx("...") < idx(".."));
    try testing.expect(idx("<!--") < idx("</"));
}

test "spanLength longest-first and repeatTouchesSame" {
    const testing = std.testing;

    var eq3 = [_]page.Cell{ asciiCell('='), asciiCell('='), asciiCell('=') };
    try testing.expectEqual(@as(usize, 3), spanLength(&eq3, 0, NoStyle{}));
    try testing.expectEqual(@as(usize, 0), spanLength(&eq3, 1, NoStyle{}));

    try testing.expectEqual(@as(usize, 3), span("///     "[0..8]));
    try testing.expectEqual(@as(usize, 3), span("<=>     "[0..8]));
    try testing.expectEqual(@as(usize, 3), span("||=     "[0..8]));
    try testing.expectEqual(@as(usize, 4), span("<!--    "[0..8]));
    try testing.expectEqual(@as(usize, 4), span("####    "[0..8]));
    try testing.expectEqual(@as(usize, 4), span("<==>    "[0..8]));
    try testing.expectEqual(@as(usize, 3), span("...     "[0..8]));
    try testing.expectEqual(@as(usize, 0), span("====    "[0..8]));
    try testing.expectEqual(@as(usize, 0), span("======  "[0..8]));
    try testing.expectEqual(@as(usize, 0), span("----    "[0..8]));
    try testing.expectEqual(@as(usize, 0), span("#####   "[0..8]));
    try testing.expectEqual(@as(usize, 0), span("....    "[0..8]));
    try testing.expectEqual(@as(usize, 3), span("+++ x   "[0..8]));
    try testing.expectEqual(@as(usize, 0), span("++++    "[0..8]));
    try testing.expectEqual(@as(usize, 3), span("=== === "[0..8]));
    try testing.expectEqual(@as(usize, 2), span("=>      "[0..8]));
    try testing.expectEqual(@as(usize, 0), span("===="));
    try testing.expectEqual(@as(usize, 3), span("==="));
}

test "hello is not a span" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), span("hello"));
}

test "bold/italic change breaks a span" {
    const testing = std.testing;
    const cells = [_]page.Cell{ asciiCell('='), asciiCell('>') };
    const ItalicSecond = struct {
        pub fn styleBits(_: @This(), i: usize) u2 {
            return if (i == 1) 2 else 0;
        }
    };
    try testing.expectEqual(@as(usize, 0), spanLength(&cells, 0, ItalicSecond{}));
    try testing.expectEqual(@as(usize, 2), spanLength(&cells, 0, NoStyle{}));
}
