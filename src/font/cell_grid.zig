//! Cell-grid letter path and table-driven programming ligatures.
//!
//! Used only when `experimental-cell-grid` is true. Flag off must not call
//! into this module on the ASCII path.

const cell_grid = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("main.zig");
const programming_ligatures = @import("programming_ligatures.zig");
const terminal = @import("../terminal/main.zig");
const page = terminal.page;
const Style = terminal.Style;

pub const Ligatures = enum {
    off,
    programming,
    on,
};

pub const Span = struct {
    x: u16,
    n: u16,
    font_index: font.Collection.Index,
    glyphs: []font.shape.Cell,
};

pub fn deinitSpans(alloc: Allocator, spans: *std.ArrayListUnmanaged(Span)) void {
    for (spans.items) |s| alloc.free(s.glyphs);
    spans.clearRetainingCapacity();
}

/// Fill `hide[0..cols]` and `spans` for one row.
///
/// `hide[i] != 0` means that cell is covered by a confirmed ligature and
/// should not get a letter glyph. The span start still emits coverage ink.
///
/// `cursor_x` splits ligatures when `font-shaping-break = cursor`. Pass
/// null to ligate through the cursor.
pub fn collect(
    alloc: Allocator,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    mode: Ligatures,
    shaper: *font.Shaper,
    grid: *font.SharedGrid,
    cache: ?*font.ShaperCache,
    hide: []u8,
    spans: *std.ArrayListUnmanaged(Span),
    cursor_x: ?usize,
) !void {
    deinitSpans(alloc, spans);
    @memset(hide, 0);
    if (mode == .off or cells.len == 0) return;

    switch (mode) {
        .off => unreachable,
        .programming => try scanProgramming(
            alloc,
            cells,
            shaper,
            grid,
            cache,
            hide,
            spans,
            cursor_x,
        ),
        .on => try scanOn(
            alloc,
            cells,
            shaper,
            grid,
            cache,
            hide,
            spans,
            cursor_x,
        ),
    }
}

fn scanProgramming(
    alloc: Allocator,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    shaper: *font.Shaper,
    grid: *font.SharedGrid,
    cache: ?*font.ShaperCache,
    hide: []u8,
    spans: *std.ArrayListUnmanaged(Span),
    cursor_x: ?usize,
) !void {
    const cols = cells.len;
    var x: usize = 0;
    while (x < cols) {
        const n = spanLengthAt(cells, x);
        if (n == 0) {
            x += 1;
            continue;
        }
        if (cursorInSpan(cursor_x, x, n)) {
            x += 1;
            continue;
        }
        if (try confirm(
            alloc,
            cells,
            shaper,
            grid,
            cache,
            x,
            n,
        )) |span| {
            markHide(hide, span.x, span.n);
            try spans.append(alloc, span);
        }
        x += n;
    }
}

fn scanOn(
    alloc: Allocator,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    shaper: *font.Shaper,
    grid: *font.SharedGrid,
    cache: ?*font.ShaperCache,
    hide: []u8,
    spans: *std.ArrayListUnmanaged(Span),
    cursor_x: ?usize,
) !void {
    const cols = cells.len;
    const raw = cells.items(.raw);
    var x: usize = 0;
    while (x < cols) {
        const n_prog = spanLengthAt(cells, x);
        if (n_prog > 0) {
            if (!cursorInSpan(cursor_x, x, n_prog)) {
                if (try confirm(
                    alloc,
                    cells,
                    shaper,
                    grid,
                    cache,
                    x,
                    n_prog,
                )) |span| {
                    markHide(hide, span.x, span.n);
                    try spans.append(alloc, span);
                }
            }
            x += n_prog;
            continue;
        }

        if (runChar(raw[x], grid) == null) {
            x += 1;
            continue;
        }

        const bold = styleOf(cells, x).flags.bold;
        const italic = styleOf(cells, x).flags.italic;
        var end = x + 1;
        while (end < cols) {
            if (runChar(raw[end], grid) == null) break;
            if (styleOf(cells, end).flags.bold != bold) break;
            if (styleOf(cells, end).flags.italic != italic) break;
            if (spanLengthAt(cells, end) > 0) break;
            if (cursor_x) |cx| {
                if (end == cx) break;
            }
            end += 1;
        }
        const n = end - x;
        if (n >= 2) {
            try emitShaped(
                alloc,
                cells,
                shaper,
                grid,
                cache,
                hide,
                spans,
                x,
                n,
            );
        }
        x = end;
    }
}

const StyleCtx = struct {
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,

    pub fn styleBits(self: StyleCtx, i: usize) u2 {
        const s = styleOf(self.cells, i);
        var bits: u2 = 0;
        if (s.flags.bold) bits |= 1;
        if (s.flags.italic) bits |= 2;
        return bits;
    }
};

fn spanLengthAt(
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    x: usize,
) usize {
    return programming_ligatures.spanLength(
        cells.items(.raw),
        x,
        StyleCtx{ .cells = cells },
    );
}

fn cursorInSpan(cursor_x: ?usize, x: usize, n: usize) bool {
    const cx = cursor_x orelse return false;
    return cx >= x and cx < x + n;
}

fn styleOf(
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    i: usize,
) Style {
    if (cells.items(.raw)[i].hasStyling()) return cells.items(.style)[i];
    return .{};
}

fn runChar(cell: page.Cell, grid: *font.SharedGrid) ?u32 {
    if (cell.content_tag != .codepoint) return null;
    if (cell.wide != .narrow) return null;
    const p: u32 = cell.codepoint();
    if (p < 0x20) return if (p == 0) 0x20 else null;
    if (grid.resolver.sprite) |sprite| {
        if (sprite.hasCodepoint(p, null)) return null;
    }
    return p;
}

fn markHide(hide: []u8, x: u16, n: u16) void {
    const start: usize = x;
    const end = @min(hide.len, start + @as(usize, n));
    @memset(hide[start..end], 1);
}

fn confirm(
    alloc: Allocator,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    shaper: *font.Shaper,
    grid: *font.SharedGrid,
    cache: ?*font.ShaperCache,
    x: usize,
    n: usize,
) !?Span {
    const shaped = try shapeRange(alloc, cells, shaper, grid, cache, x, n) orelse
        return null;
    if (!isLigature(grid, shaped.run.font_index, cells, x, n, shaped.cells)) {
        return null;
    }
    const glyphs = try alloc.dupe(font.shape.Cell, shaped.cells);
    errdefer alloc.free(glyphs);
    return .{
        .x = @intCast(x),
        .n = @intCast(n),
        .font_index = shaped.run.font_index,
        .glyphs = glyphs,
    };
}

fn emitShaped(
    alloc: Allocator,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    shaper: *font.Shaper,
    grid: *font.SharedGrid,
    cache: ?*font.ShaperCache,
    hide: []u8,
    spans: *std.ArrayListUnmanaged(Span),
    x: usize,
    n: usize,
) !void {
    const shaped = try shapeRange(alloc, cells, shaper, grid, cache, x, n) orelse
        return;
    const mask = try alloc.alloc(bool, n);
    defer alloc.free(mask);
    ligatedMask(grid, shaped.run.font_index, cells, x, n, shaped.cells, mask);

    var i: usize = 0;
    while (i < n) {
        if (!mask[i]) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < n and mask[j]) j += 1;
        if (j - i >= 2) {
            const glyphs = try glyphsForRange(alloc, shaped.cells, @intCast(i), @intCast(j - i));
            errdefer alloc.free(glyphs);
            const span: Span = .{
                .x = @intCast(x + i),
                .n = @intCast(j - i),
                .font_index = shaped.run.font_index,
                .glyphs = glyphs,
            };
            markHide(hide, span.x, span.n);
            try spans.append(alloc, span);
        }
        i = j;
    }
}

pub const Shaped = struct {
    run: font.shape.TextRun,
    cells: []const font.shape.Cell,
};

pub fn shapeRange(
    alloc: Allocator,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    shaper: *font.Shaper,
    grid: *font.SharedGrid,
    cache: ?*font.ShaperCache,
    start: usize,
    n: usize,
) !?Shaped {
    var tmp: std.MultiArrayList(terminal.RenderState.Cell) = .empty;
    defer tmp.deinit(alloc);
    try tmp.ensureTotalCapacity(alloc, n);
    const raw = cells.items(.raw);
    const grapheme = cells.items(.grapheme);
    const style = cells.items(.style);
    for (0..n) |i| {
        tmp.appendAssumeCapacity(.{
            .raw = raw[start + i],
            .grapheme = grapheme[start + i],
            .style = style[start + i],
        });
    }

    var it = shaper.runIterator(.{
        .grid = grid,
        .cells = tmp.slice(),
    });
    const run = (try it.next(alloc)) orelse return null;
    if (cache) |c| {
        if (c.get(run)) |cached| return .{ .run = run, .cells = cached };
    }
    const new_cells = try shaper.shape(run);
    if (cache) |c| {
        c.put(alloc, run, new_cells) catch {};
    }
    return .{ .run = run, .cells = new_cells };
}

fn cmapGlyph(
    grid: *font.SharedGrid,
    font_index: font.Collection.Index,
    cp: u32,
) ?u32 {
    if (font_index.special() != null) return cp;
    const face = grid.resolver.collection.getFace(font_index) catch return null;
    return face.glyphIndex(cp);
}

/// Confirm liga by cmap mismatch, not x_offset. JetBrains parks spacer+liga
/// at xOffset≈0.
pub fn isLigature(
    grid: *font.SharedGrid,
    font_index: font.Collection.Index,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    start: usize,
    n: usize,
    shaped: []const font.shape.Cell,
) bool {
    if (shaped.len == 0 or n == 0) return false;
    var stack: [8]bool = undefined;
    if (n <= stack.len) {
        ligatedMask(grid, font_index, cells, start, n, shaped, stack[0..n]);
        for (stack[0..n]) |m| if (m) return true;
        return false;
    }
    for (0..n) |i| {
        if (cellIsLigated(grid, font_index, cells, start, n, shaped, i))
            return true;
    }
    return false;
}

fn ligatedMask(
    grid: *font.SharedGrid,
    font_index: font.Collection.Index,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    start: usize,
    n: usize,
    shaped: []const font.shape.Cell,
    mask: []bool,
) void {
    std.debug.assert(mask.len == n);
    for (0..n) |i| {
        mask[i] = cellIsLigated(grid, font_index, cells, start, n, shaped, i);
    }
}

fn cellIsLigated(
    grid: *font.SharedGrid,
    font_index: font.Collection.Index,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    start: usize,
    n: usize,
    shaped: []const font.shape.Cell,
    i: usize,
) bool {
    _ = n;
    const raw = cells.items(.raw);
    const cp: u32 = if (raw[start + i].codepoint() == 0)
        ' '
    else
        raw[start + i].codepoint();
    const cmap = cmapGlyph(grid, font_index, cp);
    var found: usize = 0;
    var mismatch = false;
    for (shaped) |s| {
        if (s.x != i) continue;
        found += 1;
        if (cmap == null or s.glyph_index != cmap.?) mismatch = true;
    }
    return found != 1 or mismatch;
}

fn glyphsForRange(
    alloc: Allocator,
    shaped: []const font.shape.Cell,
    start: u16,
    n: u16,
) ![]font.shape.Cell {
    var count: usize = 0;
    for (shaped) |s| {
        if (s.x >= start and s.x < start + n) count += 1;
    }
    const out = try alloc.alloc(font.shape.Cell, count);
    var i: usize = 0;
    for (shaped) |s| {
        if (s.x >= start and s.x < start + n) {
            out[i] = s;
            out[i].x -= start;
            i += 1;
        }
    }
    return out;
}

pub fn spanStartingAt(spans: []const Span, x: usize) ?Span {
    for (spans) |s| {
        if (s.x == x) return s;
    }
    return null;
}

pub fn fontStyle(style: Style) font.Style {
    if (style.flags.bold) {
        if (style.flags.italic) return .bold_italic;
        return .bold;
    }
    if (style.flags.italic) return .italic;
    return .regular;
}

/// True when this cell should stay on Ghostty's existing addGlyph path
/// (sprites, graphemes, wide, Kitty, color). Narrow ASCII scalars are false.
pub fn useExistingPath(cell: page.Cell, grid: *font.SharedGrid) bool {
    if (cell.wide != .narrow) return true;
    if (cell.hasGrapheme()) return true;
    switch (cell.content_tag) {
        .codepoint => {},
        .codepoint_grapheme => return true,
        .bg_color_palette, .bg_color_rgb => return false,
    }
    const cp = cell.codepoint();
    if (cp == 0) return false;
    if (cp == terminal.kitty.graphics.unicode.placeholder) return true;
    if (grid.resolver.sprite) |sprite| {
        if (sprite.hasCodepoint(cp, null)) return true;
    }
    return false;
}

test {
    _ = programming_ligatures;
}

const TestShaper = struct {
    alloc: Allocator,
    shaper: font.Shaper,
    grid: *font.SharedGrid,
    lib: font.Library,

    fn deinit(self: *TestShaper) void {
        self.shaper.deinit();
        self.grid.deinit(self.alloc);
        self.alloc.destroy(self.grid);
        self.lib.deinit();
    }
};

fn testShaper(alloc: Allocator, features: []const []const u8) !TestShaper {
    var lib = try font.Library.init(alloc);
    errdefer lib.deinit();

    var c = font.Collection.init();
    c.load_options = .{ .library = lib };
    _ = try c.add(alloc, try .init(
        lib,
        font.embedded.jetbrains_mono,
        .{ .size = .{ .points = 13 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

    const grid_ptr = try alloc.create(font.SharedGrid);
    errdefer alloc.destroy(grid_ptr);
    grid_ptr.* = try .init(alloc, .{ .collection = c });
    errdefer grid_ptr.deinit(alloc);

    var shaper = try font.Shaper.init(alloc, .{ .features = features });
    errdefer shaper.deinit();

    return .{
        .alloc = alloc,
        .shaper = shaper,
        .grid = grid_ptr,
        .lib = lib,
    };
}

fn collectRow(
    alloc: Allocator,
    testdata: *TestShaper,
    text: []const u8,
    mode: Ligatures,
    hide: []u8,
    spans: *std.ArrayListUnmanaged(Span),
) !void {
    const io = std.testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{
        .cols = @intCast(text.len),
        .rows = 1,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(text);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    testdata.shaper.shape_calls = 0;
    try collect(
        alloc,
        state.row_data.get(0).cells.slice(),
        mode,
        &testdata.shaper,
        testdata.grid,
        null,
        hide,
        spans,
        null,
    );
}

test "collect programming hides arrow only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{});
    defer testdata.deinit();

    var hide: [6]u8 = undefined;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer {
        deinitSpans(alloc, &spans);
        spans.deinit(alloc);
    }

    try collectRow(alloc, &testdata, "ab=>cd", .programming, &hide, &spans);

    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(@as(u16, 2), spans.items[0].x);
    try testing.expectEqual(@as(u16, 2), spans.items[0].n);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1, 0, 0 }, &hide);
    try testing.expectEqual(@as(usize, 1), testdata.shaper.shape_calls);
}

test "coverage raster for == and => has ink" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{});
    defer testdata.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    const cases = [_][]const u8{ "==", "=>", "!=" };
    for (cases) |text| {
        var hide: [2]u8 = undefined;
        var spans: std.ArrayListUnmanaged(Span) = .empty;
        defer {
            deinitSpans(alloc, &spans);
            spans.deinit(alloc);
        }

        try collectRow(alloc, &testdata, text, .programming, &hide, &spans);
        try testing.expectEqual(@as(usize, 1), spans.items.len);
        const span = spans.items[0];

        testdata.grid.lock.lockUncancelable(testing.io);
        defer testdata.grid.lock.unlock(testing.io);
        const face = try testdata.grid.resolver.collection.getFace(span.font_index);

        var ink = false;
        for (span.glyphs) |sc| {
            if (sc.glyph_index == 0) continue;
            const g = try face.renderGlyph(
                alloc,
                &atlas,
                sc.glyph_index,
                .{
                    .grid_metrics = testdata.grid.metrics,
                    .cell_box = true,
                    .clip_cols = @intCast(span.n),
                },
            );
            if (g.width > 0 and g.height > 0) ink = true;
        }
        try testing.expect(ink);
    }
}

test "collect on hides arrow only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{});
    defer testdata.deinit();

    var hide: [6]u8 = undefined;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer {
        deinitSpans(alloc, &spans);
        spans.deinit(alloc);
    }

    try collectRow(alloc, &testdata, "ab=>cd", .on, &hide, &spans);

    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(@as(u16, 2), spans.items[0].x);
    try testing.expectEqual(@as(u16, 2), spans.items[0].n);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1, 0, 0 }, &hide);
}

test "collect off is empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{});
    defer testdata.deinit();

    var hide: [2]u8 = .{ 1, 1 };
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer {
        deinitSpans(alloc, &spans);
        spans.deinit(alloc);
    }

    try collectRow(alloc, &testdata, "=>", .off, &hide, &spans);

    try testing.expectEqual(@as(usize, 0), spans.items.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, &hide);
    try testing.expectEqual(@as(usize, 0), testdata.shaper.shape_calls);
}

test "collect programming hello does not shape" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{});
    defer testdata.deinit();

    var hide: [5]u8 = undefined;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer {
        deinitSpans(alloc, &spans);
        spans.deinit(alloc);
    }

    try collectRow(alloc, &testdata, "hello", .programming, &hide, &spans);

    try testing.expectEqual(@as(usize, 0), spans.items.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, &hide);
    try testing.expectEqual(@as(usize, 0), testdata.shaper.shape_calls);
}

test "collect -calt does not confirm =>" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{"-calt"});
    defer testdata.deinit();

    var hide: [2]u8 = undefined;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer {
        deinitSpans(alloc, &spans);
        spans.deinit(alloc);
    }

    try collectRow(alloc, &testdata, "=>", .programming, &hide, &spans);

    try testing.expectEqual(@as(usize, 0), spans.items.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, &hide);
    try testing.expectEqual(@as(usize, 1), testdata.shaper.shape_calls);
}

test "collect programming ==== is not ===" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{});
    defer testdata.deinit();

    var hide: [4]u8 = undefined;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer {
        deinitSpans(alloc, &spans);
        spans.deinit(alloc);
    }

    try collectRow(alloc, &testdata, "====", .programming, &hide, &spans);

    try testing.expectEqual(@as(usize, 0), spans.items.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &hide);
    try testing.expectEqual(@as(usize, 0), testdata.shaper.shape_calls);
}

test "collect programming y-row does not shape" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{});
    defer testdata.deinit();

    const line: [80]u8 = @splat('y');
    var hide: [80]u8 = undefined;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer {
        deinitSpans(alloc, &spans);
        spans.deinit(alloc);
    }

    try collectRow(alloc, &testdata, &line, .programming, &hide, &spans);

    try testing.expectEqual(@as(usize, 0), spans.items.len);
    try testing.expectEqual(@as(usize, 0), testdata.shaper.shape_calls);
}

test "collect programming one arrow per line shapes once" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc, &.{});
    defer testdata.deinit();

    const line = "a=>aaaaaaaaaaaaaaaaa";
    var hide: [20]u8 = undefined;
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer {
        deinitSpans(alloc, &spans);
        spans.deinit(alloc);
    }

    try collectRow(alloc, &testdata, line, .programming, &hide, &spans);

    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(@as(usize, 1), testdata.shaper.shape_calls);
}
