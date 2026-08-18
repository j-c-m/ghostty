/**
 * @file search.h
 *
 * C API for full-screen text search (ScreenSearch), including scrollback.
 *
 * Callers must serialize with other terminal mutations (same rule as
 * selection / grid_ref).
 */

#ifndef GHOSTTY_VT_SEARCH_H
#define GHOSTTY_VT_SEARCH_H

#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/terminal.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup search Screen Search
 *
 * Full-screen text search over the active screen including scrollback,
 * backed by Ghostty's ScreenSearch engine.
 *
 * @{
 */

/**
 * Opaque handle to a completed screen search.
 *
 * @ingroup search
 */
typedef struct GhosttyScreenSearchImpl *GhosttyScreenSearch;

/**
 * One match in screen coordinates (POINT_TAG_SCREEN).
 *
 * Endpoints are inclusive. Multi-row engine matches are expanded into
 * one row-local entry per row.
 *
 * This is a sized struct. Set size to sizeof(GhosttyScreenSearchMatch).
 *
 * @ingroup search
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;

  /** Start column (0-indexed, inclusive). */
  uint16_t start_x;

  /** End column (0-indexed, inclusive). */
  uint16_t end_x;

  /** Screen row (0 = oldest history). */
  uint32_t y;
} GhosttyScreenSearchMatch;

/**
 * Create a searcher for the terminal's active screen, run it to completion,
 * and return a handle with the full match list.
 *
 * The needle is UTF-8 and is copied. Empty needle returns GHOSTTY_INVALID_VALUE.
 *
 * Matches are ordered newest-first (bottom of screen toward history), matching
 * Ghostty's ScreenSearch.matches() order.
 *
 * The caller must free the handle with ghostty_screen_search_free().
 * The terminal must outlive the search handle.
 *
 * @param allocator Allocator, or NULL for the default
 * @param terminal Terminal to search (must not be NULL)
 * @param needle UTF-8 needle bytes (may be NULL only if needle_len is 0)
 * @param needle_len Length of needle in bytes
 * @param out Receives the search handle on success
 * @return GHOSTTY_SUCCESS on success
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_screen_search_new(
    const GhosttyAllocator *allocator,
    GhosttyTerminal terminal,
    const uint8_t *needle,
    size_t needle_len,
    GhosttyScreenSearch *out);

/**
 * Free a screen search handle.
 *
 * @param search Handle to free (may be NULL)
 *
 * @ingroup search
 */
GHOSTTY_API void ghostty_screen_search_free(GhosttyScreenSearch search);

/**
 * Number of row-local matches after a successful ghostty_screen_search_new.
 *
 * @param search Search handle
 * @param out Receives the match count
 * @return GHOSTTY_SUCCESS on success
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_screen_search_match_count(
    GhosttyScreenSearch search,
    size_t *out);

/**
 * Fetch a match by index (0 = most recent).
 *
 * @param search Search handle
 * @param index Match index in [0, count)
 * @param out Receives the match (size field is set by the library)
 * @return GHOSTTY_SUCCESS, or GHOSTTY_NO_VALUE if index is out of range
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_screen_search_match_at(
    GhosttyScreenSearch search,
    size_t index,
    GhosttyScreenSearchMatch *out);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SEARCH_H */
