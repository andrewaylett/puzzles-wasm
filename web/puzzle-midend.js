/*
 * puzzle-midend.js: a browser front end for the wasmmidend.c WASM
 * modules (see ../wasm-midend.md for the interface those modules
 * expose). This plays the same role emccpre.js/emcclib.js play for
 * the canvas build, but talks to the mid-end's own exports directly
 * instead of Emscripten's JS-library glue, and needs no build step:
 * load it as a plain <script type="module"> from a static file.
 *
 * This file is the type-erased twin of puzzle-midend.ts, which is
 * the authoritative source (kept deliberately restricted to
 * "erasable" TypeScript - no enums, no parameter properties - so the
 * two stay a mechanical strip apart). If you edit one, mirror the
 * change into the other; there is no build step wiring them together
 * in this repository.
 */

/* ----------------------------------------------------------------------
 * Constants mirrored from puzzles.h. Plain objects rather than TS
 * enums, since enums aren't erasable syntax.
 */
export const Button = {
  LEFT_BUTTON: 0x0200,
  MIDDLE_BUTTON: 0x0201,
  RIGHT_BUTTON: 0x0202,
  LEFT_DRAG: 0x0203,
  MIDDLE_DRAG: 0x0204,
  RIGHT_DRAG: 0x0205,
  LEFT_RELEASE: 0x0206,
  MIDDLE_RELEASE: 0x0207,
  RIGHT_RELEASE: 0x0208,
  CURSOR_UP: 0x0209,
  CURSOR_DOWN: 0x020a,
  CURSOR_LEFT: 0x020b,
  CURSOR_RIGHT: 0x020c,
  CURSOR_SELECT: 0x020d,
  CURSOR_SELECT2: 0x020e,
  UI_NEWGAME: 0x0211,
  UI_UNDO: 0x0213,
  UI_REDO: 0x0214,
  MOD_CTRL: 0x1000,
  MOD_SHFT: 0x2000,
  MOD_NUM_KEYPAD: 0x4000,
};

export const ConfigType = { STRING: 0, CHOICES: 1, BOOLEAN: 2, END: 3 };
export const ConfigWhich = { SETTINGS: 0, SEED: 1, DESC: 2, PREFS: 3 };
export const KeyResult = { QUIT: 0, SOME_EFFECT: 1, NO_EFFECT: 2, UNUSED: 3 };

const ALIGN_VCENTRE = 0x100;
const ALIGN_HCENTRE = 0x001;
const ALIGN_HRIGHT = 0x002;
const FONT_FIXED = 0;

/* ----------------------------------------------------------------------
 * Dark-mode colour handling. The puzzle's own default background
 * (colour index 0) is already themed, via wasmmid_default_colour
 * reading the page's CSS. But every other colour the puzzle asks for
 * is a hard-coded light-mode RGB triple baked into the C code, which
 * looks harsh against a dark background. Rather than maintain a
 * per-game palette, we invert just the lightness of each such colour
 * in Oklab space (Björn Ottosson's perceptual colour space), which
 * flips light greys to dark greys and vice versa while leaving hue
 * and chroma - and so each colour's identity - intact.
 */
function srgbToLinear(c) {
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}
function linearToSrgb(c) {
  return c <= 0.0031308 ? c * 12.92 : 1.055 * c ** (1 / 2.4) - 0.055;
}
function clamp01(c) {
  return Math.min(1, Math.max(0, c));
}

function invertOklabLightness(r, g, b) {
  const lr = srgbToLinear(r);
  const lg = srgbToLinear(g);
  const lb = srgbToLinear(b);

  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);

  const L = 1 - (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s);
  const a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  const bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;

  const l2 = L + 0.3963377774 * a + 0.2158037573 * bb;
  const m2 = L - 0.1055613458 * a - 0.0638541728 * bb;
  const s2 = L - 0.0894841775 * a - 1.2914855480 * bb;

  const l3 = l2 * l2 * l2;
  const m3 = m2 * m2 * m2;
  const s3 = s2 * s2 * s2;

  const outR = clamp01(linearToSrgb(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3));
  const outG = clamp01(linearToSrgb(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3));
  const outB = clamp01(linearToSrgb(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3));

  return [outR, outG, outB];
}

function prefersDarkMode() {
  const theme = document.documentElement.dataset.theme;
  if (theme === "dark") return true;
  if (theme === "light") return false;
  return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
}

/* ----------------------------------------------------------------------
 * The UI's light/dark override (as opposed to the above, which is what
 * actually gets rendered once the browser's own preference is folded
 * in). "system" means "no override": document.documentElement's
 * [data-theme] is left unset, so puzzle-midend.html's CSS falls
 * through to its prefers-color-scheme media query.
 */
const THEME_STORAGE_KEY = "puzzle-midend-theme";

function getThemePreference() {
  const stored = localStorage.getItem(THEME_STORAGE_KEY);
  return stored === "light" || stored === "dark" ? stored : "system";
}

function setThemePreference(theme) {
  localStorage.setItem(THEME_STORAGE_KEY, theme);
  if (theme === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = theme;
}

/* ----------------------------------------------------------------------
 * Minimal WASI shim. These modules are WASI *reactors*, not commands:
 * wasmmidend.c deliberately has no main(), so Emscripten exports
 * _initialize (called once, below) instead of _start, runs global
 * constructors, and returns normally rather than calling proc_exit -
 * the module is meant to keep running and answering exports
 * indefinitely. We still have to satisfy the wasi_snapshot_preview1
 * imports libc pulls in regardless (a stray stdio write from an
 * unexpected assert should land somewhere visible rather than fail to
 * link), but proc_exit itself should never actually be called; if it
 * is, something has aborted and that's a real error.
 */
function makeWasiImports(getMemory, onStderr) {
  function iovsToString(iovsPtr, iovsLen) {
    const dv = new DataView(getMemory().buffer);
    const bytes = [];
    for (let i = 0; i < iovsLen; i++) {
      const base = iovsPtr + i * 8;
      const ptr = dv.getUint32(base, true);
      const len = dv.getUint32(base + 4, true);
      bytes.push(new Uint8Array(getMemory().buffer, ptr, len));
    }
    let total = 0;
    for (const b of bytes) total += b.length;
    return { total, bytes };
  }

  return {
    proc_exit(code) {
      throw new Error(`puzzle module unexpectedly called proc_exit(${code})`);
    },
    environ_sizes_get(countPtr, sizePtr) {
      const dv = new DataView(getMemory().buffer);
      dv.setUint32(countPtr, 0, true);
      dv.setUint32(sizePtr, 0, true);
      return 0;
    },
    environ_get(_environPtr, _environBufPtr) {
      return 0;
    },
    fd_close(_fd) {
      return 0;
    },
    fd_seek(_fd, _offset, _whence, newOffsetPtr) {
      const dv = new DataView(getMemory().buffer);
      dv.setBigUint64(newOffsetPtr, 0n, true);
      return 0;
    },
    fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
      const { total, bytes } = iovsToString(iovsPtr, iovsLen);
      if (fd === 1 || fd === 2) {
        const buf = new Uint8Array(total);
        let pos = 0;
        for (const b of bytes) {
          buf.set(b, pos);
          pos += b.length;
        }
        onStderr(new TextDecoder().decode(buf));
      }
      new DataView(getMemory().buffer).setUint32(nwrittenPtr, total, true);
      return 0;
    },
  };
}

/* ----------------------------------------------------------------------
 * One instantiated WASM module plus one live midend handle, bound to
 * a canvas and a small amount of surrounding UI it builds for itself.
 */
export class Midend {
  constructor() {
    this.instance = null;
    this.exports = null;
    this.combined = false;
    this.me = 0;

    this.canvas = null;
    this.offscreen = document.createElement("canvas");
    this.ctx = this.offscreen.getContext("2d", { alpha: false });
    this.colours = [];
    this.updateRect = null;

    this.blitters = new Map();
    this.nextBlitterId = 1;

    this.timerRunning = false;
    this.timerHandle = 0;
    this.timerLast = 0;

    this.statusBarEl = null;
    this.onFatalError = (message) => alert(message);
  }

  memBuffer() {
    return this.exports.memory.buffer;
  }
  u8() {
    return new Uint8Array(this.memBuffer());
  }
  dv() {
    return new DataView(this.memBuffer());
  }

  readCString(ptr) {
    if (ptr === 0) return null;
    const bytes = this.u8();
    let end = ptr;
    while (bytes[end] !== 0) end++;
    return new TextDecoder().decode(bytes.subarray(ptr, end));
  }

  writeCString(str) {
    const encoded = new TextEncoder().encode(str);
    const ptr = this.exports.malloc(encoded.length + 1);
    this.u8().set(encoded, ptr);
    this.u8()[ptr + encoded.length] = 0;
    return ptr;
  }

  mallocInt() {
    return this.exports.malloc(4);
  }
  readInt(ptr) {
    return this.dv().getInt32(ptr, true);
  }
  writeInt(ptr, value) {
    this.dv().setInt32(ptr, value, true);
  }

  /* --------------------------------------------------------------
   * Loading.
   */
  static async load(wasmBytes, canvas, options = {}) {
    const me = new Midend();
    me.canvas = canvas;
    me.statusBarEl = options.statusBar || null;
    if (options.onFatalError) me.onFatalError = options.onFatalError;

    const getMemory = () => me.exports.memory;

    const imports = {
      wasi_snapshot_preview1: makeWasiImports(getMemory, (text) =>
        console.error("[puzzle]", text),
      ),
      env: {
        emscripten_notify_memory_growth() {},
        wasmmid_fatal_error: (ptr) => me.onFatalError(me.readCString(ptr)),
        wasmmid_get_date_64: (ptr) => {
          const bytes = new Uint8Array(8);
          crypto.getRandomValues(bytes);
          me.u8().set(bytes, ptr);
        },
        wasmmid_default_colour: (ptr) => {
          const style = window.getComputedStyle(canvas).backgroundColor;
          const m = style.match(
            /^rgba?\((\d+(?:\.\d+)?), ?(\d+(?:\.\d+)?), ?(\d+(?:\.\d+)?)/,
          );
          if (m) {
            const dv = me.dv();
            dv.setFloat32(ptr, +m[1] / 255, true);
            dv.setFloat32(ptr + 4, +m[2] / 255, true);
            dv.setFloat32(ptr + 8, +m[3] / 255, true);
          }
        },
        wasmmid_activate_timer: () => me.startTimer(),
        wasmmid_deactivate_timer: () => me.stopTimer(),
        wasmmid_ids_changed: () => {
          if (options.onIdsChanged) options.onIdsChanged();
        },

        wasmmid_draw_text: (_dr, x, y, fonttype, fontsize, align, colour, textPtr) =>
          me.drawText(x, y, fonttype, fontsize, align, colour, me.readCString(textPtr)),
        wasmmid_draw_rect: (_dr, x, y, w, h, colour) => me.drawRect(x, y, w, h, colour),
        wasmmid_draw_line: (_dr, x1, y1, x2, y2, colour) =>
          me.drawLine(x1, y1, x2, y2, 1, colour),
        wasmmid_draw_polygon: (_dr, coordsPtr, npoints, fill, outline) =>
          me.drawPolygon(coordsPtr, npoints, fill, outline),
        wasmmid_draw_circle: (_dr, cx, cy, radius, fill, outline) =>
          me.drawCircle(cx, cy, radius, fill, outline),
        wasmmid_draw_update: (_dr, x, y, w, h) => me.markUpdate(x, y, w, h),
        wasmmid_clip: (_dr, x, y, w, h) => {
          me.ctx.save();
          me.ctx.beginPath();
          me.ctx.rect(x, y, w, h);
          me.ctx.clip();
        },
        wasmmid_unclip: () => me.ctx.restore(),
        wasmmid_start_draw: () => me.startDraw(),
        wasmmid_end_draw: () => me.endDraw(),
        wasmmid_status_bar: (_dr, textPtr) => {
          if (me.statusBarEl) me.statusBarEl.textContent = me.readCString(textPtr);
        },
        wasmmid_blitter_new: (_dr, w, h) => {
          const id = me.nextBlitterId++;
          const c = document.createElement("canvas");
          c.width = w;
          c.height = h;
          me.blitters.set(id, c);
          return id;
        },
        wasmmid_blitter_free: (_dr, bl) => me.blitters.delete(bl),
        wasmmid_blitter_save: (_dr, bl, x, y) =>
          me.blitters.get(bl).getContext("2d", { alpha: false }).drawImage(me.offscreen, -x, -y),
        wasmmid_blitter_load: (_dr, bl, x, y) =>
          me.ctx.drawImage(me.blitters.get(bl), x, y),
        wasmmid_draw_thick_line: (_dr, thickness, x1, y1, x2, y2, colour) =>
          me.drawLine(x1, y1, x2, y2, thickness, colour),
      },
    };

    const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
    me.instance = instance;
    me.exports = instance.exports;
    me.exports._initialize();
    me.combined = typeof me.exports.wasmmid_game_count === "function";

    const index = options.gameIndex || 0;
    me.me = me.combined ? me.exports.wasmmid_midend_new(index) : me.exports.wasmmid_midend_new();

    me.exports.wasmmid_midend_request_id_changes(me.me);
    me.exports.midend_new_game(me.me);
    return me;
  }

  /*
   * Instantiate a module just far enough to ask whether it's combined
   * (and if so, list its games), without creating a midend at all.
   * Used by mountPuzzle() to build a game picker before the user has
   * chosen a game. The instance is discarded afterwards.
   */
  static async probeGames(wasmBytes) {
    const noop = () => {};
    let exports;
    const getMemory = () => exports.memory;
    const { instance } = await WebAssembly.instantiate(wasmBytes, {
      wasi_snapshot_preview1: makeWasiImports(getMemory, noop),
      env: {
        emscripten_notify_memory_growth: noop,
        wasmmid_fatal_error: noop,
        wasmmid_get_date_64: noop,
        wasmmid_default_colour: noop,
        wasmmid_activate_timer: noop,
        wasmmid_deactivate_timer: noop,
        wasmmid_ids_changed: noop,
        wasmmid_draw_text: noop,
        wasmmid_draw_rect: noop,
        wasmmid_draw_line: noop,
        wasmmid_draw_polygon: noop,
        wasmmid_draw_circle: noop,
        wasmmid_draw_update: noop,
        wasmmid_clip: noop,
        wasmmid_unclip: noop,
        wasmmid_start_draw: noop,
        wasmmid_end_draw: noop,
        wasmmid_status_bar: noop,
        wasmmid_blitter_new: () => 0,
        wasmmid_blitter_free: noop,
        wasmmid_blitter_save: noop,
        wasmmid_blitter_load: noop,
        wasmmid_draw_thick_line: noop,
      },
    });
    exports = instance.exports;
    exports._initialize();
    if (typeof exports.wasmmid_game_count !== "function") return null;
    return Midend.listGames(exports);
  }

  static listGames(exports) {
    const count = exports.wasmmid_game_count();
    const games = [];
    for (let i = 0; i < count; i++) {
      const g = exports.wasmmid_game_at(i);
      games.push({
        index: i,
        name: readCStringFromExports(exports, exports.wasmmid_game_name(g)),
        canSolve: !!exports.wasmmid_game_can_solve(g),
        canConfigure: !!exports.wasmmid_game_can_configure(g),
      });
    }
    return games;
  }

  /* --------------------------------------------------------------
   * Drawing.
   */
  refreshColours() {
    const nPtr = this.mallocInt();
    const arr = this.exports.midend_colours(this.me, nPtr);
    const n = this.readInt(nPtr);
    this.exports.free(nPtr);
    const floats = new Float32Array(this.memBuffer(), arr, n * 3);
    const dark = prefersDarkMode();
    this.colours = [];
    for (let i = 0; i < n; i++) {
      let r = floats[i * 3];
      let g = floats[i * 3 + 1];
      let b = floats[i * 3 + 2];
      /* Colour 0 is the puzzle's background, already themed via
       * wasmmid_default_colour; every other colour is a fixed
       * light-mode RGB from the puzzle itself, so invert those. */
      if (dark && i !== 0) [r, g, b] = invertOklabLightness(r, g, b);
      this.colours.push(`rgb(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)})`);
    }
  }

  startDraw() {
    this.refreshColours();
    this.updateRect = null;
  }

  endDraw() {
    if (this.updateRect) {
      const { x, y, w, h } = this.updateRect;
      const onCtx = this.canvas.getContext("2d", { alpha: false });
      onCtx.drawImage(this.offscreen, x, y, w, h, x, y, w, h);
    }
  }

  markUpdate(x, y, w, h) {
    if (!this.updateRect) {
      this.updateRect = { x, y, w, h };
      return;
    }
    const r = this.updateRect;
    const x2 = Math.max(r.x + r.w, x + w);
    const y2 = Math.max(r.y + r.h, y + h);
    r.x = Math.min(r.x, x);
    r.y = Math.min(r.y, y);
    r.w = x2 - r.x;
    r.h = y2 - r.y;
  }

  drawRect(x, y, w, h, colour) {
    this.ctx.fillStyle = this.colours[colour];
    this.ctx.fillRect(x, y, w, h);
  }

  drawLine(x1, y1, x2, y2, width, colour) {
    const c = this.colours[colour];
    this.ctx.beginPath();
    this.ctx.moveTo(x1 + 0.5, y1 + 0.5);
    this.ctx.lineTo(x2 + 0.5, y2 + 0.5);
    this.ctx.lineWidth = width;
    this.ctx.lineCap = "round";
    this.ctx.lineJoin = "round";
    this.ctx.strokeStyle = c;
    this.ctx.stroke();
    this.ctx.fillStyle = c;
    this.ctx.fillRect(x1, y1, 1, 1);
    this.ctx.fillRect(x2, y2, 1, 1);
  }

  drawPolygon(coordsPtr, npoints, fill, outline) {
    const dv = this.dv();
    this.ctx.beginPath();
    this.ctx.moveTo(dv.getInt32(coordsPtr, true) + 0.5, dv.getInt32(coordsPtr + 4, true) + 0.5);
    for (let i = 1; i < npoints; i++) {
      this.ctx.lineTo(
        dv.getInt32(coordsPtr + 8 * i, true) + 0.5,
        dv.getInt32(coordsPtr + 8 * i + 4, true) + 0.5,
      );
    }
    this.ctx.closePath();
    if (fill >= 0) {
      this.ctx.fillStyle = this.colours[fill];
      this.ctx.fill();
    }
    this.ctx.lineWidth = 1;
    this.ctx.lineCap = "round";
    this.ctx.lineJoin = "round";
    this.ctx.strokeStyle = this.colours[outline];
    this.ctx.stroke();
  }

  drawCircle(cx, cy, r, fill, outline) {
    this.ctx.beginPath();
    this.ctx.arc(cx + 0.5, cy + 0.5, r, 0, 2 * Math.PI);
    if (fill >= 0) {
      this.ctx.fillStyle = this.colours[fill];
      this.ctx.fill();
    }
    this.ctx.lineWidth = 1;
    this.ctx.lineCap = "round";
    this.ctx.lineJoin = "round";
    this.ctx.strokeStyle = this.colours[outline];
    this.ctx.stroke();
  }

  drawText(x, y, fonttype, fontsize, align, colour, text) {
    this.ctx.font = `${fontsize}px ${fonttype === FONT_FIXED ? "monospace" : "sans-serif"}`;
    this.ctx.fillStyle = this.colours[colour];
    this.ctx.textAlign =
      align & ALIGN_HCENTRE ? "center" : align & ALIGN_HRIGHT ? "right" : "left";
    this.ctx.textBaseline = align & ALIGN_VCENTRE ? "middle" : "alphabetic";
    this.ctx.fillText(text, x, y);
  }

  /* --------------------------------------------------------------
   * Timer.
   */
  startTimer() {
    if (this.timerRunning) return;
    this.timerRunning = true;
    this.timerLast = performance.now();
    const frame = (now) => {
      if (!this.timerRunning) return;
      this.timerHandle = requestAnimationFrame(frame);
      const tplus = (now - this.timerLast) / 1000;
      this.timerLast = now;
      this.exports.midend_timer(this.me, tplus);
    };
    this.timerHandle = requestAnimationFrame(frame);
  }

  stopTimer() {
    this.timerRunning = false;
    cancelAnimationFrame(this.timerHandle);
  }

  /* --------------------------------------------------------------
   * Sizing.
   */
  resize(userSize = false) {
    const dpr = window.devicePixelRatio || 1;
    const cssW = this.canvas.parentElement.clientWidth;
    const cssH = this.canvas.parentElement.clientHeight;
    const xPtr = this.mallocInt();
    const yPtr = this.mallocInt();
    this.writeInt(xPtr, Math.max(1, Math.round(cssW * dpr)));
    this.writeInt(yPtr, Math.max(1, Math.round(cssH * dpr)));
    this.exports.midend_size(this.me, xPtr, yPtr, userSize ? 1 : 0, dpr);
    const w = this.readInt(xPtr);
    const h = this.readInt(yPtr);
    this.exports.free(xPtr);
    this.exports.free(yPtr);

    this.canvas.width = w;
    this.canvas.height = h;
    this.canvas.style.width = `${w / dpr}px`;
    this.canvas.style.height = `${h / dpr}px`;
    this.offscreen.width = w;
    this.offscreen.height = h;
    this.exports.midend_force_redraw(this.me);
  }

  forceRedraw() {
    this.exports.midend_force_redraw(this.me);
  }

  /* --------------------------------------------------------------
   * Input.
   */
  canvasCoords(event) {
    const rect = this.canvas.getBoundingClientRect();
    return {
      x: Math.round(((event.clientX - rect.left) * this.canvas.width) / rect.width),
      y: Math.round(((event.clientY - rect.top) * this.canvas.height) / rect.height),
    };
  }

  pointerButton(event, phase) {
    if (phase === "drag") {
      const buttons = event.buttons;
      return buttons & 2 ? Button.MIDDLE_DRAG : buttons & 4 ? Button.RIGHT_DRAG : Button.LEFT_DRAG;
    }
    const table = {
      down: [Button.LEFT_BUTTON, Button.MIDDLE_BUTTON, Button.RIGHT_BUTTON],
      up: [Button.LEFT_RELEASE, Button.MIDDLE_RELEASE, Button.RIGHT_RELEASE],
    };
    return table[phase][event.button] ?? table[phase][0];
  }

  processKey(x, y, button) {
    return this.exports.midend_process_key(this.me, x, y, button);
  }

  keyEventToButton(event) {
    const key = event.key;
    let code = -1;
    if (key === "Backspace" || key === "Delete") code = 127;
    else if (key === "Enter") code = 13;
    else if (key === " ") code = 32;
    else if (key === "Escape") code = 27;
    else if (key === "ArrowLeft") code = Button.CURSOR_LEFT;
    else if (key === "ArrowUp") code = Button.CURSOR_UP;
    else if (key === "ArrowRight") code = Button.CURSOR_RIGHT;
    else if (key === "ArrowDown") code = Button.CURSOR_DOWN;
    else if (key.length === 1 && key.charCodeAt(0) < 0x80) code = key.charCodeAt(0);
    if (code < 0) return -1;
    if (event.shiftKey) code |= Button.MOD_SHFT;
    if (event.ctrlKey || event.metaKey) code |= Button.MOD_CTRL;
    return code;
  }

  /* --------------------------------------------------------------
   * High-level game control.
   */
  newGame() {
    this.processKey(0, 0, Button.UI_NEWGAME);
  }
  restartGame() {
    this.exports.midend_restart_game(this.me);
  }
  undo() {
    this.processKey(0, 0, Button.UI_UNDO);
  }
  redo() {
    this.processKey(0, 0, Button.UI_REDO);
  }
  solve() {
    const err = this.exports.midend_solve(this.me);
    if (err) this.onFatalError(this.readCString(err));
  }
  canUndo() {
    return !!this.exports.midend_can_undo(this.me);
  }
  canRedo() {
    return !!this.exports.midend_can_redo(this.me);
  }
  wantsStatusBar() {
    return !!this.exports.midend_wants_statusbar(this.me);
  }

  /* --------------------------------------------------------------
   * Presets.
   */
  getPresets() {
    const idLimitPtr = this.mallocInt();
    const menu = this.exports.midend_get_presets(this.me, idLimitPtr);
    this.exports.free(idLimitPtr);
    const walk = (m) => {
      const n = this.exports.wasmmid_preset_menu_nentries(m);
      const entries = [];
      for (let i = 0; i < n; i++) {
        const submenu = this.exports.wasmmid_preset_menu_entry_submenu(m, i);
        entries.push({
          title: this.readCString(this.exports.wasmmid_preset_menu_entry_title(m, i)),
          id: this.exports.wasmmid_preset_menu_entry_id(m, i),
          submenu: submenu ? walk(submenu) : null,
        });
      }
      return entries;
    };
    return walk(menu);
  }

  whichPreset() {
    return this.exports.midend_which_preset(this.me);
  }

  setPresetById(id) {
    const idLimitPtr = this.mallocInt();
    const menu = this.exports.midend_get_presets(this.me, idLimitPtr);
    this.exports.free(idLimitPtr);
    const params = this.exports.preset_menu_lookup_by_id(menu, id);
    this.exports.midend_set_params(this.me, params);
    this.newGameFromParams();
  }

  newGameFromParams() {
    this.exports.midend_new_game(this.me);
    this.resize(false);
    this.exports.midend_force_redraw(this.me);
  }

  /* --------------------------------------------------------------
   * Configuration dialogs (custom size, seed/id entry, preferences).
   */
  getConfig(which) {
    const titlePtrPtr = this.mallocInt();
    const cfg = this.exports.midend_get_config(this.me, which, titlePtrPtr);
    const titlePtr = this.readInt(titlePtrPtr);
    const title = this.readCString(titlePtr);
    this.exports.free(titlePtr);
    this.exports.free(titlePtrPtr);

    const fields = [];
    for (let i = 0; ; i++) {
      const type = this.exports.wasmmid_config_item_type(cfg, i);
      if (type === ConfigType.END) break;
      const field = {
        index: i,
        type,
        name: this.readCString(this.exports.wasmmid_config_item_name(cfg, i)),
      };
      if (type === ConfigType.STRING) {
        field.value = this.readCString(this.exports.wasmmid_config_item_string_value(cfg, i));
      } else if (type === ConfigType.BOOLEAN) {
        field.value = !!this.exports.wasmmid_config_item_bool_value(cfg, i);
      } else if (type === ConfigType.CHOICES) {
        const raw = this.readCString(this.exports.wasmmid_config_item_choices(cfg, i));
        field.choices = raw.slice(1).split(raw[0]);
        field.value = this.exports.wasmmid_config_item_choice_selected(cfg, i);
      }
      fields.push(field);
    }
    return { title, cfg, fields };
  }

  applyConfig(which, cfg, fields, values) {
    for (const field of fields) {
      const v = values[field.index];
      if (field.type === ConfigType.STRING) {
        const ptr = this.writeCString(v);
        this.exports.wasmmid_config_item_set_string(cfg, field.index, ptr);
        this.exports.free(ptr);
      } else if (field.type === ConfigType.BOOLEAN) {
        this.exports.wasmmid_config_item_set_bool(cfg, field.index, v ? 1 : 0);
      } else if (field.type === ConfigType.CHOICES) {
        this.exports.wasmmid_config_item_set_choice(cfg, field.index, v);
      }
    }
    const errPtr = this.exports.midend_set_config(this.me, which, cfg);
    const err = this.readCString(errPtr);
    if (err) return err;
    this.exports.free_cfg(cfg);
    if (which === ConfigWhich.PREFS) {
      this.resize(false);
      this.exports.midend_force_redraw(this.me);
    } else {
      this.newGameFromParams();
    }
    return null;
  }

  cancelConfig(cfg) {
    this.exports.free_cfg(cfg);
  }

  /* --------------------------------------------------------------
   * Save/load and preferences.
   */
  serialise() {
    const outlenPtr = this.mallocInt();
    const ptr = this.exports.wasmmid_serialise(this.me, outlenPtr);
    const len = this.readInt(outlenPtr);
    this.exports.free(outlenPtr);
    const bytes = new Uint8Array(this.memBuffer(), ptr, len).slice();
    this.exports.free(ptr);
    return bytes;
  }

  deserialise(bytes) {
    const ptr = this.exports.malloc(bytes.length);
    this.u8().set(bytes, ptr);
    const errPtr = this.exports.wasmmid_deserialise(this.me, ptr, bytes.length);
    this.exports.free(ptr);
    const err = this.readCString(errPtr);
    if (!err) {
      this.resize(false);
      this.exports.midend_force_redraw(this.me);
    }
    return err;
  }

  savePrefs() {
    const outlenPtr = this.mallocInt();
    const ptr = this.exports.wasmmid_save_prefs(this.me, outlenPtr);
    const len = this.readInt(outlenPtr);
    this.exports.free(outlenPtr);
    const bytes = new Uint8Array(this.memBuffer(), ptr, len).slice();
    this.exports.free(ptr);
    return bytes;
  }

  loadPrefs(bytes) {
    const ptr = this.exports.malloc(bytes.length);
    this.u8().set(bytes, ptr);
    const errPtr = this.exports.wasmmid_load_prefs(this.me, ptr, bytes.length);
    this.exports.free(ptr);
    return this.readCString(errPtr);
  }

  /** Save this game's in-progress state to localStorage under _stateKey, if set. */
  saveState() {
    if (!this.me || !this._stateKey) return;
    const bytes = this.serialise();
    localStorage.setItem(this._stateKey, btoa(String.fromCharCode(...bytes)));
  }

  destroy() {
    this.stopTimer();
    if (this.me) this.exports.midend_free(this.me);
    this.me = 0;
  }
}

function readCStringFromExports(exports, ptr) {
  if (ptr === 0) return "";
  const bytes = new Uint8Array(exports.memory.buffer);
  let end = ptr;
  while (bytes[end] !== 0) end++;
  return new TextDecoder().decode(bytes.subarray(ptr, end));
}

const wasmCache = new Map();

async function getWasmBytes(url) {
  if (!wasmCache.has(url)) {
    wasmCache.set(url, (async () => (await fetch(url)).arrayBuffer())());
  }
  return wasmCache.get(url);
}

/* ----------------------------------------------------------------------
 * Convenience: build a working puzzle UI (canvas, status bar, preset
 * menu, toolbar) inside a container element, entirely from a fetched
 * .wasm module. This is the easiest way to use this library from a
 * plain HTML page; construct a Midend directly if you want to supply
 * your own UI around it.
 *
 * For a combined module (built from every puzzle, see
 * ../wasm-midend.md), a "Puzzle:" selector is added automatically;
 * choosing a different game re-mounts the whole UI for that game,
 * reusing the already-fetched .wasm bytes.
 */
export async function mountPuzzle(container, wasmUrl, options = {}) {
  if (container._puzzleMidend) {
    container._puzzleMidend.saveState();
    container._puzzleMidend.destroy();
    if (container._puzzleMidendResizeObserver) container._puzzleMidendResizeObserver.disconnect();
    if (container._puzzleMidendThemeCleanup) container._puzzleMidendThemeCleanup();
  }
  container.innerHTML = "";
  container.classList.add("puzzle-midend");

  const toolbar = document.createElement("div");
  toolbar.className = "puzzle-midend-toolbar";
  container.appendChild(toolbar);

  const makeButton = (label, onClick) => {
    const b = document.createElement("button");
    b.textContent = label;
    b.addEventListener("click", onClick);
    toolbar.appendChild(b);
    return b;
  };

  const wasmBytes = await getWasmBytes(wasmUrl);

  /* Absent an explicit gameIndex (from a caller, or a URL ?game=
   * param), fall back to whatever game was last selected for this
   * module, so a refresh reloads the in-progress game rather than
   * always resetting to game 0. */
  const games = await Midend.probeGames(wasmBytes);
  const lastGameKey = games ? `puzzle-midend-last-game:${wasmUrl}` : null;
  let gameIndex = options.gameIndex;
  if (gameIndex === undefined && lastGameKey) {
    const stored = localStorage.getItem(lastGameKey);
    if (stored !== null) gameIndex = Number(stored);
  }
  if (lastGameKey && gameIndex !== undefined) localStorage.setItem(lastGameKey, String(gameIndex));

  if (games) {
    const gameSelect = document.createElement("select");
    for (const g of games) {
      const opt = document.createElement("option");
      opt.value = String(g.index);
      opt.textContent = g.name;
      gameSelect.appendChild(opt);
    }
    gameSelect.value = String(gameIndex ?? 0);
    gameSelect.addEventListener("change", () =>
      mountPuzzle(container, wasmUrl, { ...options, gameIndex: Number(gameSelect.value) }),
    );
    toolbar.appendChild(gameSelect);
  }

  const themeSelect = document.createElement("select");
  themeSelect.title = "Colour theme";
  for (const [value, label] of [
    ["system", "Theme: match system"],
    ["light", "Theme: light"],
    ["dark", "Theme: dark"],
  ]) {
    const opt = document.createElement("option");
    opt.value = value;
    opt.textContent = label;
    themeSelect.appendChild(opt);
  }
  setThemePreference(getThemePreference());
  themeSelect.value = getThemePreference();
  themeSelect.addEventListener("change", () => {
    setThemePreference(themeSelect.value);
    midend.forceRedraw();
  });
  toolbar.appendChild(themeSelect);

  const presetSelect = document.createElement("select");
  toolbar.appendChild(presetSelect);

  const canvasWrap = document.createElement("div");
  canvasWrap.className = "puzzle-midend-canvas-wrap";
  container.appendChild(canvasWrap);

  const canvas = document.createElement("canvas");
  canvas.tabIndex = 0;
  canvasWrap.appendChild(canvas);

  const statusBar = document.createElement("div");
  statusBar.className = "puzzle-midend-statusbar";
  container.appendChild(statusBar);

  let mounted = false;
  const midend = await Midend.load(wasmBytes, canvas, {
    ...options,
    gameIndex,
    statusBar,
    onIdsChanged: () => mounted && refreshPresetSelection(),
  });
  container._puzzleMidend = midend;
  mounted = true;

  if (!midend.wantsStatusBar()) statusBar.remove();

  const undoButton = makeButton("Undo", () => {
    midend.undo();
    updateButtons();
  });
  const redoButton = makeButton("Redo", () => {
    midend.redo();
    updateButtons();
  });
  makeButton("New", () => {
    midend.newGame();
    updateButtons();
  });
  makeButton("Restart", () => midend.restartGame());
  makeButton("Solve", () => midend.solve());

  function updateButtons() {
    undoButton.disabled = !midend.canUndo();
    redoButton.disabled = !midend.canRedo();
  }

  function populatePresets() {
    presetSelect.innerHTML = "";
    const addEntries = (entries, prefix) => {
      for (const entry of entries) {
        if (entry.submenu) {
          addEntries(entry.submenu, prefix + entry.title + " / ");
        } else {
          const opt = document.createElement("option");
          opt.value = String(entry.id);
          opt.textContent = prefix + entry.title;
          presetSelect.appendChild(opt);
        }
      }
    };
    addEntries(midend.getPresets(), "");
    if (midend.exports.wasmmid_game_can_configure(midend.exports.midend_which_game(midend.me))) {
      const opt = document.createElement("option");
      opt.value = "custom";
      opt.textContent = "Custom...";
      presetSelect.appendChild(opt);
    }
    refreshPresetSelection();
  }

  function refreshPresetSelection() {
    const current = String(midend.whichPreset());
    for (const opt of presetSelect.options) {
      if (opt.value === current) {
        presetSelect.value = opt.value;
        return;
      }
    }
  }

  presetSelect.addEventListener("change", () => {
    if (presetSelect.value === "custom") {
      openConfigDialog(ConfigWhich.SETTINGS);
      return;
    }
    midend.setPresetById(Number(presetSelect.value));
    updateButtons();
  });

  function openConfigDialog(which) {
    const { title, cfg, fields } = midend.getConfig(which);
    const overlay = document.createElement("div");
    overlay.className = "puzzle-midend-dialog-overlay";
    const box = document.createElement("form");
    box.className = "puzzle-midend-dialog";
    const heading = document.createElement("h3");
    heading.textContent = title;
    box.appendChild(heading);

    const inputs = [];
    for (const field of fields) {
      const row = document.createElement("label");
      row.className = "puzzle-midend-dialog-row";
      const span = document.createElement("span");
      span.textContent = field.name;
      row.appendChild(span);
      let input;
      if (field.type === ConfigType.STRING) {
        input = document.createElement("input");
        input.type = "text";
        input.value = field.value;
      } else if (field.type === ConfigType.BOOLEAN) {
        input = document.createElement("input");
        input.type = "checkbox";
        input.checked = field.value;
      } else {
        input = document.createElement("select");
        field.choices.forEach((choice, i) => {
          const opt = document.createElement("option");
          opt.value = String(i);
          opt.textContent = choice;
          input.appendChild(opt);
        });
        input.value = String(field.value);
      }
      row.appendChild(input);
      box.appendChild(row);
      inputs.push(input);
    }

    const errorEl = document.createElement("div");
    errorEl.className = "puzzle-midend-dialog-error";
    box.appendChild(errorEl);

    const buttons = document.createElement("div");
    buttons.className = "puzzle-midend-dialog-buttons";
    const ok = document.createElement("button");
    ok.type = "submit";
    ok.textContent = "OK";
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.textContent = "Cancel";
    buttons.append(ok, cancel);
    box.appendChild(buttons);

    overlay.appendChild(box);
    container.appendChild(overlay);

    cancel.addEventListener("click", () => {
      midend.cancelConfig(cfg);
      overlay.remove();
    });
    box.addEventListener("submit", (event) => {
      event.preventDefault();
      const values = {};
      fields.forEach((field, i) => {
        const input = inputs[i];
        values[field.index] =
          field.type === ConfigType.BOOLEAN
            ? input.checked
            : field.type === ConfigType.CHOICES
              ? Number(input.value)
              : input.value;
      });
      const err = midend.applyConfig(which, cfg, fields, values);
      if (err) {
        errorEl.textContent = err;
        return;
      }
      overlay.remove();
      populatePresets();
      updateButtons();
    });
  }

  makeButton("Preferences...", () => openConfigDialog(ConfigWhich.PREFS));
  makeButton("Save", () => {
    const bytes = midend.serialise();
    const blob = new Blob([bytes], { type: "application/octet-stream" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "puzzle.sav";
    a.click();
    URL.revokeObjectURL(a.href);
  });
  const loadInput = document.createElement("input");
  loadInput.type = "file";
  loadInput.style.display = "none";
  loadInput.addEventListener("change", async () => {
    const file = loadInput.files[0];
    if (!file) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    const err = midend.deserialise(bytes);
    if (err) midend.onFatalError(err);
    else {
      populatePresets();
      updateButtons();
    }
  });
  toolbar.appendChild(loadInput);
  makeButton("Load...", () => loadInput.click());

  midend._prefsKey = `puzzle-midend-prefs:${wasmUrl}:${gameIndex ?? 0}`;
  const savedPrefs = localStorage.getItem(midend._prefsKey);
  if (savedPrefs) {
    midend.loadPrefs(Uint8Array.from(atob(savedPrefs), (c) => c.charCodeAt(0)));
  }

  midend._stateKey = `puzzle-midend-state:${wasmUrl}:${gameIndex ?? 0}`;
  const savedState = localStorage.getItem(midend._stateKey);
  if (savedState) {
    const err = midend.deserialise(Uint8Array.from(atob(savedState), (c) => c.charCodeAt(0)));
    if (err) {
      console.error("[puzzle] discarding unreadable saved game:", err);
      localStorage.removeItem(midend._stateKey);
    }
  }

  if (!container._puzzleMidendUnloadHandler) {
    container._puzzleMidendUnloadHandler = true;
    window.addEventListener("beforeunload", () => {
      const current = container._puzzleMidend;
      if (!current || !current.me) return;
      current.saveState();
      const bytes = current.savePrefs();
      localStorage.setItem(current._prefsKey, btoa(String.fromCharCode(...bytes)));
    });
  }

  const resizeObserver = new ResizeObserver(() => midend.resize(false));
  resizeObserver.observe(canvasWrap);
  container._puzzleMidendResizeObserver = resizeObserver;
  midend.resize(false);

  /* Colours are recomputed from the puzzle (and, for colour 0, from
   * the page's CSS) on every redraw - see refreshColours() - so
   * switching schemes just needs a redraw kicked off, not any special
   * cache invalidation. */
  const themeQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const onThemeChange = () => midend.forceRedraw();
  themeQuery.addEventListener("change", onThemeChange);
  container._puzzleMidendThemeCleanup = () => themeQuery.removeEventListener("change", onThemeChange);

  canvas.addEventListener("contextmenu", (e) => e.preventDefault());
  canvas.addEventListener("pointerdown", (e) => {
    canvas.focus();
    canvas.setPointerCapture(e.pointerId);
    const { x, y } = midend.canvasCoords(e);
    midend.processKey(x, y, midend.pointerButton(e, "down"));
    updateButtons();
  });
  canvas.addEventListener("pointermove", (e) => {
    if (e.buttons === 0) return;
    const { x, y } = midend.canvasCoords(e);
    midend.processKey(x, y, midend.pointerButton(e, "drag"));
  });
  canvas.addEventListener("pointerup", (e) => {
    const { x, y } = midend.canvasCoords(e);
    midend.processKey(x, y, midend.pointerButton(e, "up"));
    updateButtons();
  });
  canvas.addEventListener("keydown", (e) => {
    const button = midend.keyEventToButton(e);
    if (button < 0) return;
    e.preventDefault();
    midend.processKey(0, 0, button);
    updateButtons();
  });

  populatePresets();
  updateButtons();

  return midend;
}
