#!/usr/bin/env bash
set -euo pipefail

# Zero-GPL / Zero-LGPL License & Linkage Audit for Chiaro V1.0
# Verifies zero linkage or symbol references to forbidden libraries:
#   x265 (GPL), Exiv2 (GPL), libheif (LGPL), x264 (GPL), libde265 (LGPL),
#   and LibRaw GPL2/GPL3 demosaic packs.

REQUIRE_BINARIES=0
for arg in "$@"; do
  case "$arg" in
    --require-binaries) REQUIRE_BINARIES=1 ;;
    -h|--help)
      echo "Usage: $0 [--require-binaries]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor"
FORBIDDEN_DYLIB_RE='(^|/)(libx265|x265|libheif|libexiv2|exiv2|libx264|x264|libde265)([./-]|$)'
FORBIDDEN_SYM_RE='(([0-9]+|^|_)(x265|heif|Exiv2|x264|de265)|(^|_)(x265_|heif_(context|encoder|image|gain_map)|Exiv2|x264_encoder_|de265_|demosaic_pack_gpl|amaze_demosaic|lmmse_demosaic|afd_demosaic|vcd_demosaic))'

FAILURES=0

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; FAILURES=$((FAILURES + 1)); }

# ------------------------------------------------------------------------------
# 1. Vendor XCFrameworks & Source/Config Audit
# ------------------------------------------------------------------------------
if [[ ! -d "$VENDOR_DIR/XCFrameworks" ]]; then
  fail "Missing $VENDOR_DIR/XCFrameworks"
else
  for xcf in LibRaw.xcframework LibUltraHDR.xcframework LibAVIF.xcframework; do
    if [[ ! -d "$VENDOR_DIR/XCFrameworks/$xcf" ]]; then
      fail "Missing XCFramework: $xcf"
    fi
  done
  pass "Vendor XCFrameworks present"
fi

if find "$VENDOR_DIR" \( -iname "*demosaic-pack-GPL2*" -o -iname "*demosaic-pack-GPL3*" \) | grep -q .; then
  fail "Forbidden LibRaw GPL demosaic pack found in $VENDOR_DIR"
else
  pass "No LibRaw GPL2/GPL3 demosaic packs in Vendor/"
fi

UHDR_CACHE="$VENDOR_DIR/.build/libultrahdr/CMakeCache.txt"
if [[ -f "$UHDR_CACHE" ]]; then
  UHDR_CACHE_BAD=0
  for kv in "UHDR_ENABLE_HEIF:(BOOL|UNINITIALIZED)=OFF" "UHDR_WRITE_ISO:(BOOL|UNINITIALIZED)=ON" "UHDR_WRITE_XMP:(BOOL|UNINITIALIZED)=ON"; do
    if ! grep -Eq "^${kv}$" "$UHDR_CACHE"; then
      fail "libultrahdr CMakeCache missing required flag matching: ^${kv}$"
      UHDR_CACHE_BAD=1
    fi
  done
  if [[ "$UHDR_CACHE_BAD" -eq 0 ]]; then
    pass "libultrahdr CMakeCache flags verified (HEIF=OFF, ISO=ON, XMP=ON)"
  fi
fi

if [[ -d "$VENDOR_DIR/install/lib/pkgconfig" ]]; then
  PC_BAD=0
  for pc in "$VENDOR_DIR/install/lib/pkgconfig"/*.pc; do
    [[ -f "$pc" ]] || continue
    if grep -Eqi '(libheif|x265|exiv2|x264|libde265)' "$pc"; then
      fail "Forbidden dependency reference in $pc"
      PC_BAD=1
    fi
  done
  if [[ "$PC_BAD" -eq 0 ]]; then
    pass "Vendor pkg-config files clean"
  fi
fi

# ------------------------------------------------------------------------------
# 2. Package.swift Audit
# ------------------------------------------------------------------------------
PKG_FILE="$ROOT_DIR/Package.swift"
if [[ ! -f "$PKG_FILE" ]]; then
  fail "Missing $PKG_FILE"
else
  if grep -Eqi '(/opt/homebrew/lib\b|\b(libheif|x265|exiv2|x264|libde265)\b|-l[[:space:]",]*(x265|heif|exiv2|x264|de265)\b|\.linkedLibrary\("[[:space:]]*(x265|heif|exiv2|x264|de265))' "$PKG_FILE"; then
    fail "Package.swift contains forbidden linker flag, library token, or /opt/homebrew/lib search path"
  else
    pass "Package.swift linker isolation verified"
  fi
fi

# ------------------------------------------------------------------------------
# 3. Symbol Audit (nm -gU & nm -u on Vendor .a & Built Binaries)
# ------------------------------------------------------------------------------
SYM_TARGETS=()
while IFS= read -r -d '' afile; do
  SYM_TARGETS+=("$afile")
done < <(find "$VENDOR_DIR/XCFrameworks" "$VENDOR_DIR/install/lib" -maxdepth 4 -name '*.a' -print0 2>/dev/null || true)

ARCHIVE_COUNT="${#SYM_TARGETS[@]}"

BUILT_APP_BINS=(
  "$ROOT_DIR/.build/debug/chiaro-cli"
  "$ROOT_DIR/.build/release/chiaro-cli"
  "$ROOT_DIR/.build/debug/Chiaro"
  "$ROOT_DIR/.build/release/Chiaro"
  "$ROOT_DIR/Chiaro.app/Contents/MacOS/Chiaro"
)
for bbin in "${BUILT_APP_BINS[@]}"; do
  if [[ -f "$bbin" ]]; then
    SYM_TARGETS+=("$bbin")
  fi
done

if [[ "$ARCHIVE_COUNT" -eq 0 ]]; then
  fail "No static archives (.a) found under Vendor/"
else
  SYM_BAD=0
  for sfile in "${SYM_TARGETS[@]}"; do
    # Check both defined external symbols (-gU) and undefined symbols (-u), skipping archive/object headers ending with ':'
    DEFINED_HITS="$(nm -gU "$sfile" 2>/dev/null | awk '!/^$/ && !/:$/ {print $NF}' | grep -E "$FORBIDDEN_SYM_RE" | head -n 5 || true)"
    if [[ -n "$DEFINED_HITS" ]]; then
      fail "Forbidden defined symbol in $sfile: $(echo "$DEFINED_HITS" | head -n 3 | tr '\n' ';')"
      SYM_BAD=1
    fi
    UNDEF_HITS="$(nm -u "$sfile" 2>/dev/null | awk '!/^$/ && !/:$/ {print $NF}' | grep -E "$FORBIDDEN_SYM_RE" | head -n 5 || true)"
    if [[ -n "$UNDEF_HITS" ]]; then
      fail "Forbidden undefined symbol in $sfile: $(echo "$UNDEF_HITS" | head -n 3 | tr '\n' ';')"
      SYM_BAD=1
    fi
  done
  if [[ "$SYM_BAD" -eq 0 ]]; then
    pass "Symbol audit clean across ${#SYM_TARGETS[@]} target(s) (${ARCHIVE_COUNT} static archive(s) + built binaries)"
  fi
fi

# ------------------------------------------------------------------------------
# 4. Recursive Mach-O otool -L Audit (with @rpath / @loader_path resolution)
# ------------------------------------------------------------------------------
BINARIES=()
CANDIDATES=(
  "$ROOT_DIR/.build/debug/chiaro-cli"
  "$ROOT_DIR/.build/release/chiaro-cli"
  "$ROOT_DIR/.build/debug/Chiaro"
  "$ROOT_DIR/.build/release/Chiaro"
  "$ROOT_DIR/.build/debug/ChiaroCoreTests.xctest/Contents/MacOS/ChiaroCoreTests"
  "$ROOT_DIR/.build/release/ChiaroCoreTests.xctest/Contents/MacOS/ChiaroCoreTests"
  "$ROOT_DIR/Chiaro.app/Contents/MacOS/Chiaro"
)
for cand in "${CANDIDATES[@]}"; do
  if [[ -f "$cand" ]]; then
    BINARIES+=("$cand")
  fi
done
if [[ -d "$ROOT_DIR/Chiaro.app/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' fw_dylib; do
    BINARIES+=("$fw_dylib")
  done < <(find "$ROOT_DIR/Chiaro.app/Contents/Frameworks" -name '*.dylib' -print0 2>/dev/null || true)
fi
if [[ -d "$VENDOR_DIR/install/bin" ]]; then
  for vbin in "$VENDOR_DIR/install/bin"/*; do
    if [[ -f "$vbin" && -x "$vbin" ]]; then
      BINARIES+=("$vbin")
    fi
  done
fi
while IFS= read -r -d '' dylib; do
  BINARIES+=("$dylib")
done < <(find "$VENDOR_DIR" -name '*.dylib' -print0 2>/dev/null || true)

if [[ "$REQUIRE_BINARIES" -eq 1 ]]; then
  if [[ ! -f "$ROOT_DIR/.build/debug/chiaro-cli" && ! -f "$ROOT_DIR/.build/release/chiaro-cli" ]]; then
    fail "--require-binaries specified, but neither .build/debug/chiaro-cli nor .build/release/chiaro-cli exists"
  fi
  if [[ ! -f "$ROOT_DIR/.build/debug/Chiaro" && ! -f "$ROOT_DIR/.build/release/Chiaro" ]]; then
    fail "--require-binaries specified, but neither .build/debug/Chiaro nor .build/release/Chiaro exists"
  fi
fi

if [[ "${#BINARIES[@]}" -gt 0 ]]; then
  VISITED_FILE="$(mktemp)"
  trap 'rm -f "$VISITED_FILE"' EXIT
  OTOOL_BAD=0

  expand_loader_tokens() {
    local raw_path="$1"
    local loader_dir="$2"
    local exec_dir="$3"
    local out="$raw_path"
    out="${out/@loader_path/$loader_dir}"
    out="${out/@executable_path/$exec_dir}"
    echo "$out"
  }

  extract_rpaths() {
    local target="$1"
    local loader_dir="$2"
    local exec_dir="$3"
    local raw_rpath
    while IFS= read -r raw_rpath; do
      [[ -n "$raw_rpath" ]] || continue
      expand_loader_tokens "$raw_rpath" "$loader_dir" "$exec_dir"
    done < <(otool -l "$target" 2>/dev/null | awk '/cmd LC_RPATH/{f=1} f && /path /{sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; f=0}' || true)
  }

  audit_macho() {
    local target="$1"
    local exec_dir="${2:-$(dirname "$target")}"
    local inherited_rpaths="${3:-}"
    if grep -Fxq "$target" "$VISITED_FILE" 2>/dev/null; then
      return 0
    fi
    echo "$target" >> "$VISITED_FILE"

    local loader_dir
    loader_dir="$(dirname "$target")"
    local local_rpaths
    local_rpaths="$(extract_rpaths "$target" "$loader_dir" "$exec_dir")"
    local combined_rpaths="$local_rpaths"
    if [[ -n "$inherited_rpaths" ]]; then
      if [[ -n "$combined_rpaths" ]]; then
        combined_rpaths="$combined_rpaths"$'\n'"$inherited_rpaths"
      else
        combined_rpaths="$inherited_rpaths"
      fi
    fi

    local deps
    deps="$(otool -L "$target" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)"
    local dep
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      if echo "$dep" | grep -Eqi "$FORBIDDEN_DYLIB_RE"; then
        fail "Forbidden dynamic library dependency in $target -> $dep"
        OTOOL_BAD=1
      fi
      # Recursively inspect non-system dylibs that exist on disk (including @rpath, @loader_path, @executable_path)
      case "$dep" in
        /System/*|/usr/lib/*) ;;
        /*)
          if [[ -f "$dep" ]]; then
            audit_macho "$dep" "$exec_dir" "$combined_rpaths"
          fi
          ;;
        @loader_path/*)
          local resolved="${loader_dir}/${dep#@loader_path/}"
          if [[ -f "$resolved" ]]; then
            audit_macho "$resolved" "$exec_dir" "$combined_rpaths"
          fi
          ;;
        @executable_path/*)
          local resolved="${exec_dir}/${dep#@executable_path/}"
          if [[ -f "$resolved" ]]; then
            audit_macho "$resolved" "$exec_dir" "$combined_rpaths"
          fi
          ;;
        @rpath/*)
          local rel="${dep#@rpath/}"
          local rp
          while IFS= read -r rp; do
            [[ -n "$rp" ]] || continue
            local candidate="${rp%/}/$rel"
            if [[ -f "$candidate" ]]; then
              audit_macho "$candidate" "$exec_dir" "$combined_rpaths"
              break
            fi
          done <<< "$combined_rpaths"
          ;;
      esac
    done <<< "$deps"
  }

  for bin in "${BINARIES[@]}"; do
    audit_macho "$bin" "$(dirname "$bin")" ""
  done

  if [[ "$OTOOL_BAD" -eq 0 ]]; then
    pass "Recursive otool -L audit clean across ${#BINARIES[@]} binary/binaries"
  fi
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "License audit FAILED with $FAILURES failure(s)." >&2
  exit 1
fi

echo "License audit PASSED (0 GPL/LGPL violations)."
