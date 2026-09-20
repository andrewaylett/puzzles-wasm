# Notes for agents working on this repository

## Emscripten browser minima and KaiOS

`cmake/platforms/emscripten.cmake` probes the installed emsdk at configure
time to find the oldest browser versions it's still willing to target (emcc
enforces a rising floor per release; see `check_browser_versions()` in its
`tools/link.py`), and uses that to set `MIN_FIREFOX_VERSION`,
`MIN_CHROME_VERSION` and `MIN_SAFARI_VERSION`.

KaiOS 2.5's browser is based on Firefox 48. The non-WASM build
(`-DWASM=NO`, used for the KaiOS packaging in `Buildscr`) needs to target
Firefox 48 specifically, and configuration now fails outright if the
installed emsdk's floor has risen above that - there's no way to force an
older target once emcc refuses it. As of emsdk 3.1.x-era releases carrying
Firefox floors above 79, KaiOS builds are no longer possible without an
older emsdk kept around specifically for that purpose.
