//! C API for terminal screen search (ScreenSearch).
//!
//! Callers must serialize with other terminal mutations (same rule as
//! selection / grid_ref APIs).

const std = @import("std");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const terminal_c = @import("terminal.zig");
const ZigTerminal = @import("../Terminal.zig");
const Screen = @import("../Screen.zig");
const ScreenSearch = @import("../search/screen.zig").ScreenSearch;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const Result = @import("result.zig").Result;

/// One linear match in **screen** coordinates (POINT_TAG_SCREEN).
/// Endpoints are inclusive. Multi-row Zig matches are expanded into
/// one entry per row when collected.
///
/// C: GhosttyScreenSearchMatch
pub const Match = extern struct {
    size: usize = @sizeOf(Match),
    start_x: u16,
    end_x: u16,
    /// Screen row (0 = oldest history).
    y: u32,
};

/// Owns a completed ScreenSearch plus a flat match table for C consumers.
const SearchWrapper = struct {
    alloc: std.mem.Allocator,
    /// Active-screen searcher (references terminal.screens.active).
    search: ScreenSearch,
    /// Flattened row-local matches, newest-first (same order as ScreenSearch.matches).
    matches: std.ArrayListUnmanaged(Match) = .empty,

    fn deinit(self: *SearchWrapper) void {
        self.matches.deinit(self.alloc);
        self.search.deinit();
        self.alloc.destroy(self);
    }
};

/// C: GhosttyScreenSearch
pub const ScreenSearchHandle = ?*SearchWrapper;

/// Create a searcher for the terminal's **active** screen and run it to completion.
///
/// Needle is UTF-8 (copied). Empty needle returns `invalid_value`.
/// On success, matches are ready via `match_count` / `match_at`.
pub fn screen_search_new(
    alloc_: ?*const CAllocator,
    terminal_: terminal_c.Terminal,
    needle: ?[*]const u8,
    needle_len: usize,
    out: *ScreenSearchHandle,
) callconv(lib.calling_conv) Result {
    out.* = null;
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    if (needle_len == 0 or needle == null) return .invalid_value;

    const alloc = lib.alloc.default(alloc_);
    const slice = needle.?[0..needle_len];

    const wrapper = alloc.create(SearchWrapper) catch return .out_of_memory;
    errdefer alloc.destroy(wrapper);

    wrapper.* = .{
        .alloc = alloc,
        .search = ScreenSearch.init(alloc, t.screens.active, slice) catch {
            return .out_of_memory;
        },
        .matches = .empty,
    };
    errdefer wrapper.search.deinit();

    // Full search under the caller's lock (same as selection APIs).
    wrapper.search.searchAll() catch {
        wrapper.search.deinit();
        alloc.destroy(wrapper);
        return .out_of_memory;
    };

    collectMatches(wrapper) catch {
        wrapper.deinit();
        return .out_of_memory;
    };

    out.* = wrapper;
    return .success;
}

pub fn screen_search_free(
    handle: ScreenSearchHandle,
) callconv(lib.calling_conv) void {
    const wrapper = handle orelse return;
    wrapper.deinit();
}

pub fn screen_search_match_count(
    handle: ScreenSearchHandle,
    out: *usize,
) callconv(lib.calling_conv) Result {
    const wrapper = handle orelse return .invalid_value;
    out.* = wrapper.matches.items.len;
    return .success;
}

/// `index` 0 = most recent match (bottom of screen), increasing toward history.
pub fn screen_search_match_at(
    handle: ScreenSearchHandle,
    index: usize,
    out: *Match,
) callconv(lib.calling_conv) Result {
    const wrapper = handle orelse return .invalid_value;
    if (index >= wrapper.matches.items.len) return .no_value;
    out.* = wrapper.matches.items[index];
    out.size = @sizeOf(Match);
    return .success;
}

fn collectMatches(wrapper: *SearchWrapper) error{OutOfMemory}!void {
    const alloc = wrapper.alloc;
    const screen = wrapper.search.screen;
    const list = try wrapper.search.matches(alloc);
    defer {
        // ScreenSearch.matches returns a slice of *references* into internal
        // result arrays — do not deinit the highlights, only free the slice.
        alloc.free(list);
    }

    try wrapper.matches.ensureTotalCapacity(alloc, list.len);

    // list is newest → oldest. Expand multi-row into per-row matches in the
    // same order (newest first).
    for (list) |hl| {
        try appendExpanded(wrapper, screen, hl);
    }
}

fn appendExpanded(
    wrapper: *SearchWrapper,
    screen: *Screen,
    hl: FlattenedHighlight,
) error{OutOfMemory}!void {
    const start_pin = hl.startPin();
    const end_pin = hl.endPin();
    const start_pt = screen.pages.pointFromPin(.screen, start_pin) orelse return;
    const end_pt = screen.pages.pointFromPin(.screen, end_pin) orelse return;

    const sy = start_pt.screen.y;
    const ey = end_pt.screen.y;
    const sx = start_pt.screen.x;
    const ex = end_pt.screen.x;
    const cols = screen.pages.cols;

    if (sy == ey) {
        const lo = @min(sx, ex);
        const hi = @max(sx, ex);
        try wrapper.matches.append(wrapper.alloc, .{
            .start_x = lo,
            .end_x = hi,
            .y = sy,
        });
        return;
    }

    // Multi-row: top row sx..cols-1, full middle rows, bottom 0..ex.
    // Order within one logical match: top → bottom so paint is contiguous;
    // overall list stays newest-first by outer order.
    if (sy < ey) {
        try wrapper.matches.append(wrapper.alloc, .{
            .start_x = sx,
            .end_x = if (cols > 0) cols - 1 else 0,
            .y = sy,
        });
        var y = sy + 1;
        while (y < ey) : (y += 1) {
            try wrapper.matches.append(wrapper.alloc, .{
                .start_x = 0,
                .end_x = if (cols > 0) cols - 1 else 0,
                .y = y,
            });
        }
        try wrapper.matches.append(wrapper.alloc, .{
            .start_x = 0,
            .end_x = ex,
            .y = ey,
        });
    } else {
        // Reverse pin order — treat as end→start.
        try wrapper.matches.append(wrapper.alloc, .{
            .start_x = ex,
            .end_x = if (cols > 0) cols - 1 else 0,
            .y = ey,
        });
        var y = ey + 1;
        while (y < sy) : (y += 1) {
            try wrapper.matches.append(wrapper.alloc, .{
                .start_x = 0,
                .end_x = if (cols > 0) cols - 1 else 0,
                .y = y,
            });
        }
        try wrapper.matches.append(wrapper.alloc, .{
            .start_x = 0,
            .end_x = sx,
            .y = sy,
        });
    }
}

const testing = std.testing;

test "search: empty needle is invalid_value" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        2,
    ));
    defer terminal_c.free(terminal);

    var handle: ScreenSearchHandle = @ptrFromInt(1);
    try testing.expectEqual(Result.invalid_value, screen_search_new(
        &lib.alloc.test_allocator,
        terminal,
        "".ptr,
        0,
        &handle,
    ));
    try testing.expectEqual(@as(ScreenSearchHandle, null), handle);

    handle = @ptrFromInt(1);
    try testing.expectEqual(Result.invalid_value, screen_search_new(
        &lib.alloc.test_allocator,
        terminal,
        null,
        3,
        &handle,
    ));
    try testing.expectEqual(@as(ScreenSearchHandle, null), handle);
}

test "search: simple match" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        20,
        2,
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "hello", 5);

    var handle: ScreenSearchHandle = null;
    try testing.expectEqual(Result.success, screen_search_new(
        &lib.alloc.test_allocator,
        terminal,
        "ell",
        3,
        &handle,
    ));
    defer screen_search_free(handle);

    var count: usize = 0;
    try testing.expectEqual(Result.success, screen_search_match_count(handle, &count));
    try testing.expectEqual(@as(usize, 1), count);

    var match: Match = undefined;
    try testing.expectEqual(Result.success, screen_search_match_at(handle, 0, &match));
    try testing.expectEqual(@as(u16, 1), match.start_x);
    try testing.expectEqual(@as(u16, 3), match.end_x);

    try testing.expectEqual(Result.no_value, screen_search_match_at(handle, 1, &match));
}

test "search: multi-row match expands" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        4,
        3,
    ));
    defer terminal_c.free(terminal);

    // 4-col grid: "abcd" + "efgh" wraps "cdef" across the row boundary.
    terminal_c.vt_write(terminal, "abcdefgh", 8);

    var handle: ScreenSearchHandle = null;
    try testing.expectEqual(Result.success, screen_search_new(
        &lib.alloc.test_allocator,
        terminal,
        "cdef",
        4,
        &handle,
    ));
    defer screen_search_free(handle);

    var count: usize = 0;
    try testing.expectEqual(Result.success, screen_search_match_count(handle, &count));
    try testing.expect(count >= 2);

    var first: Match = undefined;
    var second: Match = undefined;
    try testing.expectEqual(Result.success, screen_search_match_at(handle, 0, &first));
    try testing.expectEqual(Result.success, screen_search_match_at(handle, 1, &second));
    try testing.expect(first.y != second.y);
}

test "search: free null is safe" {
    screen_search_free(null);
}
