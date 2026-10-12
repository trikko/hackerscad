#!/bin/sh
# Prepares build/win to build the Windows version on Linux:
# llvm-mingw (C/C++ for Windows), LDC with its Windows libraries, and the
# MSYS2 CLANG64 packages hackerscad needs (OpenCascade, GTK 4, libadwaita,
# GtkSourceView) with their dependencies. Needs curl, 7z, bsdtar, python3,
# glib-compile-schemas and wine (for the pixbuf loader cache).
# Then: packaging/windows/package.sh
set -e
LLVM_MINGW=20261006
LDC=1.42.0
root="$(cd "$(dirname "$0")/.." && pwd)"
win="$root/build/win"
mkdir -p "$win/dl/pkgs"
cd "$win"
get() { [ -f "dl/$1" ] || curl -fsSL -o "dl/$1" "$2"; }

get llvm-mingw.tar.xz "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW/llvm-mingw-$LLVM_MINGW-ucrt-ubuntu-22.04-x86_64.tar.xz"
get ldc-linux.tar.xz "https://github.com/ldc-developers/ldc/releases/download/v$LDC/ldc2-$LDC-linux-x86_64.tar.xz"
get ldc-win.7z "https://github.com/ldc-developers/ldc/releases/download/v$LDC/ldc2-$LDC-windows-multilib.7z"
[ -d llvm-mingw-$LLVM_MINGW-ucrt-ubuntu-22.04-x86_64 ] || tar -xJf dl/llvm-mingw.tar.xz
[ -d ldc2-$LDC-linux-x86_64 ] || tar -xJf dl/ldc-linux.tar.xz
[ -d ldc2-$LDC-windows-multilib ] || 7z x -y dl/ldc-win.7z >/dev/null
# LDC: link Windows programs with the libraries of the Windows package
cat > ldc2-$LDC-linux-x86_64/etc/ldc2.conf/60-target-windows.conf <<CONF
"x86_64-.*-windows-msvc":
{
    switches ~= [ "-defaultlib=phobos2-ldc,druntime-ldc", "-link-defaultlib-shared=false", ];
    lib-dirs = [ "$win/ldc2-$LDC-windows-multilib/lib64", ];
};
CONF

# MSYS2 CLANG64 packages: the closure of the dependencies, from the repository index
curl -fsSL -o dl/clang64.db https://repo.msys2.org/mingw/clang64/clang64.db
rm -rf db && mkdir db && bsdtar -xf dl/clang64.db -C db
python3 - <<'PY'
import os, re
P = 'mingw-w64-clang-x86_64-'
pk, prov = {}, {}
for d in os.listdir('db'):
    sec = {m.group(1): m.group(2).split('\n')
           for m in re.finditer(r'%(\w+)%\n(.*?)(?:\n\n|\Z)', open(f'db/{d}/desc').read(), re.S)}
    pk[sec['NAME'][0]] = sec
    for p in sec.get('PROVIDES', []):
        prov[re.split('[<>=]', p)[0]] = sec['NAME'][0]
want = [P + x for x in ['opencascade', 'gtk4', 'libadwaita', 'gtksourceview5', 'librsvg', 'mesa',
                        'adwaita-icon-theme', 'libc++', 'libunwind', 'freetype', 'fontconfig']]
seen, stack = set(), want
while stack:
    n = re.split('[<>=]', stack.pop())[0]
    n = n if n in pk else prov.get(n, n)
    if n in seen or n not in pk:
        continue
    seen.add(n)
    stack += pk[n].get('DEPENDS', [])
open('pkgs.txt', 'w').write('\n'.join(pk[n]['FILENAME'][0] for n in sorted(seen)) + '\n')
PY
(cd dl/pkgs && xargs -P 8 -I{} sh -c 'test -f {} || curl -fsSL -o {} https://repo.msys2.org/mingw/clang64/{}') < pkgs.txt
rm -rf msys && mkdir msys
while read -r f; do
    bsdtar -xf "dl/pkgs/$f" -C msys --exclude .PKGINFO --exclude .BUILDINFO --exclude .MTREE --exclude .INSTALL
done < pkgs.txt

# Microsoft's C runtime of the D programs (vcruntime140.dll), from the official
# Visual C++ Redistributable, shipped next to them: a fresh Windows may lack it.
# The installer holds cabinets, and cabinets inside them: the DLL is looked up
# by name
get vc_redist.x64.exe https://aka.ms/vs/17/release/vc_redist.x64.exe
if ! [ -f vcruntime/vcruntime140.dll ]; then
    rm -rf vcredist && mkdir -p vcredist vcruntime
    python3 - <<'PY'
import re
data = open('dl/vc_redist.x64.exe', 'rb').read()
for i, m in enumerate(re.finditer(b'MSCF\0\0\0\0', data)):
    size = int.from_bytes(data[m.start() + 8:m.start() + 12], 'little')
    if 0 < size <= len(data) - m.start():
        open(f'vcredist/outer{i}.cab', 'wb').write(data[m.start():m.start() + size])
PY
    for c in vcredist/outer*.cab; do 7z x -y -ovcredist/inner "$c" >/dev/null; done
    for f in vcredist/inner/*; do
        if 7z l "$f" 2>/dev/null | grep -q "vcruntime140.dll_amd64"; then
            7z e -y -ovcredist "$f" vcruntime140.dll_amd64 >/dev/null
            cp vcredist/vcruntime140.dll_amd64 vcruntime/vcruntime140.dll
            break
        fi
    done
    rm -rf vcredist
    [ -f vcruntime/vcruntime140.dll ] || { echo "vcruntime140.dll not found in vc_redist.x64.exe" >&2; exit 1; }
fi

# what the packages' install scripts would do
sys="$win/msys/clang64"
glib-compile-schemas "$sys/share/glib-2.0/schemas"
WINEPREFIX="$win/prefix" WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all WINEPATH="Z:$sys/bin" \
    wine "$sys/bin/gdk-pixbuf-query-loaders.exe" --update-cache
echo "build/win is ready: packaging/windows/package.sh"
