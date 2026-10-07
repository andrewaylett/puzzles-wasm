set(platform_common_sources emcc.c)
set(platform_gui_libs)
set(platform_libs)
set(CMAKE_EXECUTABLE_SUFFIX ".js")

set(WASM ON
  CACHE BOOL "Compile to WebAssembly rather than plain JavaScript")

option(PUZZLES_WASM_MIDEND
  "Also build WASM modules that expose the midend API directly (for \
front ends other than the canvas-based one in emcc.c), one per puzzle \
plus a combined module covering every puzzle - and, from those, the \
browser front end's static web pages (web/)" ON)

option(PUZZLES_WASM_MINSIZE
  "Optimise every WASM/JS target for size (-Oz with link-time \
optimisation) rather than speed. The puzzles are not compute-bound, so \
this trades a little speed for a markedly smaller download (the combined \
midend module shrinks by roughly 30% against a plain Release build). \
LTO needs LTO builds of Emscripten's system libraries, which emcc \
builds on demand into its cache; if the emsdk's cache isn't writable, \
point EM_CACHE at a directory that is." OFF)

if(PUZZLES_WASM_MINSIZE)
  # Both compile and link: with -flto the real optimisation happens at
  # link time, and the link step also needs -Oz for wasm-opt's passes.
  add_compile_options(-Oz -flto)
  add_link_options(-Oz -flto)
endif()

if(PUZZLES_WASM_MIDEND)
  find_program(TSC tsc)
  if(NOT TSC)
    message(FATAL_ERROR "PUZZLES_WASM_MIDEND (on by default) builds the \
browser front end's puzzle-midend.js from puzzle-midend.ts, which needs \
the TypeScript compiler: install one (e.g. 'npm install -g typescript') \
and make sure 'tsc' is on PATH, or pass -DTSC=/path/to/tsc, or configure \
with -DPUZZLES_WASM_MIDEND=OFF to skip the web front end entirely.")
  endif()
endif()

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

# Builds WASM modules that export the midend API directly, rather
# than the canvas-based UI in emcc.c. These deliberately don't use
# em_link_pre_js/em_link_js_library (that's how emcc.c's front end
# gets its js_* functions resolved): the wasmmid_* functions declared
# but not defined in wasmmidend.c are left as genuine WASM imports,
# for any host (JS or otherwise) to supply directly. See
# wasm-midend.md for the full contract.
function(build_wasm_midend_targets)
  # Per-puzzle modules land straight in the web output directory: it's
  # the thing build_wasm_web_pages() below packages up as the
  # ready-to-upload site, and each puzzle's page fetches
  # "<name>-midend.wasm" next to itself.
  set(web_output_dir ${CMAKE_BINARY_DIR}/web)
  # CMAKE_C_LINK_FLAGS (set above, for the canvas build's own targets)
  # is read once, at generate time, as a single value shared by every
  # C-executable target in this directory - it isn't captured
  # per-target at add_executable() time, so there's no way to exempt
  # our targets from it by (temporarily or otherwise) changing the
  # variable here. Instead, override the specific canvas-build
  # settings that don't apply to us (notably a MIN_FIREFOX_VERSION
  # newer emcc versions reject) by repeating them in our own
  # target_link_options(): emcc takes the last occurrence of a
  # repeated `-s KEY=`, and ours land after CMAKE_C_LINK_FLAGS on the
  # command line.
  set(wasmmidend_export_list
    # Exported directly from wasmmidend.c.
    _wasmmid_midend_new
    _wasmmid_preset_menu_nentries
    _wasmmid_preset_menu_entry_title
    _wasmmid_preset_menu_entry_id
    _wasmmid_preset_menu_entry_submenu
    _wasmmid_preset_menu_entry_params
    _wasmmid_config_item_type
    _wasmmid_config_item_name
    _wasmmid_config_item_kw
    _wasmmid_config_item_string_value
    _wasmmid_config_item_set_string
    _wasmmid_config_item_bool_value
    _wasmmid_config_item_set_bool
    _wasmmid_config_item_choices
    _wasmmid_config_item_choice_selected
    _wasmmid_config_item_set_choice
    _wasmmid_key_label_text
    _wasmmid_key_label_button
    _wasmmid_game_name
    _wasmmid_game_can_solve
    _wasmmid_game_can_configure
    _wasmmid_game_can_format_as_text_ever
    _wasmmid_midend_request_id_changes
    _wasmmid_serialise
    _wasmmid_deserialise
    _wasmmid_save_prefs
    _wasmmid_load_prefs
    _wasmmid_identify_game
    # Exported directly from midend.c/misc.c: plain enough signatures
    # to cross the WASM boundary as-is.
    _midend_free
    _midend_which_game
    _midend_set_params
    _midend_get_params
    _midend_size
    _midend_reset_tilesize
    _midend_new_game
    _midend_restart_game
    _midend_stop_anim
    _midend_process_key
    _midend_request_keys
    _midend_current_key_label
    _midend_force_redraw
    _midend_redraw
    _midend_colours
    _midend_freeze_timer
    _midend_timer
    _midend_get_presets
    _midend_which_preset
    _midend_wants_statusbar
    _midend_get_config
    _midend_set_config
    _midend_game_id
    _midend_get_game_id
    _midend_get_random_seed
    _midend_can_format_as_text_now
    _midend_text_format
    _midend_solve
    _midend_status
    _midend_can_undo
    _midend_can_redo
    _midend_supersede_game_desc
    _midend_rewrite_statusbar
    _midend_get_cursor_location
    _midend_tilesize
    _free_cfg
    _free_keys
    _preset_menu_lookup_by_id
    # Memory management, so the host can hand us buffers and free
    # what we return.
    _malloc
    _free)
  set(wasmmidend_combined_export_list ${wasmmidend_export_list}
    _wasmmid_game_count _wasmmid_game_at)

  list(TRANSFORM wasmmidend_export_list PREPEND \")
  list(TRANSFORM wasmmidend_export_list APPEND \")
  string(JOIN "," wasmmidend_export_string ${wasmmidend_export_list})

  list(TRANSFORM wasmmidend_combined_export_list PREPEND \")
  list(TRANSFORM wasmmidend_combined_export_list APPEND \")
  string(JOIN "," wasmmidend_combined_export_string
    ${wasmmidend_combined_export_list})

  # These targets don't emit any JS glue at all (STANDALONE_WASM), so
  # the canvas build's browser-version floors and STRICT_JS don't
  # apply to them; MIN_FIREFOX_VERSION in particular is overridden
  # because newer Emscripten versions reject the canvas build's older
  # floor outright. See the note above build_wasm_midend_targets() for
  # why this is done by repeating the setting rather than by trying to
  # exempt these targets from CMAKE_C_LINK_FLAGS.
  # --no-entry: build a WASI reactor (exporting _initialize) rather
  # than a command (exporting _start, which Emscripten wires up to
  # call proc_exit() once main() returns). wasmmidend.c has no main()
  # for exactly this reason, but STANDALONE_WASM's EXPECT_MAIN
  # defaults to true regardless of whether a main() actually exists
  # in the linked objects, so this flag - not the absence of main() -
  # is what actually switches the mode.
  set(wasmmidend_link_options
    -sSTANDALONE_WASM=1
    --no-entry
    -sALLOW_MEMORY_GROWTH=1
    -sEXPORTED_FUNCTIONS=[${wasmmidend_export_string}]
    -sMIN_FIREFOX_VERSION=0
    -sMIN_CHROME_VERSION=0
    -sMIN_SAFARI_VERSION=0
    -sERROR_ON_UNDEFINED_SYMBOLS=0)

  # Two separate object libraries, not one shared between both kinds
  # of target: wasmmidend.c's behaviour (and list.c's) differs under
  # COMBINED, so each flavour needs its own compile of it.
  add_library(wasmmidend_core_obj OBJECT
    ${midend_core_sources} hat.c spectre.c wasmmidend.c)

  add_library(wasmmidend_combined_core_obj OBJECT
    ${midend_core_sources} hat.c spectre.c wasmmidend.c)
  target_compile_definitions(wasmmidend_combined_core_obj PRIVATE COMBINED)
  target_include_directories(wasmmidend_combined_core_obj PRIVATE
    ${generated_include_dir})

  # puzzle_names and puzzle_sources are meant to be parallel lists,
  # but build_extras() (cmake/setup.cmake) sorts puzzle_names before
  # calling build_platform_extras() without sorting puzzle_sources to
  # match, so the two are not reliably in step by the time we get
  # here. Resolve each name's source file ourselves instead of
  # indexing into puzzle_sources.
  foreach(name ${puzzle_names})
    if(EXISTS ${PUZZLES_ROOT_DIR}/${name}.c)
      set(source ${PUZZLES_ROOT_DIR}/${name}.c)
    else()
      set(source ${PUZZLES_ROOT_DIR}/unfinished/${name}.c)
    endif()
    add_executable(${name}-midend
      $<TARGET_OBJECTS:wasmmidend_core_obj> ${source})
    set_target_properties(${name}-midend PROPERTIES
      SUFFIX ".wasm"
      RUNTIME_OUTPUT_DIRECTORY ${web_output_dir})
    target_link_options(${name}-midend PRIVATE ${wasmmidend_link_options})
  endforeach()

  add_executable(puzzles-midend
    $<TARGET_OBJECTS:wasmmidend_combined_core_obj> list.c ${puzzle_sources})
  target_compile_definitions(puzzles-midend PRIVATE COMBINED)
  target_include_directories(puzzles-midend PRIVATE ${generated_include_dir})
  set_target_properties(puzzles-midend PROPERTIES SUFFIX ".wasm")
  target_link_options(puzzles-midend PRIVATE
    -sSTANDALONE_WASM=1
    --no-entry
    -sALLOW_MEMORY_GROWTH=1
    -sEXPORTED_FUNCTIONS=[${wasmmidend_combined_export_string}]
    -sMIN_FIREFOX_VERSION=0
    -sMIN_CHROME_VERSION=0
    -sMIN_SAFARI_VERSION=0
    -sERROR_ON_UNDEFINED_SYMBOLS=0)
endfunction()

# Assembles the browser front end's static site: puzzle-midend.js
# (compiled from puzzle-midend.ts by tsc), puzzle-midend.css, one HTML
# page per puzzle (each fetching its own <name>-midend.wasm, built by
# build_wasm_midend_targets() above into the same directory) and an
# index page linking to all of them - the WASM-mid-end equivalent of
# the classic set of per-puzzle canvas-build pages under html/. Must
# run after build_platform_extras() has set up help_dir/HALIBUT, so
# game pages can link to their instructions when docs are available.
function(build_wasm_web_pages)
  set(web_src_dir ${PUZZLES_ROOT_DIR}/web)
  set(web_output_dir ${CMAKE_BINARY_DIR}/web)
  file(MAKE_DIRECTORY ${web_output_dir})

  add_custom_command(
    OUTPUT ${web_output_dir}/puzzle-midend.js
    COMMAND ${TSC} --target es2022 --module es2022
      --outDir ${web_output_dir} ${web_src_dir}/puzzle-midend.ts
    DEPENDS ${web_src_dir}/puzzle-midend.ts
    COMMENT "Compiling puzzle-midend.ts (tsc)")

  add_custom_command(
    OUTPUT ${web_output_dir}/puzzle-midend.css
    COMMAND ${CMAKE_COMMAND} -E copy
      ${web_src_dir}/puzzle-midend.css ${web_output_dir}/puzzle-midend.css
    DEPENDS ${web_src_dir}/puzzle-midend.css)

  # Puzzles under unfinished/ (see PUZZLES_ENABLE_UNFINISHED) aren't
  # documented in puzzles.but, so they get no "Full instructions" link
  # and are left off the index - matching html/jspage.pl's treatment
  # of the same puzzles for the canvas build.
  set(page_args)
  set(page_outputs ${web_output_dir}/index.html)
  foreach(name ${puzzle_names})
    if(EXISTS ${PUZZLES_ROOT_DIR}/${name}.c)
      set(unfinished 0)
    else()
      set(unfinished 1)
    endif()
    list(APPEND page_args
      ${name} "${displayname_${name}}" "${description_${name}}" ${unfinished})
    list(APPEND page_outputs ${web_output_dir}/${name}.html)
  endforeach()

  if(HALIBUT)
    set(has_help 1)
  else()
    set(has_help 0)
  endif()

  add_custom_command(
    OUTPUT ${page_outputs}
    COMMAND ${web_src_dir}/genpages.pl
      ${web_output_dir} ${has_help} ${page_args}
    DEPENDS ${web_src_dir}/genpages.pl ${PUZZLES_ROOT_DIR}/CMakeLists.txt
    VERBATIM
    COMMENT "Generating puzzle web pages")

  add_custom_target(puzzles-web ALL
    DEPENDS
      ${web_output_dir}/puzzle-midend.js
      ${web_output_dir}/puzzle-midend.css
      ${page_outputs})

  foreach(name ${puzzle_names})
    add_dependencies(puzzles-web ${name}-midend)
  endforeach()

  if(HALIBUT)
    # help_dir/en is populated by the kaios_help target above; copy it
    # into the web output so the generated pages' "Full instructions"
    # links resolve without reaching outside the upload directory.
    add_dependencies(puzzles-web kaios_help)
    add_custom_command(TARGET puzzles-web POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${help_dir}/en ${web_output_dir}/help
      COMMENT "Copying puzzle documentation into the web output")
  endif()
endfunction()

function(build_platform_extras)
  if(PUZZLES_WASM_MIDEND)
    build_wasm_midend_targets()
  endif()

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

  if(PUZZLES_WASM_MIDEND)
    build_wasm_web_pages()
  endif()
endfunction()
