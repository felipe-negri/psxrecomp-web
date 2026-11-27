/* WebAssembly (Emscripten) platform glue.
 *
 * Fibers: Emscripten has no ucontext. The shipping web target runs the HLE
 * (deterministic TCB) thread scheduler, which never suspends native C stacks,
 * so only the "current context" identity is needed. Entering the legacy fiber
 * tier aborts loudly instead of corrupting state.
 *
 * GL: WebGL2 lacks glGetTexLevelParameteriv; the web build presents through
 * the software renderer, so the GL backend only needs the symbol to link.
 */
#include "psx_fiber.h"

#include <stdio.h>
#include <stdlib.h>

static int s_main_context;

psx_fiber_t psx_fiber_convert_thread(void) { return &s_main_context; }
psx_fiber_t psx_fiber_current(void) { return &s_main_context; }

psx_fiber_t psx_fiber_create(size_t stack_size, psx_fiber_entry entry, void *arg) {
    (void)stack_size; (void)entry; (void)arg;
    fprintf(stderr, "psxrecomp(web): legacy fiber scheduler unsupported; use the HLE scheduler\n");
    return NULL;
}

void psx_fiber_switch(psx_fiber_t target) {
    if (target && target != &s_main_context) {
        fprintf(stderr, "psxrecomp(web): fiber switch requested; aborting\n");
        abort();
    }
}

void psx_fiber_destroy(psx_fiber_t fiber) { (void)fiber; }

void glGetTexLevelParameteriv(unsigned target, int level, unsigned pname, int *params) {
    (void)target; (void)level; (void)pname;
    if (params) *params = 0;
}

/* ---- File staging ------------------------------------------------------
 * main() runs on a worker (PROXY_TO_PTHREAD), so small files come in with a
 * synchronous XHR and land in the in-memory root. Disc images are large:
 * each FILE named by the cue becomes a WASMFS fetch-backed file that pulls
 * 1 MiB HTTP Range chunks on demand. */
#include <emscripten.h>
#include <emscripten/wasmfs.h>
#include <string.h>
#include <sys/stat.h>

EM_JS(void *, psx_web_fetch_bytes, (const char *url, int *size_out), {
    try {
        const x = new XMLHttpRequest();
        x.open('GET', UTF8ToString(url), false);
        x.responseType = 'arraybuffer';
        x.send();
        if (x.status !== 200) return 0;
        const bytes = new Uint8Array(x.response);
        const p = _malloc(bytes.length || 1);
        HEAPU8.set(bytes, p);
        HEAP32[size_out >> 2] = bytes.length;
        return p;
    } catch (e) {
        console.warn('psxrecomp: fetch failed', UTF8ToString(url), e);
        return 0;
    }
});

static void mkdirs_for(const char *path) {
    char tmp[512];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; ++p) {
        if (*p == '/') { *p = 0; mkdir(tmp, 0777); *p = '/'; }
    }
}

static int stage_small(const char *url, const char *dest) {
    int n = 0;
    void *data = psx_web_fetch_bytes(url, &n);
    if (!data) return 0;
    mkdirs_for(dest);
    FILE *f = fopen(dest, "wb");
    int ok = f && fwrite(data, 1, (size_t)n, f) == (size_t)n;
    if (f) fclose(f);
    free(data);
    return ok;
}

/* Saves: the page loads IndexedDB into Module.psxSaves ({path: Uint8Array})
 * before the runtime starts; restore_saves() writes them back into the
 * in-memory root, and psx_web_persist() hands every published memory card to
 * Module.psxPersist (IndexedDB + optional Module.psxCardSaved hook). */
#include <emscripten/em_asm.h>
#include <stdint.h>

static void restore_saves(void) {
    int count = MAIN_THREAD_EM_ASM_INT({
        Module.psxSavesList = Object.keys(Module.psxSaves || {});
        return Module.psxSavesList.length;
    });
    for (int i = 0; i < count; ++i) {
        char path[512];
        int len = MAIN_THREAD_EM_ASM_INT({
            stringToUTF8(Module.psxSavesList[$0], $1, 512);
            return Module.psxSaves[Module.psxSavesList[$0]].length;
        }, i, path);
        uint8_t *buf = malloc(len ? (size_t)len : 1);
        MAIN_THREAD_EM_ASM({ HEAPU8.set(Module.psxSaves[Module.psxSavesList[$0]], $1); }, i, buf);
        mkdirs_for(path);
        FILE *f = fopen(path, "wb");
        if (f) { fwrite(buf, 1, (size_t)len, f); fclose(f); }
        fprintf(stderr, "psxrecomp(web): restored %s (%d bytes)\n", path, len);
        free(buf);
    }
}

void psx_web_persist(const char *path, const uint8_t *a, uint32_t na,
                     const uint8_t *b, uint32_t nb) {
    MAIN_THREAD_EM_ASM({
        const bytes = new Uint8Array($2 + $4);
        bytes.set(HEAPU8.subarray($1, $1 + $2));
        if ($4) bytes.set(HEAPU8.subarray($3, $3 + $4), $2);
        if (Module.psxPersist) Module.psxPersist(UTF8ToString($0), bytes);
    }, path, a, na, b, nb);
}

/* list_url: newline-separated paths relative to the page, copied to "/<path>".
 * disc_dir: page-relative folder holding game.cue and its bins, exposed at
 * /disc. Returns 0 when something required is missing. */
int psx_web_stage_files(const char *list_url, const char *disc_dir) {
    int n = 0;
    char *list = (char *)psx_web_fetch_bytes(list_url, &n);
    if (!list) { fprintf(stderr, "psxrecomp(web): missing %s\n", list_url); return 0; }
    list = realloc(list, (size_t)n + 1);
    list[n] = 0;
    for (char *line = strtok(list, "\r\n"); line; line = strtok(NULL, "\r\n")) {
        if (!*line) continue;
        char dest[512];
        snprintf(dest, sizeof dest, "/%s", line);
        if (!stage_small(line, dest)) {
            fprintf(stderr, "psxrecomp(web): could not stage %s\n", line);
            free(list);
            return 0;
        }
    }
    free(list);

    restore_saves();

    char url[512];
    snprintf(url, sizeof url, "%s/game.cue", disc_dir);
    if (!stage_small(url, "/disc/game.cue")) {
        fprintf(stderr, "psxrecomp(web): missing %s\n", url);
        return 0;
    }
    FILE *cue = fopen("/disc/game.cue", "r");
    char line[1024];
    int bins = 0;
    while (cue && fgets(line, sizeof line, cue)) {
        char *q1 = strchr(line, '"');
        char *q2 = q1 ? strchr(q1 + 1, '"') : NULL;
        if (!q1 || !q2 || strncmp(line + strspn(line, " \t"), "FILE", 4) != 0) continue;
        *q2 = 0;
        char path[600];
        snprintf(url, sizeof url, "%s/%s", disc_dir, q1 + 1);
        snprintf(path, sizeof path, "/disc/%s", q1 + 1);
        /* The fetch backend's worker does not resolve relative URLs against
         * the page, so hand it an absolute one built from the page URL. */
        char abs_url[2048];
        MAIN_THREAD_EM_ASM({
            stringToUTF8(new URL(UTF8ToString($0), location.href).href, $1, 2048);
        }, url, abs_url);
        backend_t be = wasmfs_create_fetch_backend(abs_url, 1u << 20);
        if (wasmfs_create_file(path, 0444, be) < 0) {
            fprintf(stderr, "psxrecomp(web): could not map %s\n", url);
            fclose(cue);
            return 0;
        }
        {   /* optional precomputed data-track SHA-256 (see disc_content_hash.h) */
            char side_url[600], side_path[620];
            snprintf(side_url, sizeof side_url, "%s.sha256", url);
            snprintf(side_path, sizeof side_path, "%s.sha256", path);
            stage_small(side_url, side_path);
        }
        ++bins;
    }
    if (cue) fclose(cue);
    return bins > 0;
}

/* Emscripten has no getrusage; report zero CPU time instead of spamming. */
#include <sys/resource.h>
int getrusage(int who, struct rusage *usage) {
    (void)who;
    if (usage) memset(usage, 0, sizeof *usage);
    return 0;
}
