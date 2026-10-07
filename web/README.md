# A browser front end for the WASM midend

This is a second, independent front end for the mid-end-as-WASM interface
documented in [`../wasm-midend.md`](../wasm-midend.md) (built via the
`PUZZLES_WASM_MIDEND` CMake option, on by default for an Emscripten
configure) — a parallel to `emcc.c`'s canvas build, written entirely in the
browser instead of in C.

- `puzzle-midend.ts` is the only source: the library, in TypeScript.
- `puzzle-midend.css` is the shared stylesheet for the generated pages
  (toolbar, canvas, status bar, dialogs, light/dark theming).
- `genpages.pl` generates the static site: one HTML page per puzzle (each
  loading that puzzle's own `<name>-midend.wasm`, so there's no in-page
  picker to wire up) plus an `index.html` linking to all of them — the
  WASM-mid-end equivalent of the classic per-puzzle pages under `../html/`.

There is no checked-in build output here: `puzzle-midend.js` is compiled
from `puzzle-midend.ts` by `tsc` as part of the CMake build, not
hand-maintained, and the per-puzzle `.html`/`.wasm` files are generated
into the build directory, not this one.

## Building the site

Configure with Emscripten and build normally — `PUZZLES_WASM_MIDEND`
defaults on, so a single `cmake --build` produces the whole site:

```sh
emcmake cmake -S . -B cmake-build-wasm
cmake --build cmake-build-wasm
```

This needs the TypeScript compiler (`tsc`) on `PATH` — configure fails
with a clear message if it isn't found. Install one with e.g.
`npm install -g typescript`, or point CMake at a specific binary with
`-DTSC=/path/to/tsc`. If you don't want the web front end at all (e.g.
building only the KaiOS canvas pages), configure with
`-DPUZZLES_WASM_MIDEND=OFF` to skip both the WASM mid-end modules and this
requirement.

The result is `cmake-build-wasm/web/`: `index.html`, one `<name>.html` plus
`<name>-midend.wasm` per puzzle, the shared `puzzle-midend.js`/`.css`, and
(when `halibut` was found, so the built-in documentation could be built)
a `help/` directory the pages link to. That directory is self-contained
and relative-linked — copy it as-is to a web server, or serve it locally
to try it out:

```sh
cd cmake-build-wasm/web
python3 -m http.server
```

and open `http://localhost:8000/`. Opening a page directly (`file://`)
will not work: browsers block `fetch()` of local files from a `file://`
page, and this library fetches each `.wasm` rather than inlining it.

## Stylus input

Pointer events with `pointerType === "pen"` are sent with `MOD_STYLUS`, so
games that declare `STYLUS_SUPPORT` (currently Palisade, Loopy and Light Up)
can offer a one-button alternative to right-click.

## Using the library directly

For a custom UI (not the generated pages above), `mountPuzzle(container,
wasmUrl, options)` is the convenience entry point `genpages.pl`'s pages
call: point it at a single-puzzle `<name>-midend.wasm` and it builds a
whole toolbar/canvas/status-bar UI into `container`. It also accepts a
combined `puzzles-midend.wasm` (built by the same CMake option, covering
every puzzle in one module) — passed a combined module, it adds an
in-page game picker.

For lower-level access, use the `Midend` class directly:
`Midend.load(wasmBytes, canvas, options)` gives you an object with methods
for every mid-end operation (`newGame`, `undo`, `getPresets`, `serialise`,
...); it draws to the canvas you gave it but builds no DOM of its own.
`Midend.probeGames(wasmBytes)` lists the games in a combined module without
creating one.

## Scope

This mirrors the bulk of `emcc.c`'s behaviour (drawing, input, presets,
custom-size and preferences dialogs, save/load, undo/redo) but not all of
it: permalinks and KaiOS soft-key labels aren't wired up. The raw WASM
exports are still reachable via `midend.exports` and `midend.me` if you
want to build on those yourself.
