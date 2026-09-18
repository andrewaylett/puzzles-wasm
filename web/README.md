# A browser front end for the WASM midend

This is a second, independent front end for the mid-end-as-WASM interface
documented in [`../wasm-midend.md`](../wasm-midend.md) (built via the
`PUZZLES_WASM_MIDEND` CMake option) — a parallel to `emcc.c`'s canvas build,
written entirely in the browser instead of in C.

- `puzzle-midend.ts` is the authoritative source.
- `puzzle-midend.js` is its type-erased twin: the same code with the type
  annotations stripped, checked into the repo so the page below can be
  opened with **no build step** (no npm, no bundler, no dev server other
  than something to serve static files). If you edit one file, mirror the
  change into the other by hand — see the comment at the top of the `.ts`
  file for exactly what "erasable syntax" means here and why that keeps the
  two files a mechanical strip apart. If you have TypeScript installed,
  `tsc --target es2022 --module es2022 puzzle-midend.ts` should regenerate
  the `.js` (this wasn't verified against a real `tsc` when these files were
  written, since this sandbox didn't have one available — diff the output
  against the checked-in `.js` before trusting it).
- `puzzle-midend.html` is a working shell page: a toolbar (new/restart/
  undo/redo/solve/preferences/save/load, plus a preset-size menu and, for a
  combined module, a puzzle picker), a canvas, and a status bar.

## Running it

You need a `.wasm` file built with `-DPUZZLES_WASM_MIDEND=ON` (see
`../wasm-midend.md`). Either the combined `puzzles-midend.wasm` or a single
`<puzzle>-midend.wasm` works. Copy or symlink it next to
`puzzle-midend.html`, then serve this directory over HTTP — e.g.:

```sh
cd web
python3 -m http.server
```

and open `http://localhost:8000/puzzle-midend.html`. Opening the HTML file
directly (`file://`) will not work: browsers block `fetch()` of local files
from a `file://` page, and this library fetches the `.wasm` rather than
inlining it. Serving it statically is otherwise the whole story — there is
no build step, no dependency install, nothing to compile.

By default the page loads `puzzles-midend.wasm`. Override with query
parameters: `?wasm=net-midend.wasm` for a single-puzzle module, or
`?wasm=puzzles-midend.wasm&game=3` to jump straight to a particular game in
the combined module (indices come from `wasmmid_game_at`; the in-page
picker is easier than guessing one).

## Using the library directly

`mountPuzzle(container, wasmUrl, options)` is the convenience entry point
used above. For a custom UI, use the lower-level `Midend` class directly:
`Midend.load(wasmBytes, canvas, options)` gives you an object with methods
for every mid-end operation (`newGame`, `undo`, `getPresets`, `serialise`,
...); it draws to the canvas you gave it but builds no DOM of its own.
`Midend.probeGames(wasmBytes)` lists the games in a combined module without
creating one.

## Scope

This mirrors the bulk of `emcc.c`'s behaviour (drawing, input, presets,
custom-size and preferences dialogs, save/load, undo/redo) but not all of
it: permalinks, KaiOS soft-key labels, and text-mode rendering aren't
wired up. The raw WASM exports are still reachable via `midend.exports` and
`midend.me` if you want to build on those yourself.
