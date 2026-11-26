#!/usr/bin/env bash
set -euo pipefail

# GPL-3.0-or-later Compatibility & SBOM Audit for Chiaro v1.1
# Verifies:
#   - Repository LICENSE is GNU GPL v3.0 (GPL-3.0-or-later)
#   - LibRaw 0.22.3 elects LGPL-2.1 (NOT CDDL-1.0)
#   - All native XCFrameworks, static archives, and dylibs are GPL-3.0-compatible
#   - Zero GPL-2.0-only, proprietary, or forbidden libs (x265, x264, Exiv2, libheif, libde265)
#   - Zero unbundled /opt/homebrew or /usr/local dylib leaks in packaged Chiaro.app & dist/chiaro-cli-*
#   - Emits a Software Bill of Materials (SBOM) summary table

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

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
VENDOR_DIR="$ROOT_DIR/Vendor"
FORBIDDEN_DYLIB_RE='(^|/)(libx265|x265|libheif|libexiv2|exiv2|libx264|x264|libde265)([./-]|$)'
FORBIDDEN_SYM_RE='(([0-9]+|^|_)(x265|heif|Exiv2|x264|de265)|(^|_)(x265_|heif_(context|encoder|image|gain_map)|Exiv2|x264_encoder_|de265_))'
ALLOWLIST_BREW_DYLIB_RE='^/opt/homebrew/opt/(svt-av1|aom|dav1d|libvmaf|glib|gettext|pcre2|libpng)/lib/.*\.dylib$'

FAILURES=0
VISITED_FILE=""
DIST_TMP_DIR=""
cleanup_tmp() {
  rm -rf "${VISITED_FILE:-}" "${DIST_TMP_DIR:-}"
}
trap cleanup_tmp EXIT

ST_LICENSE="OK"
ST_NOTICES="OK"
ST_LENSFUN_DB="OK"
ST_XCF_LIBRAW="OK"
ST_XCF_RTPROC="OK"
ST_XCF_LENSFUN="OK"
ST_XCF_UHDR="OK"
ST_XCF_AVIF="OK"
ST_LIBRAW_SRC="OK"
ST_GPL2="OK"
ST_UHDR_CACHE="OK"
ST_PC="OK"
ST_PKG="OK"
ST_SYM="OK"
ST_OTOOL="OK"

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; FAILURES=$((FAILURES + 1)); }

# ------------------------------------------------------------------------------
# 1. Repository License, Notices & Dataset Attribution Audit
# ------------------------------------------------------------------------------
LICENSE_FILE="$ROOT_DIR/LICENSE"
if [[ ! -f "$LICENSE_FILE" ]]; then
  fail "Missing $LICENSE_FILE"
  ST_LICENSE="FAIL"
elif grep -q "GNU GENERAL PUBLIC LICENSE" "$LICENSE_FILE" && grep -q "Version 3, 29 June 2007" "$LICENSE_FILE"; then
  pass "Repository LICENSE verified (GNU GPL v3.0 / GPL-3.0-or-later)"
else
  fail "Repository LICENSE is not the official GNU General Public License v3.0"
  ST_LICENSE="FAIL"
fi

NOTICES_FILE="$ROOT_DIR/THIRD_PARTY_NOTICES.md"
if [[ ! -f "$NOTICES_FILE" ]]; then
  fail "Missing $NOTICES_FILE"
  ST_NOTICES="FAIL"
elif grep -q "GPL-3.0-or-later" "$NOTICES_FILE" && grep -q "LGPL-2.1" "$NOTICES_FILE"; then
  pass "THIRD_PARTY_NOTICES.md declares GPL-3.0-or-later and LibRaw LGPL-2.1 election"
else
  fail "THIRD_PARTY_NOTICES.md missing GPL-3.0-or-later or LibRaw LGPL-2.1 declaration"
  ST_NOTICES="FAIL"
fi

LENSFUN_DB_DIR="$ROOT_DIR/Sources/ChiaroCore/Resources/LensfunDB"
if [[ -d "$LENSFUN_DB_DIR" ]]; then
  if [[ -f "$LENSFUN_DB_DIR/cc-by-sa-3.0.txt" && -f "$LENSFUN_DB_DIR/mil-sony.xml" ]]; then
    pass "Bundled LensfunDB XMLs & CC-BY-SA-3.0 license present"
  else
    fail "LensfunDB missing mil-sony.xml or cc-by-sa-3.0.txt in $LENSFUN_DB_DIR"
    ST_LENSFUN_DB="FAIL"
  fi
else
  fail "Missing LensfunDB resource directory: $LENSFUN_DB_DIR"
  ST_LENSFUN_DB="FAIL"
fi

# ------------------------------------------------------------------------------
# 2. Vendor XCFrameworks, GPL-2.0-only Rejection & Config Audit
# ------------------------------------------------------------------------------
if [[ ! -d "$VENDOR_DIR/XCFrameworks" ]]; then
  fail "Missing $VENDOR_DIR/XCFrameworks"
  ST_XCF_LIBRAW="FAIL"
  ST_XCF_RTPROC="FAIL"
  ST_XCF_LENSFUN="FAIL"
  ST_XCF_UHDR="FAIL"
  ST_XCF_AVIF="FAIL"
else
  XCF_MISSING=0
  for xcf in LibRaw.xcframework LibRTProcess.xcframework LibLensfun.xcframework LibUltraHDR.xcframework LibAVIF.xcframework; do
    if [[ ! -d "$VENDOR_DIR/XCFrameworks/$xcf" ]]; then
      fail "Missing XCFramework: $xcf"
      XCF_MISSING=1
      case "$xcf" in
        LibRaw.xcframework) ST_XCF_LIBRAW="FAIL" ;;
        LibRTProcess.xcframework) ST_XCF_RTPROC="FAIL" ;;
        LibLensfun.xcframework) ST_XCF_LENSFUN="FAIL" ;;
        LibUltraHDR.xcframework) ST_XCF_UHDR="FAIL" ;;
        LibAVIF.xcframework) ST_XCF_AVIF="FAIL" ;;
      esac
    fi
  done
  if [[ "$XCF_MISSING" -eq 0 ]]; then
    pass "All 5 Vendor XCFrameworks present (LibRaw, LibRTProcess, LibLensfun, LibUltraHDR, LibAVIF)"
  fi
fi

# Verify LibRaw LGPL-2.1 license file if unpacked source exists & reject GPL-2.0-only in Vendor/.src
is_gpl2_only_file() {
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    raw = fh.read()

norm = re.sub(r"\s+", " ", raw).strip()
if not norm:
    sys.exit(1)

explicit_gpl2_only = bool(re.search(
    r"(SPDX-License-Identifier:\s*GPL-2\.0(?:-only)?(?![\w+.-])|\bGPL-?v?2(?:\.0)?-only\b|only\s+version\s+2(?:\.0)?\s+of\s+the\s+(?:GNU\s+)?(?:General\s+Public\s+)?License|GNU\s+GENERAL\s+PUBLIC\s+LICENSE[\s,:-]+Version\s+2(?:\.0)?(?!\.\d)\b.{0,120}\bno\s+later\s+version\b)",
    norm,
    re.IGNORECASE,
))
if explicit_gpl2_only:
    sys.exit(0)

has_gpl_context = bool(
    re.search(r"\b(?:GNU|General\s+Public)\b", norm, re.IGNORECASE)
    and not re.search(r"\b(?:Library|Lesser)\s+General\s+Public\b", norm, re.IGNORECASE)
)
is_gpl_v2 = bool(
    re.search(r"GNU\s+GENERAL\s+PUBLIC\s+LICENSE[\s,:-]+Version\s+2(?:\.0)?(?!\.\d)\b", norm, re.IGNORECASE)
    or (
        has_gpl_context
        and re.search(r"version\s+2(?:\.0)?(?!\.\d)\s+of\s+the\s+(?:GNU\s+(?:General\s+Public\s+)?)?License", norm, re.IGNORECASE)
    )
)
has_or_later = bool(
    re.search(
        r"(either\s+version\s+2(?:\.0)?\s+of\s+the\s+License,\s+or\s+\(at\s+your\s+option\)\s+any\s+later\s+version|any\s+later\s+version|or\s+later|GPL-2\.0-or-later|GPL-2\.0\+|\bGPL-3\.0(?:-or-later)?\b)",
        norm,
        re.IGNORECASE,
    )
)
if is_gpl_v2 and not has_or_later:
    sys.exit(0)
sys.exit(1)
PY
}

if [[ -d "$VENDOR_DIR/.src" ]]; then
  LIBRAW_SRC_FOUND=0
  for lr_src in "$VENDOR_DIR/.src"/LibRaw-*; do
    if [[ -d "$lr_src" ]]; then
      LIBRAW_SRC_FOUND=1
      if [[ ! -f "$lr_src/LICENSE.LGPL" ]]; then
        fail "LibRaw source missing LICENSE.LGPL for LGPL-2.1 election: $lr_src"
        ST_LIBRAW_SRC="FAIL"
      fi
    fi
  done
  if [[ "$LIBRAW_SRC_FOUND" -eq 1 && "$ST_LIBRAW_SRC" == "OK" ]]; then
    pass "LibRaw source LGPL-2.1 license verified"
  fi

  GPL2_ONLY_BAD=0
  while IFS= read -r -d '' lfile; do
    case "$lfile" in
      */LibRaw-*/LICENSE.CDDL|*/LibRaw-*/LICENSE.LGPL) continue ;;
    esac
    if is_gpl2_only_file "$lfile"; then
      fail "Potential GPL-2.0-only license detected in $lfile"
      GPL2_ONLY_BAD=1
      ST_GPL2="FAIL"
    fi
  done < <(find "$VENDOR_DIR/.src" -maxdepth 3 \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -print0 2>/dev/null || true)
  if [[ "$GPL2_ONLY_BAD" -eq 0 ]]; then
    pass "No GPL-2.0-only licenses found in Vendor/.src"
  fi
fi

UHDR_CACHE="$VENDOR_DIR/.build/libultrahdr/CMakeCache.txt"
if [[ -f "$UHDR_CACHE" ]]; then
  UHDR_CACHE_BAD=0
  for kv in "UHDR_ENABLE_HEIF:(BOOL|UNINITIALIZED)=OFF" "UHDR_WRITE_ISO:(BOOL|UNINITIALIZED)=ON" "UHDR_WRITE_XMP:(BOOL|UNINITIALIZED)=ON"; do
    if ! grep -Eq "^${kv}$" "$UHDR_CACHE"; then
      fail "libultrahdr CMakeCache missing required flag matching: ^${kv}$"
      UHDR_CACHE_BAD=1
      ST_UHDR_CACHE="FAIL"
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
      ST_PC="FAIL"
    fi
  done
  if [[ "$PC_BAD" -eq 0 ]]; then
    pass "Vendor pkg-config files clean"
  fi
fi

# ------------------------------------------------------------------------------
# 3. Package.swift Audit
# ------------------------------------------------------------------------------
PKG_FILE="$ROOT_DIR/Package.swift"
if [[ ! -f "$PKG_FILE" ]]; then
  fail "Missing $PKG_FILE"
  ST_PKG="FAIL"
else
  PKG_BAD=0
  if grep -Eqi '(/opt/homebrew/lib\b|/usr/local/lib\b|\b(libheif|x265|exiv2|x264|libde265)\b|-l[[:space:]",]*(x265|heif|exiv2|x264|de265)\b|\.linkedLibrary\("[[:space:]]*(x265|heif|exiv2|x264|de265))' "$PKG_FILE"; then
    fail "Package.swift contains forbidden linker flag, library token, or /opt/homebrew/lib search path"
    PKG_BAD=1
    ST_PKG="FAIL"
  fi
  while IFS= read -r opt_path; do
    [[ -n "$opt_path" ]] || continue
    if ! grep -Eq '^/opt/homebrew/opt/(jpeg-turbo|svt-av1|aom|dav1d|libvmaf|glib|gettext|pcre2|libpng)/lib' <<< "$opt_path"; then
      fail "Package.swift references unallowlisted Homebrew opt path: $opt_path"
      PKG_BAD=1
      ST_PKG="FAIL"
    fi
  done < <(grep -Eo '/opt/homebrew/opt/[A-Za-z0-9_.-]+/lib[^" ]*' "$PKG_FILE" || true)
  if [[ "$PKG_BAD" -eq 0 ]]; then
    pass "Package.swift linker isolation & GPL-3.0 allowlist verified"
  fi
fi

# Always unpack dist/chiaro-cli-*.tar.gz to a temporary directory for audit
# (even if a stale unpacked dist/chiaro-cli-* directory also exists on disk)
DIST_AUDIT_DIRS=()
if [[ -d "$ROOT_DIR/dist" ]]; then
  DIST_AUDIT_DIRS+=("$ROOT_DIR/dist")
  for cli_tar in "$ROOT_DIR/dist"/chiaro-cli-*.tar.gz; do
    [[ -f "$cli_tar" ]] || continue
    if [[ -z "$DIST_TMP_DIR" ]]; then
      DIST_TMP_DIR="$(cd "$(mktemp -d)" && pwd -P)"
    fi
    if ! tar -xzf "$cli_tar" -C "$DIST_TMP_DIR"; then
      fail "Failed to unpack $cli_tar for audit"
      ST_OTOOL="FAIL"
    fi
  done
  if [[ -n "$DIST_TMP_DIR" ]]; then
    DIST_AUDIT_DIRS+=("$DIST_TMP_DIR")
  fi
fi

# ------------------------------------------------------------------------------
# 4. Symbol Audit (nm -gU & nm -u on Vendor .a & Built Binaries)
# ------------------------------------------------------------------------------
SYM_TARGETS=()
while IFS= read -r -d '' afile; do
  SYM_TARGETS+=("$afile")
done < <(find "$VENDOR_DIR/XCFrameworks" "$VENDOR_DIR/install/lib" -maxdepth 4 -name '*.a' -print0 2>/dev/null || true)

ARCHIVE_COUNT="${#SYM_TARGETS[@]}"

BUILT_CANDIDATES=(
  "$ROOT_DIR/.build/debug/chiaro-cli"
  "$ROOT_DIR/.build/release/chiaro-cli"
  "$ROOT_DIR/.build/arm64-apple-macosx/debug/chiaro-cli"
  "$ROOT_DIR/.build/arm64-apple-macosx/release/chiaro-cli"
  "$ROOT_DIR/.build/out/Products/Debug/chiaro-cli"
  "$ROOT_DIR/.build/out/Products/Release/chiaro-cli"
  "$ROOT_DIR/.build/debug/Chiaro"
  "$ROOT_DIR/.build/release/Chiaro"
  "$ROOT_DIR/.build/arm64-apple-macosx/debug/Chiaro"
  "$ROOT_DIR/.build/arm64-apple-macosx/release/Chiaro"
  "$ROOT_DIR/.build/out/Products/Debug/Chiaro"
  "$ROOT_DIR/.build/out/Products/Release/Chiaro"
  "$ROOT_DIR/Chiaro.app/Contents/MacOS/Chiaro"
)

add_unique_file() {
  local cand="$1"
  local existing
  [[ -f "$cand" ]] || return 0
  local real
  real="$(cd "$(dirname "$cand")" && pwd -P)/$(basename "$cand")"
  for existing in "${SYM_TARGETS[@]:-}"; do
    if [[ "$existing" == "$real" ]]; then
      return 0
    fi
  done
  SYM_TARGETS+=("$real")
}

for bbin in "${BUILT_CANDIDATES[@]}"; do
  add_unique_file "$bbin"
done
if [[ -d "$ROOT_DIR/Chiaro.app/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' fw_dylib; do
    add_unique_file "$fw_dylib"
  done < <(find "$ROOT_DIR/Chiaro.app/Contents/Frameworks" -name '*.dylib' -print0 2>/dev/null || true)
fi
for ddir in "${DIST_AUDIT_DIRS[@]:-}"; do
  [[ -d "$ddir" ]] || continue
  while IFS= read -r -d '' dist_bin; do
    add_unique_file "$dist_bin"
  done < <(find "$ddir" -maxdepth 4 \( -name 'chiaro-cli' -o -name '*.dylib' \) -print0 2>/dev/null || true)
done

if [[ "$ARCHIVE_COUNT" -eq 0 ]]; then
  fail "No static archives (.a) found under Vendor/"
  ST_SYM="FAIL"
else
  SYM_BAD=0
  for sfile in "${SYM_TARGETS[@]}"; do
    DEFINED_SYMS="$(nm -gU "$sfile" 2>/dev/null | awk '!/^$/ && !/:$/ {print $NF}' || true)"
    DEFINED_HITS="$(grep -E "$FORBIDDEN_SYM_RE" <<< "$DEFINED_SYMS" | head -n 5 || true)"
    if [[ -n "$DEFINED_HITS" ]]; then
      fail "Forbidden defined symbol in $sfile: $(head -n 3 <<< "$DEFINED_HITS" | tr '\n' ';')"
      SYM_BAD=1
      ST_SYM="FAIL"
    fi
    UNDEF_SYMS="$(nm -u "$sfile" 2>/dev/null | awk '!/^$/ && !/:$/ {print $NF}' || true)"
    UNDEF_HITS="$(grep -E "$FORBIDDEN_SYM_RE" <<< "$UNDEF_SYMS" | head -n 5 || true)"
    if [[ -n "$UNDEF_HITS" ]]; then
      fail "Forbidden undefined symbol in $sfile: $(head -n 3 <<< "$UNDEF_HITS" | tr '\n' ';')"
      SYM_BAD=1
      ST_SYM="FAIL"
    fi
  done
  if [[ "$SYM_BAD" -eq 0 ]]; then
    pass "Symbol audit clean across ${#SYM_TARGETS[@]} target(s) (${ARCHIVE_COUNT} static archive(s) + built/packaged binaries)"
  fi
fi

# ------------------------------------------------------------------------------
# 5. Recursive Mach-O otool -L Audit (Strict Packaged vs Allowlisted Dev)
# ------------------------------------------------------------------------------
BINARIES=()
add_binary_unique() {
  local cand="$1"
  [[ -f "$cand" ]] || return 0
  local real
  real="$(cd "$(dirname "$cand")" && pwd -P)/$(basename "$cand")"
  local existing
  for existing in "${BINARIES[@]:-}"; do
    if [[ "$existing" == "$real" ]]; then
      return 0
    fi
  done
  BINARIES+=("$real")
}

for cand in "${BUILT_CANDIDATES[@]}" \
  "$ROOT_DIR/.build/debug/ChiaroCoreTests.xctest/Contents/MacOS/ChiaroCoreTests" \
  "$ROOT_DIR/.build/release/ChiaroCoreTests.xctest/Contents/MacOS/ChiaroCoreTests" \
  "$ROOT_DIR/.build/arm64-apple-macosx/debug/ChiaroCoreTests.xctest/Contents/MacOS/ChiaroCoreTests" \
  "$ROOT_DIR/.build/arm64-apple-macosx/release/ChiaroCoreTests.xctest/Contents/MacOS/ChiaroCoreTests"; do
  add_binary_unique "$cand"
done

if [[ -d "$ROOT_DIR/Chiaro.app/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' fw_dylib; do
    add_binary_unique "$fw_dylib"
  done < <(find "$ROOT_DIR/Chiaro.app/Contents/Frameworks" -name '*.dylib' -print0 2>/dev/null || true)
fi
for ddir in "${DIST_AUDIT_DIRS[@]:-}"; do
  [[ -d "$ddir" ]] || continue
  while IFS= read -r -d '' dist_macho; do
    add_binary_unique "$dist_macho"
  done < <(find "$ddir" -maxdepth 4 \( -name 'chiaro-cli' -o -name '*.dylib' \) -print0 2>/dev/null || true)
done
if [[ -d "$VENDOR_DIR/install/bin" ]]; then
  for vbin in "$VENDOR_DIR/install/bin"/*; do
    if [[ -f "$vbin" && -x "$vbin" ]]; then
      add_binary_unique "$vbin"
    fi
  done
fi
while IFS= read -r -d '' dylib; do
  add_binary_unique "$dylib"
done < <(find "$VENDOR_DIR" -name '*.dylib' -print0 2>/dev/null || true)

if [[ "$REQUIRE_BINARIES" -eq 1 ]]; then
  HAS_CLI=0
  for p in \
    "$ROOT_DIR/.build/debug/chiaro-cli" \
    "$ROOT_DIR/.build/release/chiaro-cli" \
    "$ROOT_DIR/.build/arm64-apple-macosx/debug/chiaro-cli" \
    "$ROOT_DIR/.build/arm64-apple-macosx/release/chiaro-cli"; do
    if [[ -f "$p" ]]; then HAS_CLI=1; break; fi
  done
  if [[ "$HAS_CLI" -eq 0 ]]; then
    fail "--require-binaries specified, but no built chiaro-cli binary exists"
    ST_OTOOL="FAIL"
  fi

  HAS_APP=0
  for p in \
    "$ROOT_DIR/.build/debug/Chiaro" \
    "$ROOT_DIR/.build/release/Chiaro" \
    "$ROOT_DIR/.build/arm64-apple-macosx/debug/Chiaro" \
    "$ROOT_DIR/.build/arm64-apple-macosx/release/Chiaro" \
    "$ROOT_DIR/Chiaro.app/Contents/MacOS/Chiaro"; do
    if [[ -f "$p" ]]; then HAS_APP=1; break; fi
  done
  if [[ "$HAS_APP" -eq 0 ]]; then
    fail "--require-binaries specified, but no built Chiaro binary exists"
    ST_OTOOL="FAIL"
  fi
fi

if [[ "${#BINARIES[@]}" -gt 0 ]]; then
  VISITED_FILE="$(mktemp)"
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

  is_packaged_target() {
    local t="$1"
    case "$t" in
      "$ROOT_DIR/Chiaro.app/"*|"$ROOT_DIR/dist/"*) return 0 ;;
      *)
        if [[ -n "$DIST_TMP_DIR" && "$t" == "$DIST_TMP_DIR/"* ]]; then
          return 0
        fi
        return 1
        ;;
    esac
  }

  packaged_exec_dir_for() {
    local t="$1"
    case "$t" in
      */Chiaro.app/Contents/*)
        echo "${t%%/Contents/*}/Contents/MacOS"
        ;;
      */lib/*)
        if is_packaged_target "$t"; then
          local cand_bin="${t%/lib/*}/bin"
          if [[ -d "$cand_bin" ]]; then
            echo "$cand_bin"
            return 0
          fi
        fi
        dirname "$t"
        ;;
      *)
        dirname "$t"
        ;;
    esac
  }

  audit_macho() {
    local target="$1"
    local exec_dir="${2:-$(packaged_exec_dir_for "$target")}"
    local inherited_rpaths="${3:-}"
    local visit_key="${target}|${exec_dir}"
    if grep -Fxq "$visit_key" "$VISITED_FILE" 2>/dev/null; then
      return 0
    fi
    echo "$visit_key" >> "$VISITED_FILE"

    local packaged=0
    if is_packaged_target "$target"; then
      packaged=1
    fi

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
      if grep -Eqi "$FORBIDDEN_DYLIB_RE" <<< "$dep"; then
        fail "Forbidden dynamic library dependency in $target -> $dep"
        OTOOL_BAD=1
        ST_OTOOL="FAIL"
      fi
      if grep -Eq '^(/tmp/|/private/tmp/)' <<< "$dep"; then
        fail "Temporary path dynamic library dependency in $target -> $dep"
        OTOOL_BAD=1
        ST_OTOOL="FAIL"
      fi

      if [[ "$packaged" -eq 1 ]]; then
        case "$dep" in
          /System/*|/usr/lib/*|@rpath/libswift*) ;;
          @executable_path/*)
            local resolved_exec="${exec_dir}/${dep#@executable_path/}"
            if [[ ! -f "$resolved_exec" ]]; then
              fail "Missing bundled dylib reference in packaged target $target -> $dep"
              OTOOL_BAD=1
              ST_OTOOL="FAIL"
            fi
            ;;
          @loader_path/*)
            local resolved_loader="${loader_dir}/${dep#@loader_path/}"
            if [[ ! -f "$resolved_loader" ]]; then
              fail "Missing bundled dylib reference in packaged target $target -> $dep"
              OTOOL_BAD=1
              ST_OTOOL="FAIL"
            fi
            ;;
          @rpath/*)
            local rel_p="${dep#@rpath/}"
            if [[ ! -f "$loader_dir/$rel_p" && ! -f "$exec_dir/../Frameworks/$rel_p" && ! -f "$exec_dir/../lib/$rel_p" ]]; then
              fail "Unresolved @rpath dependency in packaged target $target -> $dep"
              OTOOL_BAD=1
              ST_OTOOL="FAIL"
            fi
            ;;
          /opt/homebrew/*|/usr/local/*|/*)
            fail "Unbundled external dylib reference in packaged target $target -> $dep"
            OTOOL_BAD=1
            ST_OTOOL="FAIL"
            ;;
        esac
      else
        case "$dep" in
          /System/*|/usr/lib/*|@loader_path/*|@executable_path/*|@rpath/*) ;;
          /*)
            if ! grep -Eq "$ALLOWLIST_BREW_DYLIB_RE" <<< "$dep"; then
              fail "Unallowlisted external dylib reference in $target -> $dep"
              OTOOL_BAD=1
              ST_OTOOL="FAIL"
            fi
            ;;
        esac
      fi

      # Recursively inspect non-system dylibs that exist on disk
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
            resolved="$(cd "$(dirname "$resolved")" && pwd -P)/$(basename "$resolved")"
            audit_macho "$resolved" "$exec_dir" "$combined_rpaths"
          fi
          ;;
        @executable_path/*)
          local resolved="${exec_dir}/${dep#@executable_path/}"
          if [[ -f "$resolved" ]]; then
            resolved="$(cd "$(dirname "$resolved")" && pwd -P)/$(basename "$resolved")"
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
              candidate="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
              audit_macho "$candidate" "$exec_dir" "$combined_rpaths"
              break
            fi
          done <<< "$combined_rpaths"
          ;;
      esac
    done <<< "$deps"
  }

  for bin in "${BINARIES[@]}"; do
    audit_macho "$bin" "$(packaged_exec_dir_for "$bin")" ""
  done

  if [[ "$OTOOL_BAD" -eq 0 ]]; then
    pass "Recursive otool -L audit clean across ${#BINARIES[@]} binary/binaries"
  fi
fi

# ------------------------------------------------------------------------------
# 6. Dynamic Software Bill of Materials (SBOM) Summary
# ------------------------------------------------------------------------------
detect_glib_linkage() {
  local pkg_line
  pkg_line="$(grep -E 'libglib-2\.0\.a' "$PKG_FILE" 2>/dev/null || true)"
  if [[ -n "$pkg_line" ]]; then
    echo "Static (libglib-2.0.a)"
  else
    echo "Dynamic"
  fi
}

sbom_status() {
  local s
  for s in "$@"; do
    if [[ "$s" != "OK" ]]; then
      echo "FAIL"
      return 0
    fi
  done
  echo "OK"
}

GLIB_LINKAGE="$(detect_glib_linkage)"
APP_AV1_LINKAGE="Dynamic (Homebrew / Bundled)"
if [[ -f "$ROOT_DIR/Chiaro.app/Contents/Frameworks/libSvtAv1Enc.4.dylib" || -f "$ROOT_DIR/Chiaro.app/Contents/Frameworks/libaom.3.dylib" ]]; then
  APP_AV1_LINKAGE="Bundled (@executable_path/../Frameworks)"
fi

echo ""
echo "=== Chiaro v1.1 SBOM (GPL-3.0-or-later Compatibility Summary) ==="
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "Component" "Version" "License" "Linkage" "Status"
printf "%-28s-+-%-12s-+-%-26s-+-%-36s-+-%s\n" "----------------------------" "------------" "--------------------------" "------------------------------------" "------"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "Chiaro" "1.1.0" "GPL-3.0-or-later" "Primary Project" "$(sbom_status "$ST_LICENSE" "$ST_NOTICES" "$ST_PKG" "$ST_SYM" "$ST_OTOOL")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "LibRaw" "0.22.3" "LGPL-2.1 (elected)" "Static (LibRaw.xcframework)" "$(sbom_status "$ST_XCF_LIBRAW" "$ST_LIBRAW_SRC" "$ST_GPL2" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "CarVac/librtprocess" "0.12.0" "GPL-3.0-or-later" "Static (LibRTProcess.xcframework)" "$(sbom_status "$ST_XCF_RTPROC" "$ST_GPL2" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "Lensfun" "0.3.4" "LGPL-3.0-only" "Static (LibLensfun.xcframework)" "$(sbom_status "$ST_XCF_LENSFUN" "$ST_GPL2" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "Lensfun XML Database" "0.3.4 (v1)" "CC-BY-SA-3.0" "Bundled Resource (LensfunDB/)" "$(sbom_status "$ST_LENSFUN_DB")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "GLib" "2.x" "LGPL-2.1-or-later" "$GLIB_LINKAGE" "$(sbom_status "$ST_PKG" "$ST_OTOOL" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "gettext / libintl" "1.x" "LGPL-2.1-or-later" "Static (libintl.a)" "$(sbom_status "$ST_PKG" "$ST_OTOOL" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "PCRE2" "10.x" "BSD-3-Clause" "Static (libpcre2-8.a)" "$(sbom_status "$ST_PKG" "$ST_OTOOL" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "darktable (algorithms/data)" "GPL-3.0 ref" "GPL-3.0-or-later" "Ported Metal/Swift/JSON" "$(sbom_status "$ST_LICENSE" "$ST_NOTICES")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "google/libultrahdr" "2.0.2" "Apache-2.0 (HEIF=OFF)" "Static (LibUltraHDR.xcframework)" "$(sbom_status "$ST_XCF_UHDR" "$ST_UHDR_CACHE" "$ST_GPL2" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "libavif" "1.4.2" "BSD-2-Clause" "Static (LibAVIF.xcframework)" "$(sbom_status "$ST_XCF_AVIF" "$ST_PC" "$ST_GPL2" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "SVT-AV1" "4.x" "BSD-3-Clause-Clear" "$APP_AV1_LINKAGE" "$(sbom_status "$ST_PKG" "$ST_PC" "$ST_SYM" "$ST_OTOOL")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "libaom" "3.x" "BSD-2-Clause" "$APP_AV1_LINKAGE" "$(sbom_status "$ST_PKG" "$ST_PC" "$ST_SYM" "$ST_OTOOL")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "dav1d" "1.x" "BSD-2-Clause" "$APP_AV1_LINKAGE" "$(sbom_status "$ST_PKG" "$ST_PC" "$ST_SYM" "$ST_OTOOL")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "libvmaf" "3.x" "BSD-2-Clause-Patent" "$APP_AV1_LINKAGE" "$(sbom_status "$ST_PKG" "$ST_PC" "$ST_SYM" "$ST_OTOOL")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "libjpeg-turbo" "3.x" "IJG / BSD-3-Clause / zlib" "Static (libjpeg.a)" "$(sbom_status "$ST_PKG" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "libyuv" "bundled" "BSD-3-Clause" "Static (inside libavif.a)" "$(sbom_status "$ST_XCF_AVIF" "$ST_SYM")"
printf "%-28s | %-12s | %-26s | %-36s | %s\n" "zlib" "system" "Zlib" "System (/usr/lib/libz.1.dylib)" "$(sbom_status "$ST_OTOOL")"
echo ""

if [[ "$FAILURES" -gt 0 ]]; then
  echo "License & SBOM audit FAILED with $FAILURES failure(s)." >&2
  exit 1
fi

echo "License & SBOM audit PASSED (GPL-3.0-or-later compatible, 0 violations)."
