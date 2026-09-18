/*
 * wasmmidend.c: a minimal, UI-agnostic Emscripten front end that
 * exposes the mid-end's own C API directly as WASM exports, instead
 * of implementing a canvas UI itself (that's emcc.c's job).
 *
 * The intent is that a front end doesn't have to be written in C at
 * all: it just needs to be able to call WASM exports and provide the
 * small set of WASM imports declared below (drawing primitives, a
 * timer, a default colour, a random seed, and fatal-error
 * reporting). Everything else (dialogs, presets, save/load) is
 * exposed as data the host pulls via accessor functions, rather than
 * pushed out to bespoke JS the way emcc.c does it.
 *
 * See wasm-midend.md for the full interface contract.
 */

#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#include <emscripten.h>

#include "puzzles.h"

/* ----------------------------------------------------------------------
 * Imports: things only a front end can provide.
 */
extern void wasmmid_fatal_error(const char *message);
extern void wasmmid_get_date_64(unsigned *p);
extern void wasmmid_default_colour(float *output);
extern void wasmmid_activate_timer(void);
extern void wasmmid_deactivate_timer(void);
extern void wasmmid_ids_changed(void);

extern void wasmmid_draw_text(drawing *dr, int x, int y, int fonttype,
                              int fontsize, int align, int colour,
                              const char *text);
extern void wasmmid_draw_rect(drawing *dr, int x, int y, int w, int h,
                              int colour);
extern void wasmmid_draw_line(drawing *dr, int x1, int y1, int x2, int y2,
                              int colour);
extern void wasmmid_draw_polygon(drawing *dr, const int *coords, int npoints,
                                 int fillcolour, int outlinecolour);
extern void wasmmid_draw_circle(drawing *dr, int cx, int cy, int radius,
                                int fillcolour, int outlinecolour);
extern void wasmmid_draw_update(drawing *dr, int x, int y, int w, int h);
extern void wasmmid_clip(drawing *dr, int x, int y, int w, int h);
extern void wasmmid_unclip(drawing *dr);
extern void wasmmid_start_draw(drawing *dr);
extern void wasmmid_end_draw(drawing *dr);
extern void wasmmid_status_bar(drawing *dr, const char *text);
extern blitter *wasmmid_blitter_new(drawing *dr, int w, int h);
extern void wasmmid_blitter_free(drawing *dr, blitter *bl);
extern void wasmmid_blitter_save(drawing *dr, blitter *bl, int x, int y);
extern void wasmmid_blitter_load(drawing *dr, blitter *bl, int x, int y);
extern void wasmmid_draw_thick_line(drawing *dr, float thickness,
                                    float x1, float y1, float x2, float y2,
                                    int colour);

#ifdef DEBUGGING
extern void wasmmid_debug(const char *message);
void debug_printf(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    wasmmid_debug(buf);
}
#endif

/* ----------------------------------------------------------------------
 * Frontend platform hooks required by puzzles.h.
 */
void fatal(const char *fmt, ...)
{
    char buf[512];
    va_list ap;

    strcpy(buf, "puzzle fatal error: ");

    va_start(ap, fmt);
    vsnprintf(buf + strlen(buf), sizeof(buf) - strlen(buf), fmt, ap);
    va_end(ap);

    wasmmid_fatal_error(buf);
}

void get_random_seed(void **randseed, int *randseedsize)
{
    unsigned *ret = snewn(2, unsigned);
    wasmmid_get_date_64(ret);
    *randseed = ret;
    *randseedsize = 2 * sizeof(unsigned);
}

void frontend_default_colour(frontend *fe, float *output)
{
    output[0] = output[1] = output[2] = 0.9F;
    wasmmid_default_colour(output);
}

static bool wasmmid_timer_active = false;
void activate_timer(frontend *fe)
{
    if (!wasmmid_timer_active) {
        wasmmid_activate_timer();
        wasmmid_timer_active = true;
    }
}
void deactivate_timer(frontend *fe)
{
    wasmmid_deactivate_timer();
    wasmmid_timer_active = false;
}

/* ----------------------------------------------------------------------
 * The drawing API: every entry forwards to an import, except
 * text_fallback, which needs no host support at all.
 */
static char *wasmmid_text_fallback(drawing *dr, const char *const *strings,
                                   int nstrings)
{
    return dupstr(strings[0]);
}

static const struct drawing_api wasmmid_drawing = {
    1,
    wasmmid_draw_text,
    wasmmid_draw_rect,
    wasmmid_draw_line,
#ifdef USE_DRAW_POLYGON_FALLBACK
    draw_polygon_fallback,
#else
    wasmmid_draw_polygon,
#endif
    wasmmid_draw_circle,
    wasmmid_draw_update,
    wasmmid_clip,
    wasmmid_unclip,
    wasmmid_start_draw,
    wasmmid_end_draw,
    wasmmid_status_bar,
    wasmmid_blitter_new,
    wasmmid_blitter_free,
    wasmmid_blitter_save,
    wasmmid_blitter_load,
    NULL, NULL, NULL, NULL, NULL, NULL, /* {begin,end}_{doc,page,puzzle} */
    NULL, NULL,                         /* line_width, line_dotted */
    wasmmid_text_fallback,
    wasmmid_draw_thick_line,
};

/* ----------------------------------------------------------------------
 * Lifecycle.
 */
#ifdef COMBINED
EMSCRIPTEN_KEEPALIVE
int wasmmid_game_count(void)
{
    return gamecount;
}

EMSCRIPTEN_KEEPALIVE
const game *wasmmid_game_at(int index)
{
    return gamelist[index];
}

EMSCRIPTEN_KEEPALIVE
midend *wasmmid_midend_new(int index)
{
    return midend_new(NULL, gamelist[index], &wasmmid_drawing, NULL);
}
#else
EMSCRIPTEN_KEEPALIVE
midend *wasmmid_midend_new(void)
{
    return midend_new(NULL, &thegame, &wasmmid_drawing, NULL);
}
#endif

/* ----------------------------------------------------------------------
 * Aggregate accessors: a non-C host can't walk C structs, so it pulls
 * their contents through these instead.
 */
EMSCRIPTEN_KEEPALIVE
int wasmmid_preset_menu_nentries(const struct preset_menu *menu)
{
    return menu->n_entries;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_preset_menu_entry_title(const struct preset_menu *menu,
                                            int i)
{
    return menu->entries[i].title;
}

EMSCRIPTEN_KEEPALIVE
int wasmmid_preset_menu_entry_id(const struct preset_menu *menu, int i)
{
    return menu->entries[i].id;
}

EMSCRIPTEN_KEEPALIVE
struct preset_menu *wasmmid_preset_menu_entry_submenu(
    const struct preset_menu *menu, int i)
{
    return menu->entries[i].submenu;
}

EMSCRIPTEN_KEEPALIVE
game_params *wasmmid_preset_menu_entry_params(const struct preset_menu *menu,
                                              int i)
{
    return menu->entries[i].params;
}

EMSCRIPTEN_KEEPALIVE
int wasmmid_config_item_type(const config_item *cfg, int i)
{
    return cfg[i].type;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_config_item_name(const config_item *cfg, int i)
{
    return cfg[i].name;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_config_item_kw(const config_item *cfg, int i)
{
    return cfg[i].kw;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_config_item_string_value(const config_item *cfg, int i)
{
    return cfg[i].u.string.sval;
}

EMSCRIPTEN_KEEPALIVE
void wasmmid_config_item_set_string(config_item *cfg, int i, const char *v)
{
    sfree(cfg[i].u.string.sval);
    cfg[i].u.string.sval = dupstr(v);
}

EMSCRIPTEN_KEEPALIVE
bool wasmmid_config_item_bool_value(const config_item *cfg, int i)
{
    return cfg[i].u.boolean.bval;
}

EMSCRIPTEN_KEEPALIVE
void wasmmid_config_item_set_bool(config_item *cfg, int i, bool v)
{
    cfg[i].u.boolean.bval = v;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_config_item_choices(const config_item *cfg, int i)
{
    return cfg[i].u.choices.choicenames;
}

EMSCRIPTEN_KEEPALIVE
int wasmmid_config_item_choice_selected(const config_item *cfg, int i)
{
    return cfg[i].u.choices.selected;
}

EMSCRIPTEN_KEEPALIVE
void wasmmid_config_item_set_choice(config_item *cfg, int i, int selected)
{
    cfg[i].u.choices.selected = selected;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_key_label_text(const key_label *keys, int i)
{
    return keys[i].label;
}

EMSCRIPTEN_KEEPALIVE
int wasmmid_key_label_button(const key_label *keys, int i)
{
    return keys[i].button;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_game_name(const game *g)
{
    return g->name;
}

EMSCRIPTEN_KEEPALIVE
bool wasmmid_game_can_solve(const game *g)
{
    return g->can_solve;
}

EMSCRIPTEN_KEEPALIVE
bool wasmmid_game_can_configure(const game *g)
{
    return g->can_configure;
}

EMSCRIPTEN_KEEPALIVE
bool wasmmid_game_can_format_as_text_ever(const game *g)
{
    return g->can_format_as_text_ever;
}

/* ----------------------------------------------------------------------
 * midend_request_id_changes takes a C function pointer; forward it to
 * a single import instead of asking the host to supply one.
 */
static void wasmmid_ids_changed_trampoline(void *ctx)
{
    wasmmid_ids_changed();
}

EMSCRIPTEN_KEEPALIVE
void wasmmid_midend_request_id_changes(midend *me)
{
    midend_request_id_changes(me, wasmmid_ids_changed_trampoline, NULL);
}

/* ----------------------------------------------------------------------
 * Serialise/deserialise/prefs take read/write callbacks; replace
 * those with plain in-memory buffers; the host already has
 * malloc/free as exports, so it can pass memory it owns directly.
 */
struct wasmmid_write_ctx {
    char *buffer;
    size_t pos;
};

static void wasmmid_write(void *vctx, const void *buf, int len)
{
    struct wasmmid_write_ctx *ctx = (struct wasmmid_write_ctx *)vctx;
    if (ctx->buffer)
        memcpy(ctx->buffer + ctx->pos, buf, len);
    ctx->pos += len;
}

struct wasmmid_read_ctx {
    const char *buffer;
    size_t pos, len;
};

static bool wasmmid_read(void *vctx, void *buf, int len)
{
    struct wasmmid_read_ctx *ctx = (struct wasmmid_read_ctx *)vctx;
    if (len < 0 || ctx->len - ctx->pos < (size_t)len)
        return false;
    memcpy(buf, ctx->buffer + ctx->pos, len);
    ctx->pos += len;
    return true;
}

EMSCRIPTEN_KEEPALIVE
char *wasmmid_serialise(midend *me, int *outlen)
{
    struct wasmmid_write_ctx ctx;

    ctx.buffer = NULL;
    ctx.pos = 0;
    midend_serialise(me, wasmmid_write, &ctx);
    *outlen = ctx.pos;

    ctx.buffer = snewn(ctx.pos, char);
    ctx.pos = 0;
    midend_serialise(me, wasmmid_write, &ctx);
    return ctx.buffer;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_deserialise(midend *me, const char *buf, int len)
{
    struct wasmmid_read_ctx ctx;
    ctx.buffer = buf;
    ctx.pos = 0;
    ctx.len = len;
    return midend_deserialise(me, wasmmid_read, &ctx);
}

EMSCRIPTEN_KEEPALIVE
char *wasmmid_save_prefs(midend *me, int *outlen)
{
    struct wasmmid_write_ctx ctx;

    ctx.buffer = NULL;
    ctx.pos = 0;
    midend_save_prefs(me, wasmmid_write, &ctx);
    *outlen = ctx.pos;

    ctx.buffer = snewn(ctx.pos, char);
    ctx.pos = 0;
    midend_save_prefs(me, wasmmid_write, &ctx);
    return ctx.buffer;
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_load_prefs(midend *me, const char *buf, int len)
{
    struct wasmmid_read_ctx ctx;
    ctx.buffer = buf;
    ctx.pos = 0;
    ctx.len = len;
    return midend_load_prefs(me, wasmmid_read, &ctx);
}

EMSCRIPTEN_KEEPALIVE
const char *wasmmid_identify_game(char **name, const char *buf, int len)
{
    struct wasmmid_read_ctx ctx;
    ctx.buffer = buf;
    ctx.pos = 0;
    ctx.len = len;
    return identify_game(name, wasmmid_read, &ctx);
}

/*
 * Deliberately no main() here. STANDALONE_WASM's command/reactor
 * split (see the WASI application ABI doc) is decided purely by
 * whether main() is defined: with it, Emscripten exports _start and
 * automatically calls proc_exit() once it returns, on the assumption
 * that the module is done; without it, Emscripten exports
 * _initialize instead, which just runs global constructors and
 * returns normally, leaving the module instantiated and ready to
 * answer the exports above indefinitely. A front end calls
 * _initialize once, then drives everything else from outside - which
 * is the reactor behaviour we actually want, not a command's.
 */
