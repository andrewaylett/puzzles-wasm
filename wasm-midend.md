# The midend-as-WASM interface

`wasmmidend.c`, built when CMake option `PUZZLES_WASM_MIDEND` is on (in an
Emscripten configure), exposes the mid-end's own API
(`midend.h`/`midend_*`, documented at
`https://www.chiark.greenend.org.uk/~sgtatham/puzzles/devel/midend.html`)
directly as WASM exports, instead of the canvas UI that `emcc.c` implements.
A front end using this module doesn't need to be written in C, or use
Emscripten's own JS-library glue at all: it just needs to call the exports
below and provide the imports below. The wasm module is built with
`-sSTANDALONE_WASM=1` specifically so that its only imports are the ones
listed here (plus whatever minimal WASI shims libc itself pulls in) — no
Emscripten-specific runtime JS is required to use it.

Two kinds of module are built:

- `<puzzle>-midend.wasm`, one per puzzle, exposing exactly that puzzle
  (`wasmmid_midend_new(void)`).
- `puzzles-midend.wasm`, one module covering every puzzle at once (mirroring
  `fuzzpuzz`'s use of `list.c`'s `COMBINED` mechanism), with two extra
  exports to pick a game by index: `wasmmid_game_count()` and
  `wasmmid_game_at(index)`, and `wasmmid_midend_new(index)` taking that index
  instead of no arguments.

All values are the natural C ABI ones for a 32-bit WASM target: pointers and
`int`/`bool`/`float` are passed and returned directly; strings are
NUL-terminated bytes in linear memory. Anything the mid-end allocates and
hands back (a `midend *`, a `char *`, a `config_item *`, ...) is owned by
the module — free it with the matching `free`-shaped export, never with a
host-side allocator.

## Exports

### Initialisation

The module is a WASI *reactor*, not a command: it has no `main()`, so it
exports `_initialize` instead of `_start`, and never calls `proc_exit`. A
host must call `_initialize` exactly once, immediately after instantiating
the module and before calling anything else — that's what runs libc/global
initialisation. `_initialize` takes no arguments and returns nothing useful
to the host, and unlike `_start` it's safe to assume the module keeps
running afterwards: that's the whole point of not having a `main()`.

### Lifecycle

- `wasmmid_midend_new()` (or `(index)` in the combined module) — creates a
  midend for one game and returns the `midend *` handle every other call
  below takes as its first argument.
- `midend_free`, `midend_new_game`, `midend_restart_game`, `midend_stop_anim`
- `midend_set_params`, `midend_get_params`
- `midend_size(me, int *x, int *y, bool user_size, double device_pixel_ratio)`
  — `x`/`y` are in/out: pass the space available, get back the size to use.
- `midend_reset_tilesize`, `midend_tilesize`
- `midend_process_key(me, x, y, button)` — see `puzzles.h` for the
  `LEFT_BUTTON`/`CURSOR_*`/`MOD_*` etc. button constants a front end must
  translate its own input events into; these are unchanged from the rest of
  Puzzles and not duplicated here.
  A front end that knows the pointer is a stylus may OR in `MOD_STYLUS` on
  mouse-down events; games with `STYLUS_SUPPORT` (e.g. Palisade, where a tap
  then cycles an edge through wall / no wall / unknown) use it to cope
  without a right button, and other games ignore it.
- `midend_force_redraw`, `midend_redraw`, `midend_timer(me, float tplus)`,
  `midend_freeze_timer`
- `midend_colours(me, int *ncolours)` → `float *`, RGB triples, `ncolours*3`
  floats long.
- `midend_which_game()` → `const game *`; see "Game accessors" below.
- `midend_wants_statusbar`, `midend_status`, `midend_can_undo`,
  `midend_can_redo`
- `midend_game_id(me, const char *id)`, `midend_get_game_id(me)`,
  `midend_get_random_seed(me)`, `midend_supersede_game_desc`
- `midend_can_format_as_text_now`, `midend_text_format`
- `midend_solve` (returns an error string, or NULL on success)
- `midend_rewrite_statusbar(me, const char *text)`
- `midend_get_cursor_location(me, int *x, int *y, int *w, int *h)`

### Presets and configuration (pull model)

A non-C host can't walk `struct preset_menu`/`config_item`/`key_label`, so
these are read through accessor functions instead of by dereferencing the
struct directly.

- `midend_get_presets(me, int *id_limit)` → `struct preset_menu *`. Walk it
  with:
  - `wasmmid_preset_menu_nentries(menu)`
  - `wasmmid_preset_menu_entry_title(menu, i)`
  - `wasmmid_preset_menu_entry_id(menu, i)` — pass to `midend_set_params` via
    `preset_menu_lookup_by_id(menu, id)`, or to `midend_which_preset()`'s
    return value to find the active entry.
  - `wasmmid_preset_menu_entry_submenu(menu, i)` — non-NULL if entry `i` is a
    submenu (recurse); otherwise:
  - `wasmmid_preset_menu_entry_params(menu, i)` — the `game_params *` for a
    leaf preset.
  - `preset_menu_lookup_by_id(menu, id)` → `game_params *`
  - `midend_which_preset(me)`
- `midend_get_config(me, which, char **wintitle)` → `config_item *cfg`
  (terminated by an entry of type `C_END`, see `puzzles.h`'s `C_STRING` /
  `C_CHOICES` / `C_BOOLEAN` / `C_END` enum). Walk it with:
  - `wasmmid_config_item_type(cfg, i)`, `_name`, `_kw`
  - `C_STRING`: `wasmmid_config_item_string_value(cfg, i)` /
    `wasmmid_config_item_set_string(cfg, i, value)`
  - `C_BOOLEAN`: `wasmmid_config_item_bool_value(cfg, i)` /
    `wasmmid_config_item_set_bool(cfg, i, value)`
  - `C_CHOICES`: `wasmmid_config_item_choices(cfg, i)` — a delimited string
    whose first character is the delimiter (e.g. `":Foo:Bar:Baz"` → `Foo`,
    `Bar`, `Baz`), `wasmmid_config_item_choice_selected(cfg, i)` /
    `wasmmid_config_item_set_choice(cfg, i, index)`
  - `midend_set_config(me, which, cfg)` to apply, then `free_cfg(cfg)`
- `midend_request_keys(me, int *nkeys)` → `key_label *`. Walk it with
  `wasmmid_key_label_text(keys, i)` (may be NULL — use
  `midend_current_key_label` instead for a generated one) and
  `wasmmid_key_label_button(keys, i)`; free with `free_keys(keys, nkeys)`.
- `midend_current_key_label(me, button)`

### Game accessors

`midend_which_game(me)` (and, in the combined module, `wasmmid_game_at`)
return `const game *`. Its fields are read with:

- `wasmmid_game_name(g)`
- `wasmmid_game_can_solve(g)`
- `wasmmid_game_can_configure(g)`
- `wasmmid_game_can_format_as_text_ever(g)`

### Change notification

- `wasmmid_midend_request_id_changes(me)` — arranges for the
  `wasmmid_ids_changed()` import to be called whenever the game ID/seed
  changes on their own initiative (e.g. Mines superseding its description
  after the first click). There's no per-call context parameter: register
  once per midend.

### Save/load and preferences

Rather than the callback-based `midend_serialise`/`midend_deserialise`/
`midend_load_prefs`/`midend_save_prefs`, use these buffer-based wrappers —
the host already has `malloc`/`free` as exports, so it can own the memory
directly instead of a callback round-trip:

- `wasmmid_serialise(me, int *outlen)` → `char *` (not NUL-terminated; length
  is `*outlen`). Free with `free`.
- `wasmmid_deserialise(me, const char *buf, int len)` → error string, or
  NULL on success.
- `wasmmid_save_prefs(me, int *outlen)` / `wasmmid_load_prefs(me, buf, len)`
  — same shapes, for preferences instead of a full save file.
- `wasmmid_identify_game(char **name, const char *buf, int len)` — wraps
  `identify_game()`, to sniff a buffer's game type before deserialising it.

## Imports

A front end must provide all of these (there is no default implementation —
the module will fail to instantiate without them).

Timing and colour:

- `wasmmid_activate_timer()` / `wasmmid_deactivate_timer()` — start/stop
  calling `midend_timer()` at a roughly-20Hz cadence while active.
- `wasmmid_default_colour(float *output)` — write an RGB triple (0..1) for
  the UI's background colour into `output`.
- `wasmmid_get_date_64(unsigned *p)` — write two `unsigned`s (any
  high-entropy value, conventionally the current time) into `p`, used to
  seed a fresh puzzle's RNG.

Errors and (debug builds only) logging:

- `wasmmid_fatal_error(const char *message)` — called for unrecoverable
  errors (e.g. allocation failure); should report the message and stop.
- `wasmmid_debug(const char *message)` — only imported when the module was
  built with `DEBUGGING` defined.

Change notification:

- `wasmmid_ids_changed()` — see "Change notification" above.

Drawing (the `drawing_api` from `puzzles.h`, forwarded 1:1 — see that header
for exact parameter semantics):

- `wasmmid_draw_text`, `wasmmid_draw_rect`, `wasmmid_draw_line`,
  `wasmmid_draw_thick_line`, `wasmmid_draw_polygon`, `wasmmid_draw_circle`
- `wasmmid_draw_update`, `wasmmid_clip`, `wasmmid_unclip`,
  `wasmmid_start_draw`, `wasmmid_end_draw`, `wasmmid_status_bar`
- `wasmmid_blitter_new`, `wasmmid_blitter_free`, `wasmmid_blitter_save`,
  `wasmmid_blitter_load`

Text fallback (used by games that can offer a text-only alternative
rendering) needs no import: the module answers it internally.

## Explicitly not covered

This module has no opinion on: resizing/DPI policy, input event
translation, menu/dialog UI, or a save-file's on-disk representation beyond
what `wasmmid_serialise`/`wasmmid_deserialise` already do. `emcc.c` (the
canvas-based front end) makes those decisions for its own UI; a new front
end built on this module makes its own.
