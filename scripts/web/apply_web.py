#!/usr/bin/env python3
"""Apply the web runtime to a psxrecomp framework tree. Idempotent.

usage: apply_web.py <framework tree> <this fork's root>

Games pin framework commits from months apart, so a context diff does not
apply across them. Each change here is anchored on a stable line instead;
an anchor that a tree lacks is reported (optional) or fails (required).
"""
import pathlib
import re
import shutil
import sys

FW = pathlib.Path(sys.argv[1])
ROOT = pathlib.Path(sys.argv[2])
MARK = 'PSX_WEB'
problems = []


def edit(rel, fn, required=True):
    path = FW / rel
    if not path.exists():
        (problems.append if required else print)(f'   web: {rel} missing')
        return
    text = path.read_text()
    new = fn(text)
    if new is None:
        (problems.append if required else print)(f'   web: anchor not found in {rel}')
    elif new != text:
        path.write_text(new)


def insert_before(anchor_re, block, already):
    def fn(text):
        if already in text:
            return text
        m = re.search(anchor_re, text, re.M)
        return None if not m else text[:m.start()] + block + text[m.start():]
    return fn


def insert_after(anchor_re, block, already):
    def fn(text):
        if already in text:
            return text
        m = re.search(anchor_re, text, re.M)
        return None if not m else text[:m.end()] + block + text[m.end():]
    return fn


# New files.
for rel in ('runtime/src/psx_web_platform.c', 'runtime/web/fetch_size.pre.js'):
    (FW / rel).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / rel, FW / rel)

# runtime.cmake: global pthread/exceptions ABI, source swaps, link options.
CMAKE_TOP = '''if(EMSCRIPTEN)
    # Every object (SDL and zlib included) must share the pthread/atomics ABI.
    add_compile_options(-pthread -fwasm-exceptions)
    add_link_options(-pthread -fwasm-exceptions)
endif()
'''
CMAKE_SOURCES = '''if(EMSCRIPTEN)
    # Browser: no ucontext fibers (HLE scheduler only) and no GL 3.x-only calls.
    list(REMOVE_ITEM PSXRECOMP_RUNTIME_SOURCES ${PSXRECOMP_ROOT}/runtime/src/psx_fiber.c)
    list(APPEND PSXRECOMP_RUNTIME_SOURCES ${PSXRECOMP_ROOT}/runtime/src/psx_web_platform.c)
endif()
'''
CMAKE_TARGET = '''    if(EMSCRIPTEN)
        target_compile_definitions(${target} PRIVATE PSX_WEB=1)
        set_target_properties(${target} PROPERTIES SUFFIX ".js")
        target_link_options(${target} PRIVATE
            -pthread -sPROXY_TO_PTHREAD=1 -sPTHREAD_POOL_SIZE=12
            -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=1073741824 -sMAXIMUM_MEMORY=2147483648
            -sSTACK_SIZE=67108864 -sDEFAULT_PTHREAD_STACK_SIZE=8388608
            -sMAX_WEBGL_VERSION=2 -sMIN_WEBGL_VERSION=2 -sFULL_ES3=1
            -sWASMFS=1 -sFORCE_FILESYSTEM=1 -sEXIT_RUNTIME=0 -sENVIRONMENT=web,worker
            -sEXPORTED_RUNTIME_METHODS=FS,ENV,callMain,HEAPU8 -sINVOKE_RUN=1
            "-sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE=$Browser"
            --pre-js ${PSXRECOMP_ROOT}/runtime/web/fetch_size.pre.js)
    endif()
'''


def cmake(text):
    if 'psx_web_platform.c' in text:
        return text
    m = re.search(r'^set\(PSX_SDL_BACKEND\b', text, re.M) or re.search(r'^set\(PSXRECOMP_RUNTIME_SOURCES\b', text, re.M)
    if not m:
        return None
    text = text[:m.start()] + CMAKE_TOP + text[m.start():]
    m = re.search(r'^set\(PSXRECOMP_RUNTIME_SOURCES\b.*?^\)\n', text, re.M | re.S)
    if not m:
        return None
    text = text[:m.end()] + CMAKE_SOURCES + text[m.end():]
    m = re.search(r'^function\(psxrecomp_add_runtime_target target\)\n.*?^endfunction\(\)', text, re.M | re.S)
    if not m:
        return None
    end = m.end() - len('endfunction()')
    return text[:end] + CMAKE_TARGET + text[end:]


edit('runtime/runtime.cmake', cmake)

# main(): stage page files and the disc before anything else runs.
edit('runtime/src/main.cpp', insert_after(
    r'^int main\(int argc, char\*\* argv\) \{\n',
    '#if defined(PSX_WEB)\n'
    '    if (!psx_web_stage_files("web-files.txt", "disc")) return EXIT_FAILURE;\n'
    '#endif\n', 'psx_web_stage_files("web-files.txt"'))
edit('runtime/src/main.cpp', insert_before(
    r'^int main\(int argc, char\*\* argv\) \{\n',
    '#if defined(PSX_WEB)\n'
    'extern "C" int psx_web_stage_files(const char* list_url, const char* disc_dir);\n'
    '#endif\n', 'extern "C" int psx_web_stage_files'))

# Memory cards → IndexedDB (optional: older trees keep saves for the session).
edit('runtime/src/memcard.c', insert_after(
    r'^    if \(!ok\) remove\(temporary\);\n(?=    return ok \? 0 : -1;\n\})',
    '#if defined(PSX_WEB)\n'
    '    if (ok) {\n'
    '        extern void psx_web_persist(const char*, const uint8_t*, uint32_t,\n'
    '                                    const uint8_t*, uint32_t);\n'
    '        psx_web_persist(c->filepath, c->data, MEMCARD_SIZE, tail, size);\n'
    '    }\n'
    '#endif\n', 'psx_web_persist'), required=False)

# Disc identity from port.sh's sidecar (optional: older trees hash the stream).
edit('runtime/include/disc_content_hash.h', lambda t: t if 'sidecar' in t else (
    None if '    uint8_t digest[32];\n    const auto result = psx_sha256_file(input, digest);' not in t else
    t.replace('#include <filesystem>\n', '#include <filesystem>\n#include <fstream>\n', 1).replace(
        '    uint8_t digest[32];\n    const auto result = psx_sha256_file(input, digest);',
        '#if defined(PSX_WEB)\n'
        '    {\n'
        '        // Browser: the image streams over HTTP, so hashing it would download\n'
        '        // all of it. port.sh writes "<bin>.sha256" beside the data track.\n'
        '        std::ifstream sidecar(input.string() + ".sha256");\n'
        '        std::string hex;\n'
        '        if (sidecar >> hex && hex.size() == 64) { out = hex; return true; }\n'
        '    }\n'
        '#endif\n'
        '    uint8_t digest[32];\n    const auto result = psx_sha256_file(input, digest);', 1)),
    required=False)

# Host-side fixes: libc++ needs <exception> in toml11; share one emitter cache.
edit('recompiler/lib/toml11/toml/comments.hpp', insert_before(
    r'^#include <initializer_list>\n', '#include <exception>\n', '#include <exception>'), required=False)
edit('psxrecomp_cli.py', lambda t: t if 'cand.resolve()' in t else (
    None if '        if (cand / "bios").is_dir():\n            return cand\n' not in t else
    t.replace('        if (cand / "bios").is_dir():\n            return cand\n',
              '        if (cand / "bios").is_dir():\n            return cand.resolve()\n', 1)), required=False)

# C/C++ prototypes that disagree only in the return type run on x86 but trap
# in WebAssembly (wasm-ld replaces the call with "unreachable").
def fix_proto(name, src_rel):
    src = FW / src_rel
    if not src.exists():
        return
    m = re.search(r'^(\w+)\s+' + name + r'\(', src.read_text(), re.M)
    if m:
        edit('runtime/src/main.cpp', lambda t: re.sub(
            r'extern "C" \w+ ' + name + r'\(', f'extern "C" {m.group(1)} {name}(', t), required=False)


fix_proto('gpu_ws_set_nw_guest_projection', 'runtime/src/gpu.c')

if problems:
    print('\n'.join(problems), file=sys.stderr)
    sys.exit(1)
