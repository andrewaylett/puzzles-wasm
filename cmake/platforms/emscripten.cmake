set(platform_common_sources emcc.c)
set(platform_gui_libs)
set(platform_libs)
set(CMAKE_EXECUTABLE_SUFFIX ".js")

set(WASM ON
  CACHE BOOL "Compile to WebAssembly rather than plain JavaScript")

# The emsdk itself refuses to target browsers older than some floor
# that rises from one Emscripten release to the next (see
# check_browser_versions() in tools/link.py, and the table it reads
# in tools/feature_matrix.py). We used to just hard-code numbers that
# were correct for whichever Emscripten happened to be installed when
# this file was last edited, but that breaks as soon as a newer emsdk
# raises its floor above one of them - which has already happened for
# Firefox. So instead, ask the installed emsdk what its floor actually
# is, and use that both to pick sensible minimums and to work out
# whether the emsdk can still target old enough a Firefox to support
# KaiOS (whose browser is based on Firefox 48) at all.
#
# We find each floor by deliberately asking emcc to target something
# absurdly old and reading the version number out of the "older than
# NN is not supported" diagnostic it prints - that's the same check
# the real build is subject to, so it can't go stale independently of
# the emsdk itself.
function(emscripten_probe_oldest_supported ff cr sf setting_name outvar)
  set(probe_src "${CMAKE_BINARY_DIR}/CMakeFiles/emcc-min-browser-probe.c")
  if(NOT EXISTS "${probe_src}")
    file(WRITE "${probe_src}" "int main(void) { return 0; }\n")
  endif()

  execute_process(
    COMMAND "${CMAKE_C_COMPILER}" "${probe_src}"
      -o "${CMAKE_BINARY_DIR}/CMakeFiles/emcc-min-browser-probe.js"
      -s ENVIRONMENT=web
      -s MIN_NODE_VERSION=0
      -s MIN_FIREFOX_VERSION=${ff}
      -s MIN_CHROME_VERSION=${cr}
      -s MIN_SAFARI_VERSION=${sf}
    RESULT_VARIABLE probe_result
    OUTPUT_VARIABLE probe_stdout
    ERROR_VARIABLE probe_stderr)
  set(probe_text "${probe_stdout}${probe_stderr}")

  if(probe_text MATCHES "${setting_name} older than ([0-9]+) is not supported")
    set(${outvar} "${CMAKE_MATCH_1}" PARENT_SCOPE)
  else()
    message(WARNING "Couldn't work out the oldest browser version this "
      "emsdk still accepts for ${setting_name} (expected emcc to reject "
      "an absurdly low value and name its actual floor; it didn't). "
      "Falling back to Puzzles' own hard-coded default for it, which "
      "may be stale. emcc said:\n${probe_text}")
    set(${outvar} "" PARENT_SCOPE)
  endif()
endfunction()

# Only re-run the (fairly slow) probes when the emsdk itself has
# changed, e.g. because it's been upgraded in place without wiping out
# this build directory.
execute_process(COMMAND "${CMAKE_C_COMPILER}" --version
  OUTPUT_VARIABLE emcc_version_text ERROR_QUIET)
string(REGEX MATCH "[^\n]+" emcc_version_line "${emcc_version_text}")

if(NOT DEFINED CACHE{EMSCRIPTEN_BROWSER_FLOOR_STAMP} OR
    NOT EMSCRIPTEN_BROWSER_FLOOR_STAMP STREQUAL emcc_version_line)
  emscripten_probe_oldest_supported(1 0 0 MIN_FIREFOX_VERSION oldest_firefox)
  emscripten_probe_oldest_supported(0 1 0 MIN_CHROME_VERSION oldest_chrome)
  emscripten_probe_oldest_supported(0 0 1 MIN_SAFARI_VERSION oldest_safari)
  set(EMSCRIPTEN_OLDEST_SUPPORTED_FIREFOX "${oldest_firefox}" CACHE INTERNAL
    "Oldest Firefox version the installed emsdk is willing to target")
  set(EMSCRIPTEN_OLDEST_SUPPORTED_CHROME "${oldest_chrome}" CACHE INTERNAL
    "Oldest Chrome version the installed emsdk is willing to target")
  set(EMSCRIPTEN_OLDEST_SUPPORTED_SAFARI "${oldest_safari}" CACHE INTERNAL
    "Oldest Safari version the installed emsdk is willing to target")
  set(EMSCRIPTEN_BROWSER_FLOOR_STAMP "${emcc_version_line}" CACHE INTERNAL
    "emcc --version output the above floors were probed from")
endif()

# KaiOS 2.5's browser is based on Firefox 48. If the installed emsdk's
# floor has risen above that, it's no longer able to produce a
# genuinely KaiOS-compatible build at all (asking for
# MIN_FIREFOX_VERSION=0 would link, but that just disables emcc's own
# feature gating rather than actually asserting Firefox 48
# compatibility, so it isn't a substitute).
if(NOT WASM AND NOT EMSCRIPTEN_OLDEST_SUPPORTED_FIREFOX STREQUAL "" AND
    EMSCRIPTEN_OLDEST_SUPPORTED_FIREFOX GREATER 48)
  message(FATAL_ERROR "This emsdk (${EMSCRIPTEN_BROWSER_FLOOR_STAMP}) "
    "can't target anything older than Firefox "
    "${EMSCRIPTEN_OLDEST_SUPPORTED_FIREFOX}, which is newer than the "
    "Firefox 48 that KaiOS 2.5 is based on, so it can't build a "
    "KaiOS-compatible target. Try an older emsdk, or configure with "
    "-DWASM=ON if you just want the ordinary web build.")
endif()

# Pick each minimum as the more restrictive of what Puzzles' own
# JavaScript wants and what this emsdk will still let us ask for, and
# refuse to configure if a version forced on the command line
# (-DMIN_..._VERSION=) is one the emsdk won't accept.
macro(emscripten_set_min_version varname default_value floor_value docstring)
  set(effective_default ${default_value})
  if(NOT "${floor_value}" STREQUAL "" AND "${floor_value}" GREATER effective_default)
    set(effective_default ${floor_value})
  endif()
  set(${varname} ${effective_default} CACHE STRING "${docstring}")
  if(NOT "${floor_value}" STREQUAL "" AND ${varname} LESS "${floor_value}")
    message(FATAL_ERROR "${varname}=${${varname}} is older than this "
      "emsdk supports (${floor_value}).")
  endif()
endmacro()

if(WASM)
  emscripten_set_min_version(MIN_FIREFOX_VERSION 68
    "${EMSCRIPTEN_OLDEST_SUPPORTED_FIREFOX}"
    "Oldest major version of Firefox to target")
else()
  emscripten_set_min_version(MIN_FIREFOX_VERSION 48
    "${EMSCRIPTEN_OLDEST_SUPPORTED_FIREFOX}"
    "Oldest major version of Firefox to target")
endif()
emscripten_set_min_version(MIN_SAFARI_VERSION 150000
  "${EMSCRIPTEN_OLDEST_SUPPORTED_SAFARI}"
  "Oldest version of desktop Safari to target (XXYYZZ for version XX.YY.ZZ)")
emscripten_set_min_version(MIN_CHROME_VERSION 57
  "${EMSCRIPTEN_OLDEST_SUPPORTED_CHROME}"
  "Oldest version of Chrome to target")

find_program(HALIBUT halibut)
if(NOT HALIBUT)
  message(WARNING "HTML documentation cannot be built (did not find halibut)")
endif()

set(emcc_export_list
  # Event handlers for mouse and keyboard input
  _mouseup
  _mousedown
  _mousemove
  _key
  # Callback when the program activates timing
  _timer_callback
  # Callback from button presses in the UI outside the canvas
  _command
  # Text-formatting for copying to clipboard
  _get_text_format
  _free_text_format
  # Game-saving and game-loading functions
  _get_save_file
  _free_save_file
  _load_game
  # Callbacks to return values from dialog boxes
  _dlg_return_sval
  _dlg_return_ival
  # Callbacks when the resizing controls are used
  _resize_puzzle
  _restore_puzzle_size
  # Callback when device pixel ratio changes
  _rescale_puzzle
  # Callback for loading user preferences
  _prefs_load_callback
  # Functions for allocating and freeing C memory
  _malloc
  _free
  # Main program, run at initialisation time
  _main)

list(TRANSFORM emcc_export_list PREPEND \")
list(TRANSFORM emcc_export_list APPEND \")
string(JOIN "," emcc_export_string ${emcc_export_list})
set(CMAKE_C_LINK_FLAGS "\
-s ALLOW_MEMORY_GROWTH=1 \
-s ENVIRONMENT=web \
-s EXPORTED_FUNCTIONS='[${emcc_export_string}]' \
-s EXPORTED_RUNTIME_METHODS='[cwrap]' \
-s MIN_FIREFOX_VERSION=${MIN_FIREFOX_VERSION} \
-s MIN_SAFARI_VERSION=${MIN_SAFARI_VERSION} \
-s MIN_CHROME_VERSION=${MIN_CHROME_VERSION} \
-s MIN_NODE_VERSION=0x7FFFFFFF \
-s STRICT_JS=1")
if(WASM)
  set(CMAKE_C_LINK_FLAGS "${CMAKE_C_LINK_FLAGS} -s WASM=1 -s WASM_BIGINT")
else()
  set(CMAKE_C_LINK_FLAGS "${CMAKE_C_LINK_FLAGS} -s WASM=0")
endif()

set(build_cli_programs FALSE)
set(build_gui_programs FALSE)

function(get_platform_puzzle_extra_source_files OUTVAR NAME AUXILIARY)
  set(${OUTVAR} PARENT_SCOPE)
endfunction()

function(set_platform_gui_target_properties TARGET)
endfunction()

function(set_platform_puzzle_target_properties NAME TARGET)
  em_link_pre_js(${TARGET} ${PUZZLES_ROOT_DIR}/emccpre.js)
  em_link_js_library(${TARGET} ${PUZZLES_ROOT_DIR}/emcclib.js)
endfunction()

function(build_platform_extras)
  if(HALIBUT)
    set(help_dir ${CMAKE_CURRENT_BINARY_DIR}/help)
    add_custom_command(OUTPUT ${help_dir}/en
      COMMAND ${CMAKE_COMMAND} -E make_directory ${help_dir}/en)
    add_custom_command(OUTPUT ${help_dir}/en/index.html
      COMMAND ${HALIBUT} --html -Chtml-template-fragment:%k
        ${CMAKE_CURRENT_SOURCE_DIR}/puzzles.but
        ${CMAKE_CURRENT_SOURCE_DIR}/emcccopy.but
      DEPENDS
      ${help_dir}/en
      ${CMAKE_CURRENT_SOURCE_DIR}/puzzles.but
      ${CMAKE_CURRENT_SOURCE_DIR}/emcccopy.but
      WORKING_DIRECTORY ${help_dir}/en)
    add_custom_target(kaios_help ALL
      DEPENDS ${help_dir}/en/index.html)
  endif()

  # This is probably not the right way to set the destination.
  set(CMAKE_INSTALL_PREFIX ${CMAKE_CURRENT_BINARY_DIR} CACHE PATH
      "Installation path" FORCE)

  add_custom_target(kaios-extras ALL)

  foreach(name ${puzzle_names})
    add_custom_command(
      OUTPUT ${name}-manifest.webapp
      COMMAND ${PERL_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/kaios/manifest.pl
        "${name}" "${displayname_${name}}" "${description_${name}}"
        "${objective_${name}}" > "${name}-manifest.webapp"
      VERBATIM
      DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/kaios/manifest.pl)

    file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/kaios)
    add_custom_command(
      OUTPUT ${name}-kaios.html
      COMMAND ${PERL_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/kaios/apppage.pl
        "${name}" "${displayname_${name}}" > "${name}-kaios.html"
      VERBATIM
      DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/kaios/apppage.pl)

    add_custom_target(${name}-kaios-extras
      DEPENDS ${name}-manifest.webapp ${name}-kaios.html)
    add_dependencies(kaios-extras ${name}-kaios-extras)

    install(TARGETS ${name} DESTINATION kaios/${name})
    # Release builds generate an initial memory image alongside the
    # JavaScript, but CMake doesn't seem to know about it to install
    # it.
    install(FILES $<TARGET_FILE:${name}>.mem OPTIONAL
      DESTINATION kaios/${name})
    install(FILES ${ICON_DIR}/${name}-56kai.png ${ICON_DIR}/${name}-112kai.png
      DESTINATION kaios/${name} OPTIONAL)
    install(FILES ${CMAKE_CURRENT_BINARY_DIR}/${name}-kaios.html
      RENAME ${name}.html
      DESTINATION kaios/${name})
    install(FILES ${CMAKE_CURRENT_BINARY_DIR}/${name}-manifest.webapp
      RENAME manifest.webapp
      DESTINATION kaios/${name})
    install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/kaios/kaiads-glue.js
      DESTINATION kaios/${name})
    install(DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/help OPTIONAL
      DESTINATION kaios/${name})

  endforeach()
endfunction()
