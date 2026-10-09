/*
 * etxhost: EdgeTX's own Lua 5.3 (rotables, packed values, 32-bit numbers) on the host,
 * with a model of how B&W radios allocate Lua memory. Also builds on EdgeTX 2.10's Lua 5.2
 * (doubles; B&W radios there give Lua bins + malloc, no CCM: ETX_MODEL=f2). Used to measure what a script
 * needs on an STM32F2 / STM32F4 radio, including heap fragmentation.
 *
 *   etxhost script.lua [args]       run a Lua file (arg table as in lua.c)
 *
 * Environment:
 *   ETX_MODEL  f2 (default): bins of 200 x 28 B and 50 x 92 B, then newlib-nano malloc
 *              f4: a CCM pool (ETX_CCM bytes) first, then newlib-nano malloc
 *              host: plain malloc, no limit
 *   ETX_HEAP   bytes of malloc heap (default 65536)
 *   ETX_CCM    bytes of CCM pool for f4 (default 34816)
 *   ETX_TESTLIBS=1  also expose table, debug and os.getenv/os.clock (not on B&W radios)
 *
 * Lua gets etx.mem() -> heap high-water mark (sbrk top), heap in use, bins/CCM in use,
 * Lua's own count; etx.resetpeak(); etx.loadfile(path [, mode]) streams a file through
 * luaL_loadfilex like the radio does; etx.dump(f, strip) is string.dump with strip on 5.2 too.
 */
#define LUA_CORE
#if defined(__has_include) && __has_include("lprefix.h")
#include "lprefix.h"                 /* Lua 5.3; EdgeTX 2.10 and older have Lua 5.2 */
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "lstring.h"
#include "ltable.h"
#include "lstate.h"
#include "lgc.h"
#include "lobject.h"
#include "lro_defs.h"
#include "lfunc.h"
#include "lundump.h"

#if LUA_VERSION_NUM < 503                /* EdgeTX 2.10 and older: Lua 5.2, every number a double */
#define lua_isinteger(L, i) (lua_type(L, (i)) == LUA_TNUMBER && lua_tonumber(L, (i)) == (lua_Number)lua_tointeger(L, (i)))
#endif

/* ------------------------------------------------------------------ allocator model */
enum { K_HEAP = 0, K_BIN1, K_BIN2, K_CCM };
typedef struct Blk { size_t size; int kind; unsigned addr; unsigned cost; int pad; } Blk;  /* header before data */

static int model = 0;              /* 0 f2, 1 f4, 2 host */
static unsigned heapSize = 65536, ccmSize = 34816;
static int bin1 = 0, bin2 = 0, bin1Peak = 0, bin2Peak = 0;
static unsigned heapUsed = 0, heapPeakUsed = 0, heapTop = 0, heapTopPeak = 0, ccmUsed = 0, ccmPeak = 0;
static unsigned long failures = 0;

/* newlib-nano style free list: address ordered, first fit, split, coalesce */
typedef struct Free { unsigned addr, size; struct Free *next; } Free;
static Free *heapFree = NULL, *ccmFree = NULL;
static int ccmInit = 0;

static unsigned nanoCost(size_t n) {
  unsigned a = ((unsigned)n + 3u) & ~3u;
  a += 4 + 4;                      /* padding + chunk head */
  return a < 16 ? 16 : a;
}

static int listTake(Free **list, unsigned cost, unsigned *addr, int bestFit) {
  Free **pp = list, **pick = NULL;
  for (; *pp; pp = &(*pp)->next) {
    if ((*pp)->size >= cost) {
      if (!bestFit) { pick = pp; break; }
      if (!pick || (*pp)->size > (*pick)->size) pick = pp;   /* ccm_allocator picks the largest */
    }
  }
  if (!pick) return 0;
  Free *f = *pick;
  if (f->size - cost >= 16) {      /* split: both allocators hand out the end part */
    f->size -= cost;
    *addr = f->addr + f->size;
  } else {
    *addr = f->addr;
    *pick = f->next;
    free(f);
  }
  return 1;
}

static void listGive(Free **list, unsigned addr, unsigned size) {
  Free **pp = list;
  while (*pp && (*pp)->addr < addr) pp = &(*pp)->next;
  Free *n = (Free *)malloc(sizeof(Free));
  n->addr = addr; n->size = size; n->next = *pp; *pp = n;
  /* merge with next */
  if (n->next && n->addr + n->size == n->next->addr) {
    Free *x = n->next; n->size += x->size; n->next = x->next; free(x);
  }
  /* merge with previous */
  Free *p = *list;
  if (p != n) {
    while (p && p->next != n) p = p->next;
    if (p && p->addr + p->size == n->addr) { p->size += n->size; p->next = n->next; free(n); }
  }
}

static int nanoMerge = 1;         /* newer newlib-nano grows a free chunk at the heap end */
static int heapAlloc(unsigned cost, unsigned *addr) {
  if (listTake(&heapFree, cost, addr, 0)) { heapUsed += cost; goto ok; }
  if (nanoMerge && heapFree) {
    Free **pp = &heapFree;
    while ((*pp)->next) pp = &(*pp)->next;
    Free *last = *pp;
    if (last->addr + last->size == heapTop && heapTop - last->size + cost <= heapSize) {
      heapTop = last->addr + cost;
      *addr = last->addr; heapUsed += cost;
      *pp = NULL; free(last);
      goto ok;
    }
  }
  if (heapTop + cost > heapSize) return 0;
  *addr = heapTop; heapTop += cost; heapUsed += cost;
ok:
  if (heapUsed > heapPeakUsed) heapPeakUsed = heapUsed;
  if (heapTop > heapTopPeak) heapTopPeak = heapTop;
  return 1;
}

static void heapRelease(unsigned addr, unsigned cost) {
  heapUsed -= cost;
  listGive(&heapFree, addr, cost);
}

static int ccmAlloc(size_t n, unsigned *addr, unsigned *cost) {
  if (!ccmInit) { ccmInit = 1; listGive(&ccmFree, 0, ccmSize); }
  unsigned c = ((unsigned)n + 4u + 3u) & ~3u;
  if (!listTake(&ccmFree, c, addr, 1)) return 0;
  *cost = c; ccmUsed += c; if (ccmUsed > ccmPeak) ccmPeak = ccmUsed;
  return 1;
}

static Blk *hdr(void *p) { return (Blk *)((char *)p - sizeof(Blk)); }

/* a new block of n bytes: bins / ccm first, then the heap */
static void *newBlock(size_t n, int tryPools) {
  int kind = K_HEAP; unsigned addr = 0, cost = 0;
  if (tryPools && model == 0) {
    if (n <= 28 && bin1 < 200) { kind = K_BIN1; bin1++; if (bin1 > bin1Peak) bin1Peak = bin1; }
    else if (n <= 92 && bin2 < 50) { kind = K_BIN2; bin2++; if (bin2 > bin2Peak) bin2Peak = bin2; }
  } else if (tryPools && model == 1) {
    if (ccmAlloc(n, &addr, &cost)) kind = K_CCM;
  }
  if (kind == K_HEAP) {
    cost = nanoCost(n);
    if (!heapAlloc(cost, &addr)) { failures++; return NULL; }
  }
  /* host memory for the whole capacity: blocks may grow in place up to it */
  size_t cap = kind == K_BIN1 ? 28 : kind == K_BIN2 ? 92 : kind == K_CCM ? cost - 4 : cost - 8;
  if (cap < n) cap = n;
  Blk *b = (Blk *)malloc(sizeof(Blk) + cap);
  b->size = n; b->kind = kind; b->addr = addr; b->cost = cost;
  return (char *)b + sizeof(Blk);
}

static void freeBlock(void *p) {
  Blk *b = hdr(p);
  if (b->kind == K_BIN1) bin1--;
  else if (b->kind == K_BIN2) bin2--;
  else if (b->kind == K_CCM) { ccmUsed -= b->cost; listGive(&ccmFree, b->addr, b->cost); }
  else heapRelease(b->addr, b->cost);
  free(b);
}

static void *modelAlloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)osize;
  if (model == 2 || ud != NULL) {                 /* host model, or the test driver's own state */
    if (nsize == 0) { free(ptr); return NULL; }
    return realloc(ptr, nsize);
  }
  if (nsize == 0) { if (ptr) freeBlock(ptr); return NULL; }
  if (!ptr) return newBlock(nsize, 1);
  Blk *b = hdr(ptr);
  if (b->kind == K_BIN1 || b->kind == K_BIN2) {
    if (nsize <= (b->kind == K_BIN1 ? 28u : 92u)) { b->size = nsize; return ptr; }
    void *n = newBlock(nsize, 1);                 /* bin_malloc, then libc malloc */
    if (!n) return NULL;
    memcpy(n, ptr, b->size < nsize ? b->size : nsize);
    freeBlock(ptr);
    return n;
  }
  if (b->kind == K_CCM) {                          /* ccm realloc: new block, copy, free */
    void *n = newBlock(nsize, 1);
    if (!n) return NULL;
    memcpy(n, ptr, b->size < nsize ? b->size : nsize);
    freeBlock(ptr);
    return n;
  }
  /* newlib-nano realloc: keep the block if it is big enough and not twice too big */
  {
    unsigned usable = b->cost - 8;
    if (nsize <= usable && (usable >> 1) < nsize) { b->size = nsize; return ptr; }
    void *n = newBlock(nsize, 0);
    if (!n) return NULL;
    memcpy(n, ptr, b->size < nsize ? b->size : nsize);
    freeBlock(ptr);
    return n;
  }
}

/* ------------------------------------------------------------------ libraries */
LUA_API int lua_pushstringsarray(lua_State *L, int opt) { (void)L; (void)opt; return 0; }  /* debug.getstrings: unused */

extern LROT_TABLE(strlib);
extern LROT_TABLE(mathlib);
extern LROT_TABLE(bitlib);
extern LROT_TABLE(tablib);
#if LUA_VERSION_NUM >= 503
extern LROT_TABLE(dblib);                 /* Lua 5.2 has the debug library in RAM */
#endif
extern LROT_TABLE(base_func);
extern LROT_TABLE(rotables_meta);

static int etx_mem(lua_State *L) {
  lua_pushinteger(L, heapTopPeak);
  lua_pushinteger(L, heapUsed);
  lua_pushinteger(L, model == 0 ? (bin1 * 28 + bin2 * 92) : ccmUsed);
  lua_pushinteger(L, (lua_gc(L, LUA_GCCOUNT, 0) << 10) + lua_gc(L, LUA_GCCOUNTB, 0));
  lua_pushinteger(L, heapPeakUsed);
  lua_pushinteger(L, model == 0 ? (bin1Peak * 28 + bin2Peak * 92) : ccmPeak);
  lua_pushinteger(L, (lua_Integer)failures);
  lua_pushinteger(L, heapTop);
  return 8;
}

static int etx_heapinfo(lua_State *L) {         /* free bytes in holes, largest hole, top, size */
  unsigned tot = 0, big = 0;
  for (Free *f = heapFree; f; f = f->next) { tot += f->size; if (f->size > big) big = f->size; }
  lua_pushinteger(L, tot); lua_pushinteger(L, big); lua_pushinteger(L, heapTop); lua_pushinteger(L, heapSize);
  return 4;
}

static int etx_resetpeak(lua_State *L) {
  (void)L;
  heapTopPeak = heapTop; heapPeakUsed = heapUsed; bin1Peak = bin1; bin2Peak = bin2; ccmPeak = ccmUsed;
  return 0;
}

static int etx_loadfile(lua_State *L) {
  const char *fn = luaL_checkstring(L, 1);
  const char *mode = luaL_optstring(L, 2, NULL);
  if (luaL_loadfilex(L, fn, mode) != LUA_OK) { lua_pushnil(L); lua_insert(L, -2); return 2; }
  return 1;
}

static int etx_getenv(lua_State *L) {
  const char *v = getenv(luaL_checkstring(L, 1));
  if (v) lua_pushstring(L, v); else lua_pushnil(L);
  return 1;
}

static int etx_clock(lua_State *L) {
  lua_pushnumber(L, (lua_Number)clock() / (lua_Number)CLOCKS_PER_SEC);
  return 1;
}

static int etx_writefile(lua_State *L) {         /* host only: write a string to a file */
  size_t n; const char *fn = luaL_checkstring(L, 1); const char *s = luaL_checklstring(L, 2, &n);
  FILE *f = fopen(fn, "wb");
  if (!f) return luaL_error(L, "cannot write %s", fn);
  fwrite(s, 1, n, f); fclose(f);
  return 0;
}

static int dumpWriter(lua_State *L, const void *p, size_t n, void *B) {
  (void)L; luaL_addlstring((luaL_Buffer *)B, (const char *)p, n); return 0;
}
static int etx_dump(lua_State *L) {              /* string.dump(f, strip), also on Lua 5.2 */
  int strip = lua_toboolean(L, 2), st;
  luaL_Buffer b;
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_settop(L, 1);
  luaL_buffinit(L, &b);
#if LUA_VERSION_NUM >= 503
  st = lua_dump(L, dumpWriter, &b, strip);
#else
  st = isLfunction(L->top - 1) ? luaU_dump(L, getproto(L->top - 1), dumpWriter, &b, strip) : 1;
#endif
  if (st != 0) return luaL_error(L, "unable to dump given function");
  luaL_pushresult(&b);
  return 1;
}

LROT_BEGIN(etxhostlib, NULL, 0)
  LROT_FUNCENTRY(dump, etx_dump)
  LROT_FUNCENTRY(mem, etx_mem)
  LROT_FUNCENTRY(resetpeak, etx_resetpeak)
  LROT_FUNCENTRY(heapinfo, etx_heapinfo)
  LROT_FUNCENTRY(loadfile, etx_loadfile)
  LROT_FUNCENTRY(writefile, etx_writefile)
LROT_END(etxhostlib, NULL, 0)

LROT_BEGIN(oshost, NULL, 0)
  LROT_FUNCENTRY(getenv, etx_getenv)
  LROT_FUNCENTRY(clock, etx_clock)
LROT_END(oshost, NULL, 0)

static const ROTable *const globalSymbols[] = { LROT_TABLEREF(base_func), NULL };

/* global lookups that miss _G: look in the ROM symbol tables (as EdgeTX's linit.c does) */
static int indexHook(lua_State *L) {
  const ROTable *const *t = globalSymbols;
  const TValue *res = luaO_nilobject;
  TString *key;
  lua_lock(L);
  key = tsvalue(L->top - 1);
  for (; *t; t++) {
    res = luaH_getstr((Table *)*t, key);
    if (!ttisnil(res)) break;
  }
  if (ttislightuserdata(res)) {          /* strings are stored as light userdata */
    setsvalue2s(L, L->top - 1, luaS_new(L, pvalue(res)));
  } else {
    setobj2s(L, L->top - 1, res);
  }
  lua_unlock(L);
  return 1;
}

LROT_BEGIN(rotables_meta, NULL, LROT_MASK_INDEX)
  LROT_FUNCENTRY(__index, indexHook)
LROT_END(rotables_meta, NULL, LROT_MASK_INDEX)

/* what B&W radios have: base, string, math, bit32 (+ io, lcd, model... mocked in Lua) */
LROT_BEGIN(rotables, LROT_TABLEREF(rotables_meta), 0)
  LROT_TABENTRY(_G, base_func)
  LROT_TABENTRY(string, strlib)
  LROT_TABENTRY(math, mathlib)
  LROT_TABENTRY(bit32, bitlib)
  LROT_TABENTRY(etx, etxhostlib)
  LROT_TABENTRY(ROM, rotables)
LROT_END(rotables, LROT_TABLEREF(rotables_meta), 0)

LUALIB_API void luaL_openlibs(lua_State *L) {
  luaL_requiref(L, "_G", luaopen_base, 1);
  lua_pop(L, 1);
}

/* ------------------------------------------------------------------ radio mode
 * etxhost -radio driver.lua [args]: the driver runs in its own Lua state (plain malloc, full
 * test libraries) and drives a second state, the "radio", that holds only what a radio would
 * hold: EdgeTX's base libraries in ROM, the radio API as C functions in ROM, and the script.
 * Only the radio state goes through the allocator model, so its numbers are the script's own.
 */
static lua_State *Lrad = NULL;
static int radW = 128, radH = 64;
static long radClock = 0;                          /* ms */
static int radStick[4] = { 0, 0, -1024, 0 };
static long lcdCalls = 0, lcdBad = 0, lcdLines = 0;

static int r_getTime(lua_State *L) { lua_pushinteger(L, radClock / 10); return 1; }
static int r_getValue(lua_State *L) {
  int id = (int)luaL_checkinteger(L, 1);
  lua_pushinteger(L, id >= 1 && id <= 4 ? radStick[id - 1] : 0);
  return 1;
}
static int r_getFieldInfo(lua_State *L) {
  const char *n = luaL_checkstring(L, 1);
  int id = !strcmp(n, "ail") ? 1 : !strcmp(n, "ele") ? 2 : !strcmp(n, "thr") ? 3 : !strcmp(n, "rud") ? 4 : 0;
  if (!id) return 0;
  lua_createtable(L, 0, 4);                        /* the radio returns id, name, desc, unit */
  lua_pushinteger(L, id); lua_setfield(L, -2, "id");
  lua_pushstring(L, n); lua_setfield(L, -2, "name");
  return 1;
}
static int r_nop(lua_State *L) { (void)L; lcdCalls++; return 0; }
static int r_grey(lua_State *L) { lua_pushinteger(L, luaL_checkinteger(L, 1) * 0x10000); return 1; }
static int r_line(lua_State *L) {                  /* B&W: every point must be on the screen */
  int i; lcdCalls++; lcdLines++;
  for (i = 1; i <= 4; i++) {
    lua_Number v = luaL_checknumber(L, i);
    int lim = (i % 2) ? radW : radH;
    if (v < 0 || v >= lim) { lcdBad++; break; }
  }
  return 0;
}
/* color radios: drawLine drops a line with an end past the right or bottom edge */
static int r_cline(lua_State *L) {
  int i; lcdCalls++; lcdLines++;
  for (i = 1; i <= 4; i++) {
    lua_Number v = luaL_checknumber(L, i);
    if (v > ((i % 2) ? radW : radH)) { lcdBad++; break; }
  }
  return 0;
}
static int r_rgb(lua_State *L) {
  lua_pushinteger(L, (luaL_checkinteger(L, 1) * 65536 + luaL_checkinteger(L, 2) * 256 + luaL_checkinteger(L, 3)) * 2 + 1);
  return 1;
}
static int r_sizeText(lua_State *L) {
  size_t l; luaL_checklstring(L, 1, &l);
  lua_pushinteger(L, (lua_Integer)l * 9); lua_pushinteger(L, 17);
  return 2;
}
/* io on a small in-memory SD card: files the script writes, and files read from the real
   folder given by radio.sdroot(); io.open allocates a FatFs FIL in the Lua heap like the radio */
#define NFILES 16
static struct { char path[160]; char data[4096]; size_t len; int used; } vfs[NFILES];
static char sdRoot[400] = ".";
static int vfsFind(const char *p, int create) {
  int i, free_ = -1;
  for (i = 0; i < NFILES; i++) {
    if (vfs[i].used && !strcmp(vfs[i].path, p)) return i;
    if (!vfs[i].used && free_ < 0) free_ = i;
  }
  if (!create || free_ < 0) return -1;
  vfs[free_].used = 1; vfs[free_].len = 0;
  snprintf(vfs[free_].path, sizeof(vfs[free_].path), "%s", p);
  return free_;
}
typedef struct { int mode; int idx; size_t pos; char fil[544]; } RFile;
static int r_open(lua_State *L) {
  const char *p = luaL_checkstring(L, 1), *m = luaL_optstring(L, 2, "r");
  int i = vfsFind(p, 0);
  if (m[0] == 'r') {
    if (i < 0) {
      char full[600];
      snprintf(full, sizeof(full), "%s%s", sdRoot, p);
      FILE *f = fopen(full, "rb");
      if (!f) return 0;
      i = vfsFind(p, 1);
      if (i < 0) { fclose(f); return 0; }
      vfs[i].len = fread(vfs[i].data, 1, sizeof(vfs[i].data) - 1, f);
      fclose(f);
    }
  } else {
    i = vfsFind(p, 1);
    if (i < 0) return 0;
    vfs[i].len = 0;
  }
  RFile *f = (RFile *)lua_newuserdata(L, sizeof(RFile));
  f->mode = m[0]; f->idx = i; f->pos = 0;
  return 1;
}
static int r_read(lua_State *L) {                 /* like EdgeTX's read_chars: a buffer of n bytes */
  RFile *f = (RFile *)lua_touserdata(L, 1);
  size_t n = (size_t)luaL_checkinteger(L, 2), nr;
  luaL_Buffer b;
  char *p;
  if (!f) return 0;
  luaL_buffinit(L, &b);
  p = luaL_prepbuffsize(&b, n);
  nr = vfs[f->idx].len - f->pos;
  if (nr > n) nr = n;
  memcpy(p, vfs[f->idx].data + f->pos, nr);
  f->pos += nr;
  luaL_addsize(&b, nr);
  luaL_pushresult(&b);
  return 1;
}
static int r_write(lua_State *L) {
  RFile *f = (RFile *)lua_touserdata(L, 1);
  int i, n = lua_gettop(L);
  if (!f) return 0;
  for (i = 2; i <= n; i++) {
    size_t l; const char *d = luaL_checklstring(L, i, &l);
    if (vfs[f->idx].len + l < sizeof(vfs[f->idx].data)) { memcpy(vfs[f->idx].data + vfs[f->idx].len, d, l); vfs[f->idx].len += l; }
  }
  return 0;
}
static int r_close(lua_State *L) { (void)L; return 0; }

/* loadScript(file [, mode [, env]]): like the radio, .luac for "b", .lua for "t", "bt" = binary
   first (the radio takes the newer of the two). A binary that does not load gives its own error
   in "b" mode (out of memory, for one), as on the radio.
   env as in EdgeTX's api_general.cpp, which clears the stack before it reads that argument: a
   chunk loaded with one gets nil as its _ENV, no globals at all. */
static int r_loadScriptFile(lua_State *L, const char *fn, const char *mode);
static int r_loadScript(lua_State *L) {
  const char *fn = luaL_checkstring(L, 1), *mode = luaL_optstring(L, 2, "bt");
  int env = !lua_isnone(L, 3) ? 3 : 0, n;
  char fnc[600], modec[8];
  snprintf(fnc, sizeof(fnc), "%s", fn);
  snprintf(modec, sizeof(modec), "%s", mode);
  lua_settop(L, 0);
  n = r_loadScriptFile(L, fnc, modec);
  if (n == 1 && env) {
    lua_pushvalue(L, env);
    if (!lua_setupvalue(L, -2, 1)) lua_pop(L, 1);
  }
  return n;
}
static int r_loadScriptFile(lua_State *L, const char *fn, const char *mode) {
  char base[600], path[620];
  size_t n = strlen(fn);
  if (n > 4 && !strcmp(fn + n - 4, ".lua")) n -= 4;
  else if (n > 5 && !strcmp(fn + n - 5, ".luac")) n -= 5;
  snprintf(base, sizeof(base), "%s%.*s", sdRoot, (int)n, fn);
  if (strchr(mode, 'b')) {
    snprintf(path, sizeof(path), "%s.luac", base);
    FILE *f = fopen(path, "rb");
    if (f) {
      fclose(f);
      if (luaL_loadfilex(L, path, NULL) == LUA_OK) return 1;
      if (!strchr(mode, 't')) { lua_pushnil(L); lua_insert(L, -2); return 2; }
      lua_pop(L, 1);
    }
  }
  if (strchr(mode, 't') || !strchr(mode, 'b')) {
    snprintf(path, sizeof(path), "%s.lua", base);
    if (luaL_loadfilex(L, path, NULL) == LUA_OK) return 1;
    lua_pushnil(L); lua_insert(L, -2);
    return 2;
  }
  lua_pushnil(L); lua_pushfstring(L, "loadScript(\"%s\", \"%s\") error: File not found", fn, mode);
  return 2;
}

LROT_BEGIN(radio_lcd, NULL, 0)
  LROT_FUNCENTRY(clear, r_nop)
  LROT_FUNCENTRY(drawLine, r_line)
  LROT_FUNCENTRY(drawText, r_nop)
  LROT_FUNCENTRY(drawNumber, r_nop)
  LROT_FUNCENTRY(drawRectangle, r_nop)
  LROT_FUNCENTRY(drawFilledRectangle, r_nop)
  LROT_FUNCENTRY(drawPoint, r_nop)
LROT_END(radio_lcd, NULL, 0)

LROT_BEGIN(radio_io, NULL, 0)
  LROT_FUNCENTRY(open, r_open)
  LROT_FUNCENTRY(read, r_read)
  LROT_FUNCENTRY(write, r_write)
  LROT_FUNCENTRY(close, r_close)
LROT_END(radio_io, NULL, 0)

/* B&W radio constants (values as in the test harness) and the general API */
LROT_BEGIN(radio_api, NULL, 0)
  LROT_TABENTRY(lcd, radio_lcd)
  LROT_TABENTRY(io, radio_io)
  LROT_FUNCENTRY(getTime, r_getTime)
  LROT_FUNCENTRY(getValue, r_getValue)
  LROT_FUNCENTRY(getFieldInfo, r_getFieldInfo)
  LROT_FUNCENTRY(playTone, r_nop)
  LROT_FUNCENTRY(playFile, r_nop)
  LROT_FUNCENTRY(playHaptic, r_nop)
  LROT_NUMENTRY(PLAY_NOW, 0x10) LROT_NUMENTRY(PLAY_BACKGROUND, 0x20)
  LROT_FUNCENTRY(loadScript, r_loadScript)
  LROT_NUMENTRY(BLINK, 0x01) LROT_NUMENTRY(INVERS, 0x02) LROT_NUMENTRY(BOLD, 0x40) LROT_NUMENTRY(LEFT, 0)
  LROT_NUMENTRY(RIGHT, 0x04) LROT_NUMENTRY(CENTER, 0x20) LROT_NUMENTRY(PREC1, 0x20) LROT_NUMENTRY(PREC2, 0x30)
  LROT_NUMENTRY(FORCE, 0x02) LROT_NUMENTRY(ERASE, 0x04) LROT_NUMENTRY(ROUND, 0x08) LROT_NUMENTRY(TINSIZE, 0x100)
  LROT_NUMENTRY(SMLSIZE, 0x200) LROT_NUMENTRY(MIDSIZE, 0x300) LROT_NUMENTRY(DBLSIZE, 0x400) LROT_NUMENTRY(XXLSIZE, 0x500)
  LROT_NUMENTRY(SOLID, 0xff) LROT_NUMENTRY(DOTTED, 0x55)
  LROT_NUMENTRY(EVT_VIRTUAL_ENTER, 514) LROT_NUMENTRY(EVT_VIRTUAL_EXIT, 513) LROT_NUMENTRY(EVT_VIRTUAL_NEXT, 7680)
  LROT_NUMENTRY(EVT_VIRTUAL_PREV, 7424) LROT_NUMENTRY(EVT_VIRTUAL_INC, 7680) LROT_NUMENTRY(EVT_VIRTUAL_DEC, 7424)
  LROT_NUMENTRY(EVT_VIRTUAL_MENU, 518) LROT_NUMENTRY(EVT_ENTER_BREAK, 514) LROT_NUMENTRY(EVT_EXIT_BREAK, 513)
LROT_END(radio_api, NULL, 0)

static const ROTable *const radioSymbols[] = { LROT_TABLEREF(base_func), LROT_TABLEREF(radio_api), NULL };
static int radioIndexHook(lua_State *L) {
  const ROTable *const *t = radioSymbols;
  const TValue *res = luaO_nilobject;
  TString *key;
  lua_lock(L);
  key = tsvalue(L->top - 1);
  for (; *t; t++) {
    res = luaH_getstr((Table *)*t, key);
    if (!ttisnil(res)) break;
  }
  if (ttislightuserdata(res)) {
    setsvalue2s(L, L->top - 1, luaS_new(L, pvalue(res)));
  } else {
    setobj2s(L, L->top - 1, res);
  }
  lua_unlock(L);
  return 1;
}
LROT_BEGIN(radio_meta, NULL, LROT_MASK_INDEX)
  LROT_FUNCENTRY(__index, radioIndexHook)
LROT_END(radio_meta, NULL, LROT_MASK_INDEX)

LROT_BEGIN(radio_rotables, LROT_TABLEREF(radio_meta), 0)
  LROT_TABENTRY(string, strlib)
  LROT_TABENTRY(math, mathlib)
  LROT_TABENTRY(bit32, bitlib)
LROT_END(radio_rotables, LROT_TABLEREF(radio_meta), 0)

/* copy simple values between the two states */
static int xmove(lua_State *from, lua_State *to, int first, int last) {
  int i, n = 0;
  for (i = first; i <= last; i++, n++) {
    switch (lua_type(from, i)) {
      case LUA_TNUMBER:
        if (lua_isinteger(from, i)) lua_pushinteger(to, lua_tointeger(from, i)); else lua_pushnumber(to, lua_tonumber(from, i));
        break;
      case LUA_TBOOLEAN: lua_pushboolean(to, lua_toboolean(from, i)); break;
      case LUA_TSTRING: lua_pushstring(to, lua_tostring(from, i)); break;
      default: lua_pushnil(to);
    }
  }
  return n;
}

static int d_new(lua_State *L) {                   /* radio.new(W, H [, color]): a fresh radio */
  int color = lua_toboolean(L, 3);
  radW = (int)luaL_checkinteger(L, 1); radH = (int)luaL_checkinteger(L, 2);
  if (Lrad) lua_close(Lrad);
  heapUsed = heapPeakUsed = heapTop = heapTopPeak = ccmUsed = ccmPeak = 0;
  bin1 = bin2 = bin1Peak = bin2Peak = 0; failures = 0;
  while (heapFree) { Free *f = heapFree; heapFree = f->next; free(f); }
  while (ccmFree) { Free *f = ccmFree; ccmFree = f->next; free(f); } ccmInit = 0;
  lcdCalls = lcdBad = lcdLines = 0;
  memset(vfs, 0, sizeof(vfs));
  Lrad = lua_newstate(modelAlloc, NULL);
  if (!Lrad) return luaL_error(L, "no radio state");
  luaL_requiref(Lrad, "_G", luaopen_base, 1);      /* _G with the ROM tables behind it */
  lua_pop(Lrad, 1);
  lua_pushglobaltable(Lrad);                       /* globals: radio API first, then base functions */
  lua_getmetatable(Lrad, -1);
  lua_pushrotable(Lrad, LROT_TABLEREF(radio_rotables));
  lua_setfield(Lrad, -2, "__index");
  lua_pop(Lrad, 2);
  lua_pushinteger(Lrad, radW); lua_setglobal(Lrad, "LCD_W");
  lua_pushinteger(Lrad, radH); lua_setglobal(Lrad, "LCD_H");
  if (radW == 212) { lua_pushcfunction(Lrad, r_grey); lua_setglobal(Lrad, "GREY"); }
  if (color) {                                     /* a color radio: its lcd and flag values */
    static const struct { const char *n; lua_CFunction f; } fn[] = {
      { "clear", r_nop }, { "drawLine", r_cline }, { "drawText", r_nop }, { "drawNumber", r_nop },
      { "drawRectangle", r_nop }, { "drawFilledRectangle", r_nop }, { "drawPoint", r_nop },
      { "RGB", r_rgb }, { "sizeText", r_sizeText } };
    static const struct { const char *n; lua_Integer v; } cst[] = {
      { "LEFT", 0 }, { "RIGHT", 0x40000 }, { "CENTER", 0x80000 }, { "INVERS", 0x100000 }, { "BLINK", 0x200000 },
      { "BOLD", 0x400 }, { "PREC1", 0x800000 }, { "PREC2", 0x1000000 }, { "TINSIZE", 0x200 }, { "SMLSIZE", 0x300 },
      { "MIDSIZE", 0x400 }, { "DBLSIZE", 0x500 }, { "XXLSIZE", 0x600 } };
    size_t i;
    lua_createtable(Lrad, 0, 9);
    for (i = 0; i < sizeof(fn) / sizeof(fn[0]); i++) { lua_pushcfunction(Lrad, fn[i].f); lua_setfield(Lrad, -2, fn[i].n); }
    lua_setglobal(Lrad, "lcd");
    for (i = 0; i < sizeof(cst) / sizeof(cst[0]); i++) { lua_pushinteger(Lrad, cst[i].v); lua_setglobal(Lrad, cst[i].n); }
  }
  lua_gc(Lrad, LUA_GCCOLLECT, 0);
  return 0;
}

static int d_load(lua_State *L) {                  /* radio.load(path, withTestHooks) */
  const char *path = luaL_checkstring(L, 1);
  if (lua_toboolean(L, 2)) { lua_newtable(Lrad); lua_setglobal(Lrad, "STICKTIME_TEST"); }
  lua_settop(Lrad, 0);
  if (luaL_loadfilex(Lrad, path, NULL) != LUA_OK) {
    lua_pushnil(L); lua_pushstring(L, lua_tostring(Lrad, -1)); lua_settop(Lrad, 0);
    return 2;
  }
  if (lua_pcall(Lrad, 0, 1, 0) != LUA_OK) {
    lua_pushnil(L); lua_pushstring(L, lua_tostring(Lrad, -1)); lua_settop(Lrad, 0);
    return 2;
  }
  lua_setglobal(Lrad, "__script");                 /* (one hash entry; the radio keeps a registry ref) */
  lua_gc(Lrad, LUA_GCCOLLECT, 0);
  lua_pushboolean(L, 1);
  return 1;
}

/* radio.call(name, ...): __script[name](...) for init/run, or STICKTIME_TEST[name](...) with "T." */
static int d_call(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  int n = lua_gettop(L), top;
  lua_settop(Lrad, 0);
  if (!strncmp(name, "T.", 2)) { lua_getglobal(Lrad, "STICKTIME_TEST"); name += 2; }
  else lua_getglobal(Lrad, "__script");
  if (!lua_istable(Lrad, -1)) return luaL_error(L, "radio: no table for %s", name);
  lua_getfield(Lrad, -1, name);
  if (!lua_isfunction(Lrad, -1)) return luaL_error(L, "radio: no function %s", name);
  xmove(L, Lrad, 2, n);
  if (lua_pcall(Lrad, n - 1, LUA_MULTRET, 0) != LUA_OK) {
    lua_pushboolean(L, 0); lua_pushstring(L, lua_tostring(Lrad, -1)); lua_settop(Lrad, 0);
    return 2;
  }
  top = lua_gettop(Lrad);
  lua_pushboolean(L, 1);
  n = xmove(Lrad, L, 2, top);
  lua_settop(Lrad, 0);
  if (!strcmp(name, "init")) {                     /* EdgeTX drops init() once it has run */
    lua_getglobal(Lrad, "__script");
    if (lua_istable(Lrad, -1)) { lua_pushnil(Lrad); lua_setfield(Lrad, -2, "init"); }
    lua_settop(Lrad, 0);
  }
  return n + 1;
}

static int d_set(lua_State *L) {                   /* radio.set(clockMs, ail, ele, thr, rud) */
  radClock = (long)luaL_checkinteger(L, 1);
  for (int i = 0; i < 4; i++) if (!lua_isnoneornil(L, i + 2)) radStick[i] = (int)luaL_checkinteger(L, i + 2);
  return 0;
}
static int d_gcstep(lua_State *L) { lua_gc(Lrad, LUA_GCSTEP, (int)luaL_optinteger(L, 1, 10)); return 0; }
static int d_gcfull(lua_State *L) { (void)L; lua_gc(Lrad, LUA_GCCOLLECT, 0); return 0; }
static int d_mem(lua_State *L) {
  unsigned tot = 0, big = 0;
  for (Free *f = heapFree; f; f = f->next) { tot += f->size; if (f->size > big) big = f->size; }
  lua_pushinteger(L, (lua_gc(Lrad, LUA_GCCOUNT, 0) << 10) + lua_gc(Lrad, LUA_GCCOUNTB, 0));
  lua_pushinteger(L, heapTopPeak);
  lua_pushinteger(L, heapTop);
  lua_pushinteger(L, heapUsed);
  lua_pushinteger(L, model == 0 ? (bin1Peak * 28 + bin2Peak * 92) : ccmPeak);
  lua_pushinteger(L, (lua_Integer)failures);
  lua_pushinteger(L, tot);
  lua_pushinteger(L, big);
  lua_pushinteger(L, model == 0 ? (bin1 * 28 + bin2 * 92) : ccmUsed);
  return 9;
}
static int d_resetpeak(lua_State *L) {
  (void)L; heapTopPeak = heapTop; heapPeakUsed = heapUsed; bin1Peak = bin1; bin2Peak = bin2; ccmPeak = ccmUsed;
  return 0;
}
static int d_lcd(lua_State *L) {
  lua_pushinteger(L, lcdCalls); lua_pushinteger(L, lcdLines); lua_pushinteger(L, lcdBad);
  return 3;
}
static int d_file(lua_State *L) {                  /* radio.file(path): what the script wrote */
  int i = vfsFind(luaL_checkstring(L, 1), 0);
  if (i < 0) return 0;
  lua_pushlstring(L, vfs[i].data, vfs[i].len);
  return 1;
}
static int d_setfile(lua_State *L) {               /* radio.setfile(path, data | nil) */
  const char *p = luaL_checkstring(L, 1);
  size_t l; const char *d = luaL_optlstring(L, 2, NULL, &l);
  int i = vfsFind(p, d != NULL);
  if (i < 0) return 0;
  if (!d) { vfs[i].used = 0; return 0; }
  if (l >= sizeof(vfs[i].data)) l = sizeof(vfs[i].data) - 1;
  memcpy(vfs[i].data, d, l); vfs[i].len = l;
  return 0;
}
static int d_sdroot(lua_State *L) { snprintf(sdRoot, sizeof(sdRoot), "%s", luaL_checkstring(L, 1)); return 0; }
static int d_heap(lua_State *L) { heapSize = (unsigned)luaL_checkinteger(L, 1); if (lua_isinteger(L, 2)) model = (int)lua_tointeger(L, 2); return 0; }

/* radio.census(): what the radio state holds, by object type (sizes as Lua accounts them) */
#if LUA_VERSION_NUM < 503
static int d_census(lua_State *L) { lua_newtable(L); return 1; }   /* Lua 5.3 objects only */
#else
static int d_census(lua_State *L) {
  global_State *g = G(Lrad);
  GCObject *o;
  long n[10] = {0}, b[10] = {0};
  long code = 0, kc = 0, upd = 0, protos = 0, cl = 0, clup = 0, strs = 0, tabs = 0, tarr = 0, thash = 0;
  for (o = g->allgc; o; o = o->next) {
    switch (o->tt) {
      case LUA_TSHRSTR: case LUA_TLNGSTR: {
        TString *ts = gco2ts(o);
        size_t len = o->tt == LUA_TSHRSTR ? ts->shrlen : ts->u.lnglen;
        strs++; b[0] += sizeof(TString) + len + 1; break;
      }
      case LUA_TTABLE: {
        Table *t = gco2t(o);
        tabs++; tarr += t->sizearray; thash += isdummy(t) ? 0 : (1 << t->lsizenode);
        b[1] += sizeof(Table) + sizeof(TValue) * t->sizearray + (isdummy(t) ? 0 : sizeof(Node) * (1 << t->lsizenode));
        break;
      }
      case LUA_TLCL: {
        LClosure *c = gco2lcl(o);
        cl++; clup += c->nupvalues; b[2] += sizeLclosure(c->nupvalues); break;
      }
      case LUA_TPROTO: {
        Proto *f = gco2p(o);
        protos++; code += f->sizecode; kc += f->sizek; upd += f->sizeupvalues;
        b[3] += sizeof(Proto) + sizeof(Instruction) * f->sizecode + sizeof(TValue) * f->sizek + sizeof(Proto *) * f->sizep +
                sizeof(Upvaldesc) * f->sizeupvalues + sizeof(int) * f->sizelineinfo + sizeof(LocVar) * f->sizelocvars;
        break;
      }
      case LUA_TUSERDATA: b[4] += sizeludata(gco2u(o)->len); n[4]++; break;
      default: b[5] += 32; n[5]++;
    }
  }
  lua_createtable(L, 0, 16);
#define F(k, v) lua_pushinteger(L, v); lua_setfield(L, -2, k)
  F("strings", strs); F("stringBytes", b[0]);
  F("tables", tabs); F("tableBytes", b[1]); F("tableArray", tarr); F("tableHash", thash);
  F("closures", cl); F("closureUpvals", clup); F("closureBytes", b[2]);
  F("protos", protos); F("protoBytes", b[3]); F("instructions", code); F("constants", kc); F("upvalDescs", upd);
  F("userdata", n[4]); F("userdataBytes", b[4]); F("other", n[5]);
  F("sizeofProto", sizeof(Proto)); F("sizeofUpVal", sizeof(UpVal)); F("sizeofTable", sizeof(Table)); F("sizeofNode", sizeof(Node));
  F("sizeofTString", sizeof(TString)); F("sizeofUpvaldesc", sizeof(Upvaldesc));
#undef F
  return 1;
}
#endif

LROT_BEGIN(driverlib, NULL, 0)
  LROT_FUNCENTRY(census, d_census)
  LROT_FUNCENTRY(new, d_new)
  LROT_FUNCENTRY(load, d_load)
  LROT_FUNCENTRY(call, d_call)
  LROT_FUNCENTRY(set, d_set)
  LROT_FUNCENTRY(gcstep, d_gcstep)
  LROT_FUNCENTRY(gcfull, d_gcfull)
  LROT_FUNCENTRY(mem, d_mem)
  LROT_FUNCENTRY(resetpeak, d_resetpeak)
  LROT_FUNCENTRY(lcd, d_lcd)
  LROT_FUNCENTRY(file, d_file)
  LROT_FUNCENTRY(setfile, d_setfile)
  LROT_FUNCENTRY(heap, d_heap)
  LROT_FUNCENTRY(sdroot, d_sdroot)
LROT_END(driverlib, NULL, 0)

static int traceback(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  luaL_traceback(L, L, msg ? msg : "(error object)", 1);
  return 1;
}

int main(int argc, char **argv) {
  const char *m = getenv("ETX_MODEL"), *h = getenv("ETX_HEAP"), *c = getenv("ETX_CCM");
  if (m && !strcmp(m, "f4")) model = 1; else if (m && !strcmp(m, "host")) model = 2;
  if (h) heapSize = (unsigned)atoi(h);
  if (c) ccmSize = (unsigned)atoi(c);
  if (getenv("ETX_NANO_MERGE")) nanoMerge = atoi(getenv("ETX_NANO_MERGE"));
  int radioMode = argc > 1 && !strcmp(argv[1], "-radio");
  if (radioMode) { argv++; argc--; }
  if (argc < 2) { fprintf(stderr, "usage: etxhost [-radio] script.lua [args]\n"); return 2; }
  static int driverTag;
  lua_State *L = lua_newstate(modelAlloc, radioMode ? (void *)&driverTag : NULL);
  if (!L) { fprintf(stderr, "cannot create state\n"); return 1; }
  luaL_openlibs(L);
  if (radioMode) { lua_pushrotable(L, LROT_TABLEREF(driverlib)); lua_setglobal(L, "radio"); }
  if (radioMode || getenv("ETX_TESTLIBS")) {
    lua_pushrotable(L, LROT_TABLEREF(tablib)); lua_setglobal(L, "table");
#if LUA_VERSION_NUM >= 503
    lua_pushrotable(L, LROT_TABLEREF(dblib)); lua_setglobal(L, "debug");
#else
    luaL_requiref(L, "debug", luaopen_debug, 1); lua_pop(L, 1);
#endif
    lua_pushrotable(L, LROT_TABLEREF(oshost)); lua_setglobal(L, "os");
  }
  lua_createtable(L, argc, 0);
  for (int i = 0; i < argc; i++) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - 1); }
  lua_setglobal(L, "arg");
  lua_pushcfunction(L, traceback);
  if (luaL_loadfilex(L, argv[1], NULL) != LUA_OK) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return 1;
  }
  int st = lua_pcall(L, 0, 0, -2);
  if (st != LUA_OK) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }
  lua_close(L);
  return 0;
}
