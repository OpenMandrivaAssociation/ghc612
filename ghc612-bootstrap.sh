#!/bin/bash
# Package adaptation: STAGE is the build root, GMP_PREFIX is
# %{_libdir}/gmp612 when this hop still uses the private GMP, and
# HOST_GCC is %{_libdir}/ghc-VER/bin/host-gcc. Install is -j1.
# Build GHC 6.12.3 from its sources with the in-chain GHC 6.10.4.
# Registerised, with the x86-64 native code generator. No GHCi, one library way.
# The 6.10.4 that boots it is unregisterised; stage 1 is whatever that compiler
# produces, and everything stage 1 compiles is native code.
set -euo pipefail

ROOT=${STAGE:?}
R=$ROOT/build/ref-ghc-bootstrap
WORK=$ROOT/build/ghc612-work
TREE=$WORK/src/ghc-6.12.3
PREFIX=$WORK/ghc612-prefix
BOOT=$ROOT/build/ghc610-work/ghc610-prefix
GMP=${GMP_PREFIX:?}
SRC=$ROOT/build/sources/ghc-6.12.3-src.tar.bz2

export TMPDIR=$WORK/tmp
export LD_LIBRARY_PATH="$GMP/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$TMPDIR" "$WORK/logs" "$WORK/bin" "$WORK/shipped" "$WORK/src"

exec 9>"$WORK/bootstrap.lock"
flock -n 9 || { printf 'GHC612_FAILED: another bootstrap holds %s\n' "$WORK/bootstrap.lock"; exit 1; }

phase() { printf 'GHC612_PHASE %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { printf 'GHC612_FAILED: %s\n' "$*"; exit 1; }
errline() {
	grep -E 'ERR:|error:|Error:|unrecognised|not in scope|Not in scope|Failed' "$1" 2>/dev/null | tail -4 | tr '\n' ' ' | cut -c1-400
}

printf '%s\n' "$$" > "$WORK/bootstrap.pid"
ulimit -s unlimited 2>/dev/null || true
phase "start pid $$"

[ -x "$BOOT/bin/ghc" ] || fail "boot compiler missing: $BOOT/bin/ghc"
ver=$("$BOOT/bin/ghc" --numeric-version | tr -d '[:space:]')
[ "$ver" = "6.10.4" ] || fail "boot numeric-version is '$ver'"
phase "boot compiler 6.10.4"

cat > "$WORK/bin/gcc" <<EOF
#!/bin/bash
GMP="$GMP"
link=1
for a in "\$@"; do
	case "\$a" in
	-c|-E|-S|-M|-MM|-shared|--version|-dumpversion) link=0 ;;
	esac
done
args=(-I"\$GMP/include" -fno-pie "\$@")
if [ "\$link" = 1 ]; then
	args+=(-L"\$GMP/lib" -no-pie -Wl,-rpath,"\$GMP/lib")
fi
exec /usr/bin/gcc "\${args[@]}"
EOF
chmod +x "$WORK/bin/gcc"
mkdir -p "$(dirname "$HOST_GCC")"
/bin/cp -f "$WORK/bin/gcc" "$HOST_GCC"
chmod 755 "$HOST_GCC"

clean=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '\.ghcup' -e '\.cabal' -e '/ghc66-work/' -e '/ghc610-work/' -e '/ghc612-work/' | paste -sd: -)
export PATH="$BOOT/bin:$ROOT/build/happy-1.16-prefix/bin:$ROOT/build/alex-2.1.0-prefix/bin:$WORK/bin:$clean"
export CC="${HOST_GCC:?}"
export CFLAGS="-std=gnu89 -fpermissive -w"
export CPPFLAGS="-I$GMP/include"
export LDFLAGS="-L$GMP/lib -Wl,-rpath,$GMP/lib"
hash -r
command -v ghc | grep -q ghc610-prefix || fail "PATH ghc is $(command -v ghc)"
command -v happy | grep -q happy-1.16-prefix || fail "PATH happy is $(command -v happy)"
command -v alex | grep -q alex-2.1.0-prefix || fail "PATH alex is $(command -v alex)"
command -v gcc | grep -q '/ghc612-work/bin/gcc' || fail "PATH gcc is $(command -v gcc)"

if [ ! -d "$TREE/mk" ]; then
	phase "unpack"
	tar -C "$WORK/src" -xf "$SRC"
fi
[ -d "$TREE/mk" ] || fail "unpack did not produce $TREE"

cd "$TREE"
if [ ! -f "$WORK/rts-h.done" ]; then
	phase "Rts.h gcc visibility"
	# includes/Rts.h has two `#if __GNUC__ > 4` blocks written for a gcc that
	# did not exist in 2010. One defines macros as `#pragma GCC visibility`,
	# which cpp rejects. Take the branch every 2010 gcc took.
	sed -i 's/^#if __GNUC__ > 4$/#if 0 \/* was: __GNUC__ > 4; untested in 2010 (nix\/ghc612) *\//' includes/Rts.h
	n=$(grep -c 'was: __GNUC__ > 4' includes/Rts.h || true)
	[ "$n" = "2" ] || fail "Rts.h sed count is $n"
	touch "$WORK/rts-h.done"
fi

if [ ! -f "$WORK/regen.done" ]; then
	phase "regen parsers"
	if ! SHIPPED="$WORK/shipped" sh "$R/common/regen-parsers.sh" > "$WORK/logs/regen.log" 2>&1; then
		fail "regen-parsers: $(tail -8 "$WORK/logs/regen.log" | tr '\n' ' ' | cut -c1-500)"
	fi
	touch "$WORK/regen.done"
fi

if [ ! -f mk/build.mk ]; then
	phase "build.mk"
	cat > mk/build.mk <<'EOF'
GhcUnregisterised = NO
GhcWithNativeCodeGen = YES
GhcWithInterpreter = NO
GhcWithSMP = NO
GhcLibWays = v
GhcRTSWays =
SplitObjs = NO
HADDOCK_DOCS = NO
HSCOLOUR_SRCS = NO
BUILD_DOCBOOK_HTML = NO
BUILD_DOCBOOK_PS = NO
BUILD_DOCBOOK_PDF = NO
LATEX_DOCS = NO
GhcStage1HcOpts = -O
GhcStage2HcOpts = -O -fasm
GhcLibHcOpts = -O -fasm
SRC_HC_OPTS = -H64m -O -optc-std=gnu89 -optc-fpermissive -optc-w -optc-fwrapv -optc-fno-pie -optl-no-pie
SRC_CC_OPTS += -std=gnu89 -fpermissive -w -fwrapv -fno-pie
SRC_HSC2HS_OPTS += --cflag=-std=gnu89 --cflag=-fpermissive --cflag=-w
# Replace config.mk's -K2m. happy 1.16 / alex 2.1.0 are real RTS binaries.
SRC_HAPPY_OPTS = -agc --strict +RTS -K64M -H128M -RTS
SRC_ALEX_OPTS = -g +RTS -K64M -RTS
EOF
fi
grep -q 'GhcWithNativeCodeGen[[:space:]]*=[[:space:]]*YES' mk/build.mk || fail "build.mk NCG"

phase "configure"
if [ ! -f mk/config.mk ]; then
	if ! ./configure --prefix="$PREFIX" --with-ghc="$BOOT/bin/ghc" --with-gcc="${HOST_GCC:?}" \
		CFLAGS="-std=gnu89 -fpermissive -w" > "$WORK/logs/configure.log" 2>&1
	then
		fail "configure: $(errline "$WORK/logs/configure.log") $(tail -6 "$WORK/logs/configure.log" | tr '\n' ' ' | cut -c1-400)"
	fi
fi
grep -q "with-ghc=$BOOT/bin/ghc" config.log || fail "config.log did not record the 6.10.4 boot compiler"
happy_mk=$(grep -E '^HAPPY[[:space:]]*=' mk/config.mk | head -1)
alex_mk=$(grep -E '^ALEX[[:space:]]*=' mk/config.mk | head -1)
phase "config $happy_mk"
phase "config $alex_mk"
printf '%s\n' "$happy_mk" | grep -q happy-1.16-prefix || fail "config.mk HAPPY is $happy_mk"
printf '%s\n' "$alex_mk" | grep -q alex-2.1.0-prefix || fail "config.mk ALEX is $alex_mk"

phase "make"
if ! stdbuf -oL -eL make -j1 > "$WORK/logs/make.log" 2>&1; then
	fail "make: $(tail -8 "$WORK/logs/make.log" | tr '\n' ' ' | cut -c1-500)"
fi
phase "make rc=0"

phase "install"
if ! make install > "$WORK/logs/install.log" 2>&1; then
	fail "install: $(errline "$WORK/logs/install.log")"
fi
iver=$("$PREFIX/bin/ghc" --numeric-version | tr -d '[:space:]')
[ "$iver" = "6.12.3" ] || fail "installed numeric-version '$iver'"
iver2=$("$PREFIX/bin/ghc" --numeric-version | tr -d '[:space:]')
[ "$iver2" = "6.12.3" ] || fail "second numeric-version '$iver2'"
printf '%s\n%s\n' "$iver" "$iver2" > "$WORK/logs/ghc612-version.log"
phase "installed 6.12.3"

phase "T3"
T3=$WORK/test-t3
rm -rf "$T3"
mkdir -p "$T3"
/bin/cp -f "$R/common/test/T3.hs" "$T3/T3.hs"
/bin/cp -f "$R/common/test/GmpZero.hs" "$T3/GmpZero.hs"
(
	cd "$T3"
	"$PREFIX/bin/ghc" -v0 --make T3.hs -o t3 > "$WORK/logs/t3-compile.log" 2>&1
	./t3 > "$WORK/logs/t3.out"
) || fail "T3: $(errline "$WORK/logs/t3-compile.log") $(tail -5 "$WORK/logs/t3.out" 2>/dev/null | tr '\n' ' ')"
cmp -s "$R/common/test/T3.out" "$WORK/logs/t3.out" || fail "T3 output mismatch"
phase "T3 ok"

phase "GmpZero"
(
	cd "$T3"
	"$PREFIX/bin/ghc" -v0 -O --make GmpZero.hs -o gz > "$WORK/logs/gmpzero-compile.log" 2>&1
	./gz > "$WORK/logs/gmpzero.out"
) || fail "GmpZero: $(errline "$WORK/logs/gmpzero-compile.log")"
printf '(2400000,0)\n' | cmp -s - "$WORK/logs/gmpzero.out" || fail "GmpZero output $(cat "$WORK/logs/gmpzero.out")"
phase "GmpZero ok"

phase "cmp generated"
if ! SHIPPED="$WORK/shipped" sh "$R/common/cmp-regenerated.sh" > "$WORK/logs/cmp-regenerated.log" 2>&1; then
	fail "cmp-regenerated: $(tail -12 "$WORK/logs/cmp-regenerated.log" | tr '\n' ' ' | cut -c1-500)"
fi
phase "parsers compared"

printf 'GHC612_DONE installed %s numeric-version %s\n' "$PREFIX/bin/ghc" "$iver"
