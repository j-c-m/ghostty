#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [search-main]
int main() {
  GhosttyTerminal terminal;
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, 4, 3);
  assert(result == GHOSTTY_SUCCESS);

  const char *text = "abcdefgh";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  GhosttyScreenSearch search;
  result = ghostty_screen_search_new(
      NULL, terminal, (const uint8_t *)"cdef", 4, &search);
  assert(result == GHOSTTY_SUCCESS);

  size_t count = 0;
  result = ghostty_screen_search_match_count(search, &count);
  assert(result == GHOSTTY_SUCCESS);

  for (size_t i = 0; i < count; i++) {
    GhosttyScreenSearchMatch match;
    result = ghostty_screen_search_match_at(search, i, &match);
    assert(result == GHOSTTY_SUCCESS);
    printf(
        "%zu: y=%u %u-%u\n",
        i,
        match.y,
        match.start_x,
        match.end_x);
  }

  ghostty_screen_search_free(search);
  ghostty_terminal_free(terminal);
  return 0;
}
//! [search-main]
