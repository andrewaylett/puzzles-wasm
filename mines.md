# mines.c orientation notes

Working notes on how `mines.c` (Simon Tatham's Minesweeper clone, extended
with many non-square grids) fits together, for anyone about to add features.
~5800 lines, one file, organised in clearly-marked sections (search for the
`/* ---...--- */` banner comments).

## The big picture

Everything in this puzzle collection is grid-agnostic: mines.c doesn't just
support a square grid, it supports ~20 tilings (`GRIDLIST` macro near the
top, line 111) via the shared `grid.h`/`grid.c` infrastructure. Internally
every tile is just an index `0..ntiles-1`; only the square grid gets special
`(x,y)` treatment for encoding moves and game IDs (for backwards
compatibility with old save files). This "square is special-cased, everything
else is generic tile-index" pattern shows up repeatedly — e.g. in
`interpret_move`/`execute_move` — and is the main thing to keep in mind if a
new feature needs to touch move encoding.

## Data structures

- `game_params` (line 156): width/height, mine count (absolute or a
  proportion of eligible cells, see `MINES_PROPORTION_*`), grid `type`,
  `unique` (whether generation must guarantee a unique deduction path), and
  `first_click_tile` (for non-interactive/testing generation).
- `struct grid_info` (line 246): the shared, refcounted, immutable
  description of the chosen tiling — wraps the generic `grid` from grid.c,
  plus a flattened `neighbours` array (`neighbours[tile*nsize + j]`, `-1`
  padded), tile geometry for drawing (`tiles`, `rims`), and optional cursor
  navigation arrays (`cursor_up/down/left/right`) used for keyboard play.
  Built once by `new_grid` (line 763) and shared across all `game_state`s of
  one puzzle instance.
- `struct mine_layout` (line 174): the actual mine positions, also
  refcounted/shared. Notably it can be *unpopulated* (`mines == NULL`) — the
  real layout isn't generated until the first click, so that click is always
  safe. If not yet generated, this struct instead carries the RNG state and
  the params needed to lazily generate it in `open_square` (line 3693).
- `struct game_state` (line 199): per-move state — `board[]` holds what the
  player has revealed. Values: `0..MAX_NEIGHBOURS` = opened with that mine
  count, `-1` = flagged, `-2` = unknown/covered, `-3` = question-marked
  (see the FIXME — not actually wired up), `64/65/66` = post-death reveal
  states (exploded mine, the fatal mine, incorrectly-flagged square).
- `struct game_ui` (line 4102): transient UI-only state — mouse-down
  highlight tile, cursor position/visibility, death count, the
  `highlight_flags` preference.
- `struct game_drawstate` (line 4216) / `tile_info` / `rim_info`: cached
  screen geometry for drawing.

## Move lifecycle (where UI features usually go)

1. `interpret_move` (line 4299) turns a mouse/keyboard event into a move
   string. It does *not* mutate `from` — it only inspects state and updates
   `game_ui`. Move string formats: `Fx,y`/`Ftile` (toggle flag), `Ox,y`/
   `Otile` (open a square), `Cx,y`/`Ctile` (chord — open all covered
   neighbours because the flag count already matches the number), or
   multiple `O` moves joined by `;` (used for the "you flagged the wrong
   square, here's what actually gets exposed" case), or `"S"` (solve).
2. `execute_move` (line 4499) parses the move string and applies it via
   `open_square` (line 3693), which does the flood-fill of zero-count tiles
   and checks the win condition.
3. `open_square` is also where lazy generation happens: on the very first
   open, it calls `new_mine_layout` → `minegen` (line 3165) with the clicked
   tile as the guaranteed-safe start, then calls
   `midend_supersede_game_desc` so the game ID becomes reproducible/saveable.

If you're adding a new kind of player action (e.g. a new gesture, a
"mark uncertain" toggle, auto-chord-on-hover, etc.), this is the trio to
touch: `game_ui` for transient UI state, `interpret_move` for turning input
into a move string, `execute_move` for applying it. Keep the square-grid
`x,y` special case in sync with the generic tile-index case in both
functions.

## Generation & the solver

- `minegen` (line 3165) places `n` mines randomly (excluding the start tile
  and its neighbours), then — if `unique` is requested — repeatedly runs the
  solver (`minesolve`) against a fresh empty board seeded only with the
  start tile. If the solver can't fully resolve the board, `mineperturb`
  (line 2761) shuffles mines around the ambiguous region and it retries.
  Gives up and starts over if perturbation isn't making progress.
- `minesolve` (line 1973) is a constraint solver over "sets": each opened
  numbered tile becomes a `struct set` (line 1495) of its covered neighbours
  plus a mine count. The `setstore` (line 1504) does subset/overlap analysis
  (`setwings`, `ss_overlap`) to deduce forced mines/safe squares — classic
  minesweeper set-subtraction logic, plus a todo-list-driven event loop
  (`std`/`squaretodo`) so newly-deduced squares get reprocessed. This is
  the good/bad-guess-free "logic solver" that both drives `unique` layout
  generation and (via `execute_move`'s `"S"` case, separately, just revealing
  the board) backs the Solve button — note **Solve doesn't call the actual
  solver**, it just reveals the known layout; there's no in-game hint system.
- `describe_layout`/`new_game_desc`/`validate_desc` (lines 3309/3420/3554)
  handle serialising a layout into the game ID string (with an "obfuscated"
  bitmap form so casual save-scumming doesn't trivially reveal mines, plus a
  plaintext form for descriptions typed in by hand).

## Grid geometry & drawing

- `new_grid` (line 763) builds `grid_info` from the generic `grid.c` tiling,
  computing neighbours (`update_neighbours`, line 293) and, where supported,
  cursor-movement adjacency (`update_cursor`, line 522).
- Drawing is tile-by-tile: `draw_tile` (line 4960) is the big one (numbers,
  flags, mines, cross-outs, highlight bevels). `game_redraw` (line 5383)
  walks the board and calls it, plus draws the "wrapping" arrows
  (`draw_horizontal_arrow`/`draw_vertical_arrow`, ~line 5354) for the
  cyclic grid variants (`IS_CYCLIC`, line 107) — this is the most recently
  touched area per git log (wrapping-grid indicator arrows).
- Colours: `game_colours` (line 4666); note per-number colours
  `COL_1..COL_12` support the higher neighbour counts some exotic tilings
  need (`MAX_NEIGHBOURS` = 16, line 105).

## Adding a new grid type (documented in the file's own header comment,
line 1-34): extend `GRIDLIST`, wire up `update_neighbours`/`update_cursor`
if it needs non-trivial adjacency or cursor support, extend `IS_CYCLIC` if
it wraps, handle description-string generation in `new_game_desc`/
`validate_desc`, and check `MAX_EDGES`/`MAX_NEIGHBOURS` are still big enough.

## Implementation notes: two requested features

### Feature A — right-click "flag chord" (mirror of the existing open-chord)

The existing chord already lives in `interpret_move`, reached via the
`uncover:` label (line 4436) and set up from two entry points: the mouse path
(`LEFT_RELEASE`/`MIDDLE_RELEASE`, line 4398 → `goto uncover`) and the keyboard
path (`CURSOR_SELECT`, line 4313 → `goto uncover`). Its logic: count flagged
(`-1`) neighbours of the clicked numbered tile; if that count equals the
tile's mine count, every *other* covered neighbour must be safe, so emit an
"open" move for each of them (as one `O...;O...` string, or a single `C...`
shorthand that `execute_move` expands — see lines 4444–4492).

The new feature is the exact dual: count *all covered* neighbours (`board <
0`, i.e. `-1` flagged + `-2` unknown — not `-3`, see below) of a clicked
numbered tile; if that count equals the tile's mine count, every one of
those covered squares must be a mine, so flag the ones not already flagged.

Two places currently block this:

- `RIGHT_BUTTON` handling (line 4371–4396) exits early with `MOVE_NO_EFFECT`
  whenever `from->board[ctile]` isn't `-1` or `-2`, i.e. it never fires on an
  opened numbered tile. This needs a new branch for `board[ctile] > 0`.
- `CURSOR_SELECT2` (line 4320–4329, the keyboard equivalent of right-click)
  has the identical restriction (`if (v != -2 && v != -1) return
  MOVE_NO_EFFECT;`) and needs the same new branch.

Recommend factoring a single helper, e.g.
`static char *flag_chord_move(const game_state *from, const game_drawstate *ds, int ctile)`,
called from both sites, that:

1. Returns `NULL`/`MOVE_NO_EFFECT` unless `from->board[ctile] > 0`.
2. Walks `ds->grid->neighbours[ctile*nsize + j]`, counting neighbours with
   `board < 0`.
3. If that count != `board[ctile]`, no effect.
4. Otherwise, builds a `;`-separated list of `F` moves — one per neighbour
   with `board == -2` (i.e. covered-and-unflagged) — using the same
   `sprintf` pattern already used for multi-tile moves (see the `O...;O...`
   construction at lines 4465–4489, and the `x,y` vs. tile-index branching
   used throughout for `MINES_GRID_SQUARE` vs. everything else).

The nice part: **no change to `execute_move` or the move-string grammar is
needed**. `F` already toggles `-2 → -1` per tile, and `execute_move` already
splits `;`-joined moves and applies each independently (line 4558 onward),
so multiple `F` tokens Just Work — this mirrors how the existing feature
reuses `O` rather than inventing a new "open all" opcode.

Design decisions to make explicit (the user's phrasing doesn't fully pin
these down):

- **Question-marked (`-3`) neighbours**: the existing single right-click
  can only flag `-2`/`-1` tiles (line 4387), so for consistency, exclude
  `-3` from both the trigger count and the target list, or explicitly
  decide to extend `-3` support in the same change. Given `-3` is
  documented as not really wired up (see the FIXME at the top of the file
  and in `struct game_state`), excluding it is the path of least surprise.
- **No-op when already fully flagged**: if the covered count matches but
  every covered neighbour is already `-1`, there's nothing to flag — the
  helper should notice zero `-2` targets and return no-effect rather than
  emitting an empty move string.
- Should this apply on **mouse-down** (immediate, like the existing
  right-click flag toggle) or require a release/drag step like the left
  chord does? The existing right-click flagging acts instantly on
  `RIGHT_BUTTON` with no highlight phase, so the natural, lower-effort
  choice is to make the new behaviour act instantly too — no new
  `ui->htile`/`ui->hneighbour` drag-highlight state needed.

### Feature B — "no-guessing" mode (opening an undetermined square is fatal)

This is a bigger change: a new game-rule toggle, plus a genuinely new piece
of solving logic that has to run *during play* against the *player's*
partial knowledge, not the generator's full-knowledge solver.

**Wiring the new mode into `game_params`** — mirror the existing `unique`
flag end-to-end (it's the closest analogue: a boolean gameplay-affecting
param, not a board-size param):

- `struct game_params` (line 156): add e.g. `bool no_guessing;`.
- `decode_params`/`encode_params` (lines 1131, 1192): add a letter flag,
  e.g. `'g'`, following the pattern used for `'a'` (`unique`, note that one
  is inverted — letter present means "not unique" — pick whichever polarity
  reads better for the new flag; letter-present-means-enabled is more usual
  and matches `'a'`'s sibling flags `X`/`Y`/`I`).
- `game_configure`/`custom_params` (lines 1231, 1273): add a `C_BOOLEAN`
  entry alongside "Ensure solubility".
- `validate_params` (line 1295): probably no new constraint, but worth
  reading through — it's a good place to note the interaction with
  `unique` below.
- `dup_params` (line 1124): trivial field copy.

**The `unique`/`no_guessing` interaction is a real design question, not just
plumbing.** `unique` only guarantees the *final* board is deducible in
principle by repeatedly opening logically-forced-safe squares from the
start tile — it does not guarantee every square is forced at every
intermediate point in a *human's* particular play order (e.g. a human might
have opened tiles in a different order than the solver would, leaving a
patch that's locally ambiguous but which the solver would have resolved via
a different route, or there may be remaining 50/50s in areas the solver
proved safe indirectly through the *global* mine count, e.g. "all remaining
mines are already accounted for elsewhere" — a piece of reasoning that
needs the mine total, not just adjacency). Decide (and note in the UI copy)
whether `no_guessing` should imply/force `unique`, and whether the
per-square oracle below needs to reason about the total mine count, not
just local adjacency, to match player expectations.

**Reframe the core question as existence, not derivation.** The naive plan
("port `minesolve`'s subset-elimination machinery to run without an
`open_cb`") is *sound* but *incomplete*: subset elimination only catches
deductions expressible as one derived set being a subset of another. It's
what `unique` generation uses, so it'll agree with the generator most of the
time, but it will occasionally call a genuinely forced-safe square
"undetermined" (a well-known limitation of pure subset-elimination Minesweeper
solvers). The question the feature actually wants answered is sharper and
simpler to *state*: **is there a mine arrangement consistent with every
opened number on screen that places a mine on the clicked tile?** If no such
arrangement exists, the tile is forced safe and opening it is fine. If one
exists *and* an arrangement without a mine there also exists, the click is a
genuine guess. This existence framing is complete by construction — it's not
approximating the deduction, it's asking the real question. The important
scoping decision is *what to check existence over*: not the whole board (an
`ntiles`-wide layout `mines[]` array with a `-1`/branch-point per tile would
be a huge combined state space, essentially rebuilding a SAT solver over the
whole grid) but only the *frontier* — the connected component of covered
tiles adjacent to at least one opened number, restricted further to the
component the clicked tile is actually part of. That component is normally
small even on a large board, so a straightforward backtracking search over
"place remaining mines in the component's covered tiles, check every opened
number in the component's boundary is satisfied" is tractable, and is
close in spirit to what `mineperturb` (line 2761) already does when it
hunts for an alternative consistent mine placement during generation — the
new routine can likely share its region-finding logic even though its exit
condition is different (`mineperturb` wants *any* valid perturbation that
avoids a specific set of cells; this wants to know whether *any* valid
completion touches the clicked cell, and whether *any* valid completion
avoids it).

Recommended two-tier implementation, since the two techniques have very
different cost profiles:

1. **Fast path — subset elimination.** Build `set`/`setstore` constraints
   (line 1495/1504) from the currently *opened* numbered tiles and their
   covered neighbours (same shape as `minesolve`'s per-tile set
   construction, lines 2020–2048), run `ss_add`/`ss_check_uniq`/`setwings`/
   `ss_overlap` to a fixed point, and check whether the target tile is
   forced to `0` or `1` by some singleton/derived set. Cheap, and resolves
   the large majority of clicks (anything the `unique` generator itself
   could have resolved this way).
2. **Fallback — frontier existence search.** Only invoked when step 1
   returns "undetermined". Take the clicked tile's connected frontier
   component and backtrack over mine/no-mine assignments to its covered
   tiles, checking each opened boundary number's count as constraints are
   filled in (prune as soon as a partial assignment violates a count, same
   idea as `mineperturb`'s region search). Determine reachability of "mine
   at the clicked tile" and "no mine at the clicked tile" separately (two
   searches, or one search that tracks whether each has been witnessed and
   stops early once both have). This is worst-case exponential in the
   frontier component's size, but that component is normally small; a
   depth/node cap with "if the search doesn't resolve, be conservative"
   is worth having as a safety valve for pathological grids.

No `open_cb` and no full-board `mineperturb` run is involved in either
tier — this is strictly new code, not a `minesolve` flag, since the
contracts differ throughout (oracle-driven vs. one-shot, whole-board vs.
single-tile-existence question).

**Correctness trap: do not trust the player's flags as ground truth.**
The player can flag a safe square as a mine by mistake. If the new
routine's constraint-set construction treats `board[i] == -1` as "known
mine" (the way `minesolve`'s *internal* solving board does — but there,
`-1` only ever comes from the solver's own sound deductions, never from
outside input), a wrong flag would silently corrupt every deduction near
it, and the game could kill the player for a "guess" that was actually
forced-safe, or wave through a genuine guess as "safe". The routine must
either (a) ignore `-1`/flag state entirely and treat flagged tiles the same
as unknown/covered for constraint purposes (safest, simplest — flags become
purely a player memory aid, exactly as real Minesweeper treats them for
scoring purposes), or (b) if flags are to count as evidence, first confirm
each flag is *itself* one of the tiles the deduction independently proves
must be a mine before relying on it — which is circular unless done
carefully. (a) is much simpler and is what's recommended.

**Where to hook the check in, and the first-click exemption.**
`interpret_move` (line 4299) is the right place — it's already read-only
with respect to `from`, and both single-tile-open code paths converge on
building an `"O..."` move string (`LEFT_RELEASE`, lines 4418–4431, and
`CURSOR_SELECT`, lines 4330–4341). Before emitting that move, when
`params->no_guessing` is set, call the new routine on `ctile`. Crucially,
**the very first click of the game must always be exempted**, regardless of
what the routine says — at that point zero constraints exist, so the
routine will (correctly) report "undetermined" for every tile, but the
generator (`minegen`, line 3165) guarantees the start tile and its
neighbours are mine-free by construction (lines 3182–3196). Detect "this is
the first click" via `!from->layout->mines` (mine layout not yet generated,
line 3698) — that's the existing signal `open_square` itself uses for the
same purpose.

**What "undetermined → death" should actually mean for chords.** The
existing chord path (`goto uncover`, opening via `'C'`) already has its own
well-defined safety story: it only ever opens tiles once the surrounding
flag count matches the mine count, and if the flags turn out to be wrong it
already triggers an ordinary death by opening the real mine (lines
4457–4489). Recommend explicitly exempting chord-triggered opens from the
new "ambiguous → death" check — otherwise you'd need to decide what
"ambiguous" even means for a multi-tile open, and it's not what the
feature request is asking for.

**No new terminal state — reuse the existing mine-hit death exactly.**
Explicit design requirement: a no-guessing death must be *indistinguishable*
from opening an actual mine (`65`, `COL_BANG`). Don't tell the player "this
mode killed you for guessing" — that would reveal information (namely, that
the specific tile they clicked was actually safe, since a real mine hit
wouldn't need that distinction). Concretely: when the fallback existence
search proves both "mine here" and "no mine here" are reachable — i.e. a
genuine guess — the implementation shouldn't reveal whether the clicked tile
in the *real* underlying layout happens to hold a mine or not; it should
treat the click as if it were a mine hit regardless, using the exact same
`64`/`65`/`66` machinery `execute_move`/`open_square` already have for a
real mine (lines 3746–3754), same `draw_tile`/`COL_BANG` styling, same
`game_text_format` character. No new sentinel value, no new move token, no
new colour. This also sidesteps a subtler problem: if the death *did* show
the clicked tile's true content, a player could infer "no-guessing killed me
here" vs "I hit a real mine here" from appearance alone even without a
dedicated colour, which defeats the point.

The one piece of new logic is entirely on the *decision* side, not the
*rendering* side: `interpret_move`/`execute_move` need to decide to trigger
death at all (per the existence check above) — once that decision is made,
route it through the same death path a real mine click already takes,
rather than inventing a parallel one.

**Converse "assist" mode — ambiguous squares are never mines.** Worth
scoping alongside `no_guessing` since it's the same underlying routine
consumed the opposite way: instead of killing the player on an ambiguous
click, this mode would make ambiguous squares *safe by fiat* — i.e. treat
"undetermined" the same as "forced safe" for the purposes of what happens
when the player opens it. This only works if the *generator* cooperates:
either the mine that would have been on that tile has to be relocated
(another `mineperturb`-shaped operation, now happening live during play
rather than at generation time, which is a much bigger change since
`mine_layout` is meant to be immutable/shared once generated — see the
`refcounted` note above), or generation has to lean much harder on `unique`
so genuine ambiguity is rare enough that always-resolving-safe doesn't
noticeably change the puzzle's difficulty. Recommend treating this as a
separate, later feature rather than a flag on Feature B: it needs a design
decision about *when* the relocation happens (at click time? does the
display then need to retroactively update numbers that were already shown,
since a moved mine can change a previously-opened tile's count — which
would be jarring/inconsistent) that `no_guessing` doesn't have to make,
since `no_guessing` never touches the layout, only the death decision.

## Known gaps / FIXMEs worth knowing about

- Question marks (`-3`) are a recognised board value but there's no UI path
  to set one (see FIXME at line 6 and line 3385 area) — flagged as
  deliberately unimplemented, not broken.
- `open_square`'s flood fill is an explicit "FIXME: N^2 scans" (line 3768) —
  fine at current grid sizes, but a hazard if you're adding much bigger
  grids.
- Solve (`"S"` move) doesn't run the logic solver at all — it just paints in
  the known truth. Anything like "give me a hint" would need to actually
  invoke `minesolve` on the live board and translate a found deduction into
  something the UI can highlight — no existing scaffolding for that.
