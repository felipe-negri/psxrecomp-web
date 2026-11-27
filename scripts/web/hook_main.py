#!/usr/bin/env python3
"""Insert the web file-staging call at the top of runtime main(). Idempotent.

main.cpp changes on every framework commit, so a context diff does not apply
across the commits games pin; this anchors on the main() signature instead.
usage: hook_main.py <framework>/runtime/src/main.cpp
"""
import re
import sys

path = sys.argv[1]
src = open(path).read()
if 'psx_web_stage_files' in src:
    sys.exit(0)
m = re.search(r'^int main\(int argc, char\*\* argv\) \{\n', src, re.M)
if not m:
    sys.exit('main() not found in ' + path)
hook = ('#if defined(PSX_WEB)\n'
        'extern "C" int psx_web_stage_files(const char* list_url, const char* disc_dir);\n'
        '#endif\n')
body = ('#if defined(PSX_WEB)\n'
        '    if (!psx_web_stage_files("web-files.txt", "disc")) return EXIT_FAILURE;\n'
        '#endif\n')
open(path, 'w').write(src[:m.start()] + hook + m.group(0) + body + src[m.end():])
