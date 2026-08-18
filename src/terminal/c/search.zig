//! C API for terminal screen search (ScreenSearch).
//!
//! Search is serialized with other terminal mutations while
//! `ghostty_screen_search_new` runs. The returned handle is a match
//! snapshot and does not keep the terminal alive.

const std = @import("std");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const terminal_c = @import("terminal.zig");
const Screen = @import("../Screen.zig");
const ScreenSearch = @import("../search/screen.zig").ScreenSearch;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const Result = @import("result.zig").Result;

/// One row-local match in screen coordinates (POINT_TAG_SCREEN).
/// Endpoints are inclusive. Multi-row engine matches expand to one
/// entry per row.
///
/// C: GhosttyScreenSearchMatch
pub const Match = extern struct {
    start_x: u16,
    end_x: u16,
    /// Screen row (0 = oldest history).
    y: u32,
};

const SearchWrapper = struct {
    alloc: std.mem.Allocator,
    /// Newest-first, same order as ScreenSearch.matches.
    matches: std.ArrayListUnmanaged(Match) = .empty,

    fn deinit(self: *SearchWrapper) void {
        self.matches.deinit(self.alloc);
        self.alloc.destroy(self);
    }
};

/// C: GhosttyScreenSearch
pub const ScreenSearchHandle = ?*SearchWrapper;

pub fn screen_search_new(
    alloc_: ?*const CAllocator,
    terminal_: terminal_c.Terminal,
    needle: ?[*]const u8,
    needle_len: usize,
    out: *ScreenSearchHandle,
) callconv(lib.calling_conv) Result {
    out.* = screen_search_new_(
        alloc_,
        terminal_,
        needle,
        needle_len,
    ) catch |err| {
        out.* = null;
        return switch (err) {
            error.InvalidValue => .invalid_value,
            error.OutOfMemory => .out_of_memory,
        };
    };
    return .success;
}

fn screen_search_new_(
    alloc_: ?*const CAllocator,
    terminal_: terminal_c.Terminal,
    needle: ?[*]const u8,
    needle_len: usize,
) error{ InvalidValue, OutOfMemory }!*SearchWrapper {
    const t = terminal_c.zigTerminal(terminal_) orelse return error.InvalidValue;
    if (needle_len == 0 or needle == null) return error.InvalidValue;

    const alloc = lib.alloc.default(alloc_);
    const slice = needle.?[0..needle_len];

    var search = try ScreenSearch.init(alloc, t.screens.active, slice);
    defer search.deinit();
    try search.searchAll();

    const wrapper = try alloc.create(SearchWrapper);
    errdefer alloc.destroy(wrapper);
    wrapper.* = .{ .alloc = alloc, .matches = .empty };
    errdefer wrapper.matches.deinit(alloc);

    try collectMatches(wrapper, &search);
    return wrapper;
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
    return .success;
}

fn collectMatches(wrapper: *SearchWrapper, search: *ScreenSearch) error{OutOfMemory}!void {
    const alloc = wrapper.alloc;
    const list = try search.matches(alloc);
    defer alloc.free(list);

    for (list) |hl| {
        try appendExpanded(wrapper, search.screen, hl);
    }
}

fn appendExpanded(
    wrapper: *SearchWrapper,
    screen: *Screen,
    hl: FlattenedHighlight,
) error{OutOfMemory}!void {
    const start_pt = screen.pages.pointFromPin(.screen, hl.startPin()) orelse return;
    const end_pt = screen.pages.pointFromPin(.screen, hl.endPin()) orelse return;

    const sy = start_pt.screen.y;
    const ey = end_pt.screen.y;
    const sx = start_pt.screen.x;
    const ex = end_pt.screen.x;
    const last_col = screen.pages.cols -| 1;

    if (sy == ey) {
        try wrapper.matches.append(wrapper.alloc, .{
            .start_x = @min(sx, ex),
            .end_x = @max(sx, ex),
            .y = sy,
        });
        return;
    }

    try wrapper.matches.append(wrapper.alloc, .{
        .start_x = sx,
        .end_x = last_col,
        .y = sy,
    });
    var y = sy + 1;
    while (y < ey) : (y += 1) {
        try wrapper.matches.append(wrapper.alloc, .{
            .start_x = 0,
            .end_x = last_col,
            .y = y,
        });
    }
    try wrapper.matches.append(wrapper.alloc, .{
        .start_x = 0,
        .end_x = ex,
        .y = ey,
    });
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
    try testing.expectEqual(@as(u32, 0), match.y);

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
    try testing.expectEqual(@as(usize, 2), count);

    var first: Match = undefined;
    var second: Match = undefined;
    try testing.expectEqual(Result.success, screen_search_match_at(handle, 0, &first));
    try testing.expectEqual(Result.success, screen_search_match_at(handle, 1, &second));
    try testing.expectEqual(@as(u32, 0), first.y);
    try testing.expectEqual(@as(u16, 2), first.start_x);
    try testing.expectEqual(@as(u16, 3), first.end_x);
    try testing.expectEqual(@as(u32, 1), second.y);
    try testing.expectEqual(@as(u16, 0), second.start_x);
    try testing.expectEqual(@as(u16, 1), second.end_x);
}

test "search: no match" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        2,
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "hello", 5);

    var handle: ScreenSearchHandle = null;
    try testing.expectEqual(Result.success, screen_search_new(
        &lib.alloc.test_allocator,
        terminal,
        "xyz",
        3,
        &handle,
    ));
    defer screen_search_free(handle);

    var count: usize = 0;
    try testing.expectEqual(Result.success, screen_search_match_count(handle, &count));
    try testing.expectEqual(@as(usize, 0), count);
}

test "search: history match uses screen y" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        2,
    ));
    defer terminal_c.free(terminal);

    const text = "Fizz\r\nBuzz\r\nFizz\r\nBang";
    terminal_c.vt_write(terminal, text.ptr, text.len);

    var handle: ScreenSearchHandle = null;
    try testing.expectEqual(Result.success, screen_search_new(
        &lib.alloc.test_allocator,
        terminal,
        "Fizz",
        4,
        &handle,
    ));
    defer screen_search_free(handle);

    var count: usize = 0;
    try testing.expectEqual(Result.success, screen_search_match_count(handle, &count));
    try testing.expectEqual(@as(usize, 2), count);

    var newest: Match = undefined;
    var oldest: Match = undefined;
    try testing.expectEqual(Result.success, screen_search_match_at(handle, 0, &newest));
    try testing.expectEqual(Result.success, screen_search_match_at(handle, 1, &oldest));
    try testing.expectEqual(@as(u32, 2), newest.y);
    try testing.expectEqual(@as(u16, 0), newest.start_x);
    try testing.expectEqual(@as(u16, 3), newest.end_x);
    try testing.expectEqual(@as(u32, 0), oldest.y);
    try testing.expectEqual(@as(u16, 0), oldest.start_x);
    try testing.expectEqual(@as(u16, 3), oldest.end_x);
}

test "search: handle outlives terminal" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        20,
        2,
    ));
    terminal_c.vt_write(terminal, "hello", 5);

    var handle: ScreenSearchHandle = null;
    try testing.expectEqual(Result.success, screen_search_new(
        &lib.alloc.test_allocator,
        terminal,
        "ell",
        3,
        &handle,
    ));

    terminal_c.free(terminal);
    var count: usize = 0;
    try testing.expectEqual(Result.success, screen_search_match_count(handle, &count));
    try testing.expectEqual(@as(usize, 1), count);
    screen_search_free(handle);
}

test "search: free null is safe" {
    screen_search_free(null);
}
