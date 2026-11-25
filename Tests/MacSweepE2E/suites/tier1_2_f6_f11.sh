#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="${MACSWEEP_E2E_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO_ROOT="${MACSWEEP_REPO_ROOT:-$(cd "$E2E_DIR/../.." && pwd)}"
SWIFT_BIN="${MACSWEEP_SWIFT_BIN:-/usr/bin/swift}"
PYTHON_BIN="${MACSWEEP_PYTHON_BIN:-/usr/bin/python3}"
OTOOL_BIN="/usr/bin/otool"
SIPS_BIN="/usr/bin/sips"

TIER="all"
FILTER=""
JSON_PATH=""

usage() {
    cat <<'EOF'
Usage: tier1_2_f6_f11.sh [options]
  --tier <1|2|3|4|all>   Select tier(s) to execute (default: all)
  --filter <pattern>     Case-insensitive substring filter on id/feature/name
  --json <path>          Optional JSON report output path
  -h, --help             Show this help message
EOF
}

validate_tier() {
    case "$1" in
        1|2|3|4|all) ;;
        *)
            echo "Error: Invalid --tier value '$1' (expected 1|2|3|4|all)" >&2
            exit 2
            ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tier)
            [ $# -ge 2 ] || { echo "Error: --tier requires a value" >&2; exit 2; }
            validate_tier "$2"
            TIER="$2"
            shift 2
            ;;
        --tier=*)
            val="${1#--tier=}"
            validate_tier "$val"
            TIER="$val"
            shift
            ;;
        --filter)
            [ $# -ge 2 ] || { echo "Error: --filter requires a value" >&2; exit 2; }
            FILTER="$2"
            shift 2
            ;;
        --filter=*)
            FILTER="${1#--filter=}"
            shift
            ;;
        --json)
            [ $# -ge 2 ] || { echo "Error: --json requires a value" >&2; exit 2; }
            [ -n "$2" ] || { echo "Error: --json requires a non-empty path" >&2; exit 2; }
            JSON_PATH="$2"
            shift 2
            ;;
        --json=*)
            val="${1#--json=}"
            [ -n "$val" ] || { echo "Error: --json requires a non-empty path" >&2; exit 2; }
            JSON_PATH="$val"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

validate_tier "$TIER"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macsweep-e2e-f6-f11.XXXXXXXXXX")"
cleanup_workdir() {
    [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] || return 0
    chmod -R u+rwx "$WORK_DIR" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}
trap cleanup_workdir EXIT
trap 'cleanup_workdir; exit 130' INT
trap 'cleanup_workdir; exit 143' TERM

SCRATCH_PATH="${MACSWEEP_SCRATCH_PATH:-$WORK_DIR/app-scratch}"
mkdir -p "$SCRATCH_PATH"

APP_BIN=""
APP_BUILD_ATTEMPTED=0
APP_BUILD_ERROR=""

PASSED=0
FAILED=0
TOTAL=0
RESULTS_TSV="$WORK_DIR/results.tsv"
: > "$RESULTS_TSV"

write_json_report() {
    [ -n "$JSON_PATH" ] || return 0
    "$PYTHON_BIN" - "$RESULTS_TSV" "$JSON_PATH" "$TIER" "$FILTER" "$PASSED" "$FAILED" "$TOTAL" <<'PYEOF'
import json
import os
import sys

tsv_path, json_path, tier, filt, passed, failed, total = sys.argv[1:8]
cases = []
with open(tsv_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 4)
        t_num, feat, cid, status = parts[0], parts[1], parts[2], parts[3]
        err = parts[4] if len(parts) > 4 and parts[4] else None
        cases.append({
            "tier": int(t_num),
            "feature": feat,
            "id": cid,
            "status": status,
            "error": err,
        })

parent = os.path.dirname(os.path.abspath(json_path))
if parent:
    os.makedirs(parent, exist_ok=True)
report = {
    "probeName": "tier1_2_f6_f11.sh",
    "tierFilter": tier,
    "filterPattern": filt if filt else None,
    "summary": {
        "passed": int(passed),
        "failed": int(failed),
        "total": int(total),
    },
    "cases": cases,
}
with open(json_path, "w", encoding="utf-8") as out:
    json.dump(report, out, indent=2, sort_keys=True)
PYEOF
}

if [ "$TIER" = "3" ] || [ "$TIER" = "4" ]; then
    echo "E2E_SUMMARY tier=$TIER passed=0 failed=0 total=0"
    write_json_report
    exit 0
fi

matches_selection() {
    local case_tier="$1"
    local case_feature="$2"
    local case_id="$3"
    local case_name="$4"

    if [ "$TIER" != "all" ] && [ "$TIER" != "$case_tier" ]; then
        return 1
    fi
    if [ -n "$FILTER" ]; then
        local hay needle
        hay="$(printf '%s %s %s' "$case_id" "$case_feature" "$case_name" | tr '[:upper:]' '[:lower:]')"
        needle="$(printf '%s' "$FILTER" | tr '[:upper:]' '[:lower:]')"
        case "$hay" in
            *"$needle"*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

run_case() {
    local case_tier="$1"
    local case_feature="$2"
    local case_id="$3"
    local case_name="$4"
    local fn_name="$5"

    if ! matches_selection "$case_tier" "$case_feature" "$case_id" "$case_name"; then
        return 0
    fi

    TOTAL=$((TOTAL + 1))
    local err_file="$WORK_DIR/${case_id}.err"
    : > "$err_file"

    if "$fn_name" "$err_file"; then
        PASSED=$((PASSED + 1))
        printf '[TIER-%s][%s] %s: PASS\n' "$case_tier" "$case_feature" "$case_id"
        printf '%s\t%s\t%s\tPASS\t\n' "$case_tier" "$case_feature" "$case_id" >> "$RESULTS_TSV"
    else
        FAILED=$((FAILED + 1))
        local reason
        reason="$(tr '\r\n' '  ' < "$err_file" | sed 's/  */ /g; s/^ //; s/ $//')"
        [ -n "$reason" ] || reason="assertion failed"
        printf '[TIER-%s][%s] %s: FAIL (%s)\n' "$case_tier" "$case_feature" "$case_id" "$reason"
        printf '%s\t%s\t%s\tFAIL\t%s\n' "$case_tier" "$case_feature" "$case_id" "$reason" >> "$RESULTS_TSV"
    fi
}

ensure_app_binary() {
    local err_file="$1"
    if [ "$APP_BUILD_ATTEMPTED" -eq 1 ]; then
        if [ -n "$APP_BIN" ] && [ -x "$APP_BIN" ]; then
            return 0
        fi
        printf '%s' "$APP_BUILD_ERROR" > "$err_file"
        return 1
    fi
    APP_BUILD_ATTEMPTED=1
    local build_log="$WORK_DIR/macsweepapp_debug_build.log"
    if ! "$SWIFT_BIN" build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" -c debug --product MacSweepApp >"$build_log" 2>&1; then
        APP_BUILD_ERROR="swift build MacSweepApp failed: $(tail -n 3 "$build_log" | tr '\n' ' ')"
        printf '%s' "$APP_BUILD_ERROR" > "$err_file"
        return 1
    fi
    local bin_dir
    if ! bin_dir="$("$SWIFT_BIN" build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" -c debug --show-bin-path 2>"$build_log")"; then
        APP_BUILD_ERROR="swift build --show-bin-path failed"
        printf '%s' "$APP_BUILD_ERROR" > "$err_file"
        return 1
    fi
    APP_BIN="$bin_dir/MacSweepApp"
    if [ ! -x "$APP_BIN" ]; then
        APP_BUILD_ERROR="Built MacSweepApp binary missing at $APP_BIN"
        printf '%s' "$APP_BUILD_ERROR" > "$err_file"
        return 1
    fi
    return 0
}

# Runs a command inside a new process group with hard timeout (kills process group via SIGKILL).
# Usage: run_pg_timeout <timeout_s> <err_file> <env_json> <cmd> [args...]
# Prints exit code to stdout; returns 0 if process exited (even non-zero), 124 on timeout.
run_pg_timeout() {
    local timeout_s="$1"
    local err_file="$2"
    local env_json="$3"
    shift 3

    "$PYTHON_BIN" - "$timeout_s" "$err_file" "$env_json" "$@" <<'PYEOF'
import json
import os
import signal
import subprocess
import sys

timeout_s = float(sys.argv[1])
err_file = sys.argv[2]
env_overrides = json.loads(sys.argv[3])
cmd = sys.argv[4:]

env = os.environ.copy()
for k, v in env_overrides.items():
    if v is None:
        env.pop(k, None)
    else:
        env[k] = str(v)

proc = subprocess.Popen(
    cmd,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=env,
    start_new_session=True,
)
try:
    out, err = proc.communicate(timeout=timeout_s)
    rc = proc.returncode
    if rc != 0:
        detail = err.decode("utf-8", errors="replace").strip() or out.decode("utf-8", errors="replace").strip()
        if detail:
            with open(err_file, "a", encoding="utf-8") as ef:
                ef.write(f"exit={rc}: {detail[:240]}")
    print(rc)
    sys.exit(0)
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.communicate(timeout=2.0)
    except Exception:
        pass
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(f"timed out after {timeout_s}s (process group killed; headless M4 CLI export pending?)")
    print(124)
    sys.exit(124)
PYEOF
}

verify_png_magic_nonempty() {
    local dir="$1"
    local err_file="$2"
    local require_all_eight="${3:-1}"
    "$PYTHON_BIN" - "$dir" "$err_file" "$require_all_eight" "$SIPS_BIN" "$WORK_DIR" <<'PYEOF'
import glob
import math
import os
import re
import struct
import subprocess
import sys

d, err_file, require_all_eight, sips_bin, work_dir = sys.argv[1:6]
EXPECTED_SCREENSHOTS = [
    "01-applications-dark-en.png",
    "02-file-manager-analyzer.png",
    "03-file-manager-browser.png",
    "04-junk-cleaner.png",
    "05-resource-release-duplicates.png",
    "06-resource-release-memory.png",
    "07-startup-extensions-leftovers.png",
    "08-settings-protection-light.png",
]

def fail(msg):
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(msg)
    sys.exit(1)

if not os.path.isdir(d):
    fail(f"screenshot directory does not exist: {d}")

tmp_leftovers = glob.glob(os.path.join(d, "*.tmp"))
if tmp_leftovers:
    fail(f"Leftover .tmp files found: {tmp_leftovers}")

png_entries = []
try:
    names = sorted(os.listdir(d))
except OSError as exc:
    fail(f"Failed to list {d}: {exc}")

for name in names:
    if name.startswith("."):
        continue
    if not name.lower().endswith(".png"):
        continue
    full = os.path.join(d, name)
    if os.path.islink(full) or not os.path.isfile(full):
        fail(f"PNG entry {name} is a symlink or non-regular file")
    png_entries.append((name, full))

if not png_entries:
    fail(f"no PNG files generated in {d}")

if require_all_eight == "1":
    present = {name for name, _ in png_entries}
    missing = [name for name in EXPECTED_SCREENSHOTS if name not in present]
    if missing:
        fail(f"missing expected screenshot(s): {', '.join(missing)}")

probe_bmp = os.path.join(work_dir, "probe_64x64.bmp")

for name, p in png_entries:
    sz = os.path.getsize(p)
    if sz <= 1024:
        fail(f"PNG {name} too small ({sz} bytes)")
    with open(p, "rb") as f:
        hdr = f.read(24)
    if len(hdr) < 24 or hdr[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"Invalid PNG header in {name}")
    if hdr[12:16] != b"IHDR":
        fail(f"Missing IHDR chunk in {name}")
    ihdr_w, ihdr_h = struct.unpack(">II", hdr[16:24])

    sips_dim = subprocess.run(
        [sips_bin, "-g", "pixelWidth", "-g", "pixelHeight", p],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if sips_dim.returncode != 0:
        fail(f"sips failed reading dimensions of {name}: {sips_dim.stderr.strip()}")
    mw = re.search(r"pixelWidth:\s*(\d+)", sips_dim.stdout)
    mh = re.search(r"pixelHeight:\s*(\d+)", sips_dim.stdout)
    if not mw or not mh:
        fail(f"sips did not report pixelWidth/pixelHeight for {name}")
    sips_w, sips_h = int(mw.group(1)), int(mh.group(1))
    if sips_w != ihdr_w or sips_h != ihdr_h:
        fail(f"IHDR ({ihdr_w}x{ihdr_h}) != sips ({sips_w}x{sips_h}) for {name}")
    if sips_w < 1600 or sips_h < 1000:
        fail(f"screenshot {name} dimensions {sips_w}x{sips_h} below 1600x1000")
    if (sips_w % 2) != 0 or (sips_h % 2) != 0:
        fail(f"screenshot {name} dimensions {sips_w}x{sips_h} are not even Retina pixels")

    if os.path.exists(probe_bmp):
        os.remove(probe_bmp)
    sips_bmp = subprocess.run(
        [sips_bin, "-s", "format", "bmp", "-z", "64", "64", p, "--out", probe_bmp],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if sips_bmp.returncode != 0 or not os.path.isfile(probe_bmp):
        fail(f"sips failed to decode {name}: {sips_bmp.stderr.strip()}")

    with open(probe_bmp, "rb") as bf:
        bmp = bf.read()
    if len(bmp) < 54 or bmp[:2] != b"BM":
        fail(f"Invalid BMP output for {name}")
    data_offset = struct.unpack_from("<I", bmp, 10)[0]
    bmp_w = struct.unpack_from("<i", bmp, 18)[0]
    bmp_h = struct.unpack_from("<i", bmp, 22)[0]
    bpp = struct.unpack_from("<H", bmp, 28)[0]
    compression = struct.unpack_from("<I", bmp, 30)[0]
    w, h = abs(bmp_w), abs(bmp_h)
    if w == 0 or h == 0 or bpp not in (24, 32) or compression not in (0, 3):
        fail(f"Unsupported BMP geometry/bpp for {name}: {bmp_w}x{bmp_h} bpp={bpp} comp={compression}")

    bytes_per_px = bpp // 8
    row_stride = ((w * bpp + 31) // 32) * 4
    if data_offset + row_stride * h > len(bmp):
        fail(f"Truncated BMP pixel buffer for {name}")

    distinct_colors = set()
    lumas = []
    for y in range(h):
        row_start = data_offset + y * row_stride
        for x in range(w):
            px_off = row_start + x * bytes_per_px
            b = bmp[px_off]
            g = bmp[px_off + 1]
            r = bmp[px_off + 2]
            a = bmp[px_off + 3] if bytes_per_px == 4 else 255
            distinct_colors.add((r, g, b, a))
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)

    n = len(lumas)
    mean = sum(lumas) / n
    var = sum((v - mean) ** 2 for v in lumas) / n
    stddev = math.sqrt(var)
    if len(distinct_colors) < 16:
        fail(f"blank/solid-color PNG {name} (distinct_colors={len(distinct_colors)} < 16)")
    if stddev < 2.0:
        fail(f"low-variance/blank PNG {name} (luma_stddev={stddev:.2f} < 2.0)")
PYEOF
}

# MARK: - F10 Cases (5 cases: 2 Tier 1 + 3 Tier 2)

case_f10_sh_demo_fixture_files_present() {
    local err_file="$1"
    local catalog="$REPO_ROOT/Sources/MacSweepCore/Demo/DemoFixtureCatalog.swift"
    local exporter="$REPO_ROOT/Sources/MacSweepApp/State/DemoScreenshotExporter.swift"

    if [ ! -f "$catalog" ]; then
        echo "missing Sources/MacSweepCore/Demo/DemoFixtureCatalog.swift" > "$err_file"
        return 1
    fi
    if [ ! -f "$exporter" ]; then
        echo "missing Sources/MacSweepApp/State/DemoScreenshotExporter.swift" > "$err_file"
        return 1
    fi
    if ! grep -q "/Users/alex" "$catalog"; then
        echo "DemoFixtureCatalog.swift does not use /Users/alex fictional fixture paths" > "$err_file"
        return 1
    fi
    local host_user host_home
    host_user="$(id -un)"
    host_home="$HOME"
    for f in "$catalog" "$exporter"; do
        if [ -n "$host_home" ] && grep -Fq "$host_home" "$f"; then
            echo "$(basename "$f") contains real host HOME path" > "$err_file"
            return 1
        fi
        if [ "$host_user" != "alex" ] && grep -Fq "/Users/$host_user" "$f"; then
            echo "$(basename "$f") contains real host user path /Users/$host_user" > "$err_file"
            return 1
        fi
    done
    return 0
}

case_f10_sh_app_bundle_demo_launch() {
    local err_file="$1"
    local dist_dir="$WORK_DIR/dist-bundle"
    local out_dir="$WORK_DIR/bundle-screenshots"
    local home_dir="$WORK_DIR/bundle-home"
    mkdir -p "$dist_dir" "$out_dir" "$home_dir"

    local make_log="$WORK_DIR/make_app.log"
    if ! MACSWEEP_SCRATCH_PATH="$SCRATCH_PATH" MACSWEEP_SIGN_IDENTITY="-" /bin/bash "$REPO_ROOT/make_app.sh" "$dist_dir" >"$make_log" 2>&1; then
        echo "make_app.sh failed: $(tail -n 3 "$make_log" | tr '\n' ' ')" > "$err_file"
        return 1
    fi

    local bundled_bin="$dist_dir/MacSweep.app/Contents/MacOS/MacSweepApp"
    if [ ! -x "$bundled_bin" ]; then
        echo "Bundled MacSweepApp missing at $bundled_bin" > "$err_file"
        return 1
    fi

    local rc
    rc="$(run_pg_timeout 20 "$err_file" "{\"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\"}" "$bundled_bin" --demo-mode --export-screenshots "$out_dir")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "Bundled MacSweepApp exited with $rc" > "$err_file"
        return 1
    fi
    verify_png_magic_nonempty "$out_dir" "$err_file"
}

case_f10_sh_demo_no_network_or_real_home_calls() {
    local err_file="$1"
    local demo_dir="$REPO_ROOT/Sources/MacSweepCore/Demo"
    local exporter="$REPO_ROOT/Sources/MacSweepApp/State/DemoScreenshotExporter.swift"
    if [ ! -d "$demo_dir" ]; then
        echo "Sources/MacSweepCore/Demo directory does not exist" > "$err_file"
        return 1
    fi
    if [ ! -f "$exporter" ]; then
        echo "missing Sources/MacSweepApp/State/DemoScreenshotExporter.swift" > "$err_file"
        return 1
    fi
    if ! "$PYTHON_BIN" - "$REPO_ROOT" "$demo_dir" "$exporter" "$err_file" <<'PYEOF'
import os
import re
import sys

repo_root, demo_dir, exporter, err_file = sys.argv[1:5]

def fail(msg):
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(msg)
    sys.exit(1)

def strip_swift_comments(src):
    out = []
    n = len(src)
    i = 0
    while i < n:
        ch = src[i]
        # Line comment
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            i += 2
            while i < n and src[i] != "\n":
                i += 1
            continue
        # Block comment (supports nesting in Swift)
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
                    depth += 1
                    i += 2
                elif src[i] == "*" and i + 1 < n and src[i + 1] == "/":
                    depth -= 1
                    i += 2
                else:
                    if src[i] == "\n":
                        out.append("\n")
                    i += 1
            out.append(" ")
            continue
        # Raw string literal #"..."# or #"""..."""#
        if ch == "#":
            j = i
            while j < n and src[j] == "#":
                j += 1
            hashes = j - i
            if j < n and src[j] == '"':
                triple = src[j:j + 3] == '"""'
                delim = '"""' if triple else '"'
                k = j + len(delim)
                out.append(src[i:k])
                closing = delim + ("#" * hashes)
                while k < n:
                    if src.startswith(closing, k):
                        out.append(closing)
                        k += len(closing)
                        break
                    if src[k] == "\\" and src[k + 1:k + 1 + hashes] == "#" * hashes and src[k + 1 + hashes:k + 2 + hashes] == "(":
                        out.append(src[k:k + 2 + hashes])
                        k += 2 + hashes
                        continue
                    out.append(src[k])
                    k += 1
                i = k
                continue
        # Regular or multiline string literal
        if ch == '"':
            triple = src[i:i + 3] == '"""'
            delim = '"""' if triple else '"'
            k = i + len(delim)
            out.append(delim)
            while k < n:
                if src[k] == "\\":
                    out.append(src[k:k + 2])
                    k += 2
                    continue
                if src.startswith(delim, k):
                    out.append(delim)
                    k += len(delim)
                    break
                out.append(src[k])
                k += 1
            i = k
            continue
        out.append(ch)
        i += 1
    return "".join(out)

swift_files = []
for root_dir, _, files in os.walk(demo_dir):
    for fn in sorted(files):
        if fn.endswith(".swift"):
            swift_files.append(os.path.join(root_dir, fn))

if not swift_files:
    fail("Sources/MacSweepCore/Demo contains zero .swift files")

swift_files.append(exporter)

forbidden = re.compile(
    r"\b(?:NSUserName|NSFullUserName|NSHomeDirectory|homeDirectoryForCurrentUser|URLSession|getpwuid(?:_r)?)\b"
    r"|ProcessInfo\s*\.\s*processInfo\s*\.\s*(?:userName|fullUserName)\b"
)

hits = []
for path in swift_files:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    stripped = strip_swift_comments(raw)
    for m in forbidden.finditer(stripped):
        line_no = stripped.count("\n", 0, m.start()) + 1
        rel = os.path.relpath(path, repo_root)
        token = " ".join(m.group(0).split())
        hits.append(f"{rel}:{line_no} ({token})")

if hits:
    fail(f"Demo sources contain forbidden host/network API calls: {'; '.join(hits[:5])}")
PYEOF
    then
        return 1
    fi
    ensure_app_binary "$err_file" || return 1
    if "$OTOOL_BIN" -L "$APP_BIN" | grep -E "/opt/homebrew|/usr/local" >/dev/null 2>&1; then
        echo "MacSweepApp links disallowed Homebrew or /usr/local dylibs" > "$err_file"
        return 1
    fi
    return 0
}

case_f10_sh_demo_flag_precedence() {
    local err_file="$1"
    ensure_app_binary "$err_file" || return 1

    local out_a="$WORK_DIR/flag-prec-a"
    local out_b="$WORK_DIR/flag-prec-b"
    local home_dir="$WORK_DIR/flag-prec-home"
    mkdir -p "$out_a" "$out_b" "$home_dir"

    local rc_a
    rc_a="$(run_pg_timeout 20 "$err_file" "{\"MACSWEEP_DEMO_MODE\": \"0\", \"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\"}" "$APP_BIN" --demo-mode --export-screenshots "$out_a")" || return 1
    if [ "$rc_a" -ne 0 ]; then
        [ -s "$err_file" ] || echo "--demo-mode override with MACSWEEP_DEMO_MODE=0 exited $rc_a" > "$err_file"
        return 1
    fi
    verify_png_magic_nonempty "$out_a" "$err_file" || return 1

    local rc_b
    rc_b="$(run_pg_timeout 20 "$err_file" "{\"MACSWEEP_DEMO_MODE\": \"1\", \"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\"}" "$APP_BIN" --export-screenshots "$out_b")" || return 1
    if [ "$rc_b" -ne 0 ]; then
        [ -s "$err_file" ] || echo "MACSWEEP_DEMO_MODE=1 without --demo-mode exited $rc_b" > "$err_file"
        return 1
    fi
    verify_png_magic_nonempty "$out_b" "$err_file"
}

case_f10_sh_demo_missing_export_value_fails_cleanly() {
    local err_file="$1"
    ensure_app_binary "$err_file" || return 1

    local home_dir="$WORK_DIR/missing-val-home"
    mkdir -p "$home_dir"

    local rc
    rc="$(run_pg_timeout 6 "$err_file" "{\"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\"}" "$APP_BIN" --demo-mode --export-screenshots)" || return 1
    if [ "$rc" -eq 0 ]; then
        echo "Expected non-zero exit when --export-screenshots value is missing" > "$err_file"
        return 1
    fi
    if [ "$rc" -lt 0 ] || [ "$rc" -ge 128 ]; then
        echo "Process terminated abnormally with signal code $rc" > "$err_file"
        return 1
    fi
    : > "$err_file"
    return 0
}

# MARK: - F11 Cases (5 cases: 2 Tier 1 + 3 Tier 2)

case_f11_sh_eight_screenshots_exist() {
    local err_file="$1"
    verify_png_magic_nonempty "$REPO_ROOT/docs/screenshots" "$err_file" 1
}

case_f11_sh_readme_gallery_embeds_screenshots() {
    local err_file="$1"
    "$PYTHON_BIN" - "$REPO_ROOT" "$err_file" <<'PYEOF'
import os
import re
import sys

repo_root, err_file = sys.argv[1:3]
real_root = os.path.realpath(repo_root)

def fail(msg):
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(msg)
    sys.exit(1)

def strip_code(markdown):
    norm = markdown.replace("\r\n", "\n").replace("\r", "\n")
    lines = norm.split("\n")
    kept = []
    open_ch = None
    open_len = 0
    for line in lines:
        stripped = line.lstrip(" ")
        leading = len(line) - len(stripped)
        if open_ch is not None:
            if leading <= 3 and stripped.startswith(open_ch):
                run = len(stripped) - len(stripped.lstrip(open_ch))
                after = stripped[run:]
                if run >= open_len and all(c in (" ", "\t") for c in after):
                    open_ch = None
                    open_len = 0
            continue
        if leading <= 3 and stripped and stripped[0] in ("`", "~"):
            ch = stripped[0]
            run = len(stripped) - len(stripped.lstrip(ch))
            if run >= 3:
                info = stripped[run:]
                if ch == "~" or "`" not in info:
                    open_ch = ch
                    open_len = run
                    continue
        kept.append(line)

    text = "\n".join(kept)
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == "`":
            tick_end = i
            while tick_end < n and text[tick_end] == "`":
                tick_end += 1
            tick_len = tick_end - i
            search = tick_end
            closing_end = None
            while search < n:
                if text[search] == "`":
                    run_end = search
                    while run_end < n and text[run_end] == "`":
                        run_end += 1
                    if run_end - search == tick_len:
                        closing_end = run_end
                        break
                    search = run_end
                else:
                    search += 1
            if closing_end is not None and "\n\n" not in text[tick_end:closing_end]:
                out.append(" ")
                i = closing_end
                continue
            out.append(text[i:tick_end])
            i = tick_end
        else:
            out.append(text[i])
            i += 1
    return "".join(out)

def normalize_target(raw_input):
    raw = raw_input.strip()
    if not raw or raw.startswith("#") or raw.startswith("//"):
        return None
    low = raw.lower()
    for scheme in ("http://", "https://", "mailto:", "data:", "javascript:", "tel:"):
        if low.startswith(scheme):
            return None
    for sep in ("?", "#"):
        if sep in raw:
            raw = raw.split(sep, 1)[0]
    raw = raw.strip()
    return raw or None

def parse_dest(inner):
    s = inner.strip()
    if not s:
        return None
    if s.startswith("<"):
        idx = 1
        buf = []
        while idx < len(s):
            ch = s[idx]
            if ch == "\\" and idx + 1 < len(s):
                buf.append(s[idx + 1])
                idx += 2
                continue
            if ch == ">":
                return "".join(buf)
            buf.append(ch)
            idx += 1
        return None
    idx = 0
    buf = []
    while idx < len(s):
        ch = s[idx]
        if ch.isspace():
            break
        if ch == "\\" and idx + 1 < len(s):
            buf.append(s[idx + 1])
            idx += 2
            continue
        buf.append(ch)
        idx += 1
    return "".join(buf) or None

def extract_links(markdown):
    cleaned = strip_code(markdown)
    links = []
    stack = []
    i = 0
    n = len(cleaned)
    while i < n:
        ch = cleaned[i]
        if ch == "\\":
            i += 2
            continue
        if ch == "!" and i + 1 < n and cleaned[i + 1] == "[":
            stack.append(True)
            i += 2
            continue
        if ch == "[":
            stack.append(False)
            i += 1
            continue
        if ch == "]":
            is_img = stack.pop() if stack else False
            after = i + 1
            if after < n and cleaned[after] == "(":
                p = after + 1
                depth = 1
                quote = None
                saw_ws = False
                while p < n and depth > 0:
                    pc = cleaned[p]
                    if pc == "\\":
                        p += 2
                        continue
                    if quote is not None:
                        if pc == quote:
                            quote = None
                    else:
                        if pc.isspace():
                            saw_ws = True
                        elif saw_ws and pc in ('"', "'"):
                            quote = pc
                        elif pc == "(":
                            depth += 1
                        elif pc == ")":
                            depth -= 1
                            if depth == 0:
                                break
                    p += 1
                if depth == 0:
                    dest = parse_dest(cleaned[after + 1:p])
                    if dest:
                        norm = normalize_target(dest)
                        if norm:
                            links.append((norm, is_img))
                    i = p + 1
                    continue
            i = after
            continue
        i += 1

    html_re = re.compile(
        r'<(img|source|video|audio|a|link)\b[^>]*?\b(?:src|href)\s*=\s*(?:"([^"]*)"|\'([^\']*)\')',
        re.IGNORECASE,
    )
    for m in html_re.finditer(cleaned):
        tag = m.group(1).lower()
        val = m.group(2) if m.group(2) is not None else m.group(3)
        norm = normalize_target(val or "")
        if norm:
            links.append((norm, tag == "img"))
    return links

planning_real = os.path.realpath(os.path.join(real_root, "docs", "PLANNING.md"))
screenshots_real_dir = os.path.realpath(os.path.join(real_root, "docs", "screenshots"))

for doc in ("README.md", "README_EN.md", "README_ZH.md"):
    doc_path = os.path.join(repo_root, doc)
    if not os.path.isfile(doc_path):
        fail(f"missing {doc}")
    with open(doc_path, "r", encoding="utf-8") as f:
        content = f.read()
    links = extract_links(content)
    if not links:
        fail(f"{doc} contains no valid relative links")

    has_planning = False
    has_screenshot = False
    base_dir = os.path.dirname(doc_path)
    for target, is_img in links:
        joined = os.path.normpath(os.path.join(base_dir, target))
        resolved = os.path.realpath(joined)
        if not (resolved == real_root or resolved.startswith(real_root + os.sep)):
            fail(f"escaping link '{target}' in {doc}")
        if not os.path.exists(joined):
            fail(f"broken link '{target}' in {doc} -> {joined}")
        if is_img and os.path.isdir(joined):
            fail(f"image link '{target}' in {doc} points to a directory")
        if resolved == planning_real and os.path.isfile(joined):
            has_planning = True
        if resolved.startswith(screenshots_real_dir + os.sep) and target.lower().endswith(".png") and os.path.isfile(joined):
            has_screenshot = True

    if not has_screenshot:
        fail(f"{doc} does not embed valid docs/screenshots/*.png gallery links")
    if not has_planning:
        fail(f"{doc} does not link to existing docs/PLANNING.md")
PYEOF
}

case_f11_sh_readme_no_stale_29_or_4_tabs() {
    local err_file="$1"
    for doc in README.md README_EN.md README_ZH.md; do
        local p="$REPO_ROOT/$doc"
        if [ ! -f "$p" ]; then
            echo "missing $doc" > "$err_file"
            return 1
        fi
        if grep -qiE '(^|[^0-9A-Za-z_.])(29[[:space:]]*项([^0-9A-Za-z_]|$)|all[[:space:]]+29([^0-9A-Za-z_]|$)|29[[:space:]]+(sandbox|unit[[:space:]]+checks|checks)([^0-9A-Za-z_]|$)|4[[:space:]]*大功能页签([^0-9A-Za-z_]|$)|4[[:space:]]+(feature[[:space:]]+)?tabs([^0-9A-Za-z_]|$))' "$p"; then
            echo "$doc still contains stale 29-check or 4-tab references" > "$err_file"
            return 1
        fi
    done
    return 0
}

case_f11_sh_export_overwrite_idempotent() {
    local err_file="$1"
    ensure_app_binary "$err_file" || return 1

    local out_dir="$WORK_DIR/idempotent-out"
    local home_dir="$WORK_DIR/idempotent-home"
    mkdir -p "$out_dir" "$home_dir"

    local rc1 rc2
    rc1="$(run_pg_timeout 20 "$err_file" "{\"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\"}" "$APP_BIN" --demo-mode --export-screenshots "$out_dir")" || return 1
    if [ "$rc1" -ne 0 ]; then
        [ -s "$err_file" ] || echo "First export exited $rc1" > "$err_file"
        return 1
    fi
    rc2="$(run_pg_timeout 20 "$err_file" "{\"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\"}" "$APP_BIN" --demo-mode --export-screenshots "$out_dir")" || return 1
    if [ "$rc2" -ne 0 ]; then
        [ -s "$err_file" ] || echo "Second overwrite export exited $rc2" > "$err_file"
        return 1
    fi
    verify_png_magic_nonempty "$out_dir" "$err_file"
}

case_f11_sh_export_readonly_dest_fails_gracefully() {
    local err_file="$1"
    ensure_app_binary "$err_file" || return 1

    local ro_dir="$WORK_DIR/readonly-dest"
    local home_dir="$WORK_DIR/readonly-home"
    mkdir -p "$ro_dir" "$home_dir"
    chmod 0555 "$ro_dir"

    local rc
    rc="$(run_pg_timeout 8 "$err_file" "{\"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\"}" "$APP_BIN" --demo-mode --export-screenshots "$ro_dir/sub")"
    local wrap_rc=$?
    chmod 0755 "$ro_dir" >/dev/null 2>&1 || true

    if [ $wrap_rc -ne 0 ]; then
        return 1
    fi
    if [ "$rc" -eq 0 ]; then
        echo "Expected non-zero exit when exporting into read-only directory" > "$err_file"
        return 1
    fi
    if [ "$rc" -lt 0 ] || [ "$rc" -ge 128 ]; then
        echo "Read-only export crashed with signal code $rc" > "$err_file"
        return 1
    fi
    : > "$err_file"
    return 0
}

# Execute 10 disjoint F10/F11 shell cases
run_case 1 "F-10" "f10-sh-demo-fixture-files-present" "DemoFixtureCatalog and DemoScreenshotExporter exist with /Users/alex fixtures" case_f10_sh_demo_fixture_files_present
run_case 1 "F-10" "f10-sh-app-bundle-demo-launch" "make_app.sh bundle launches with --demo-mode --export-screenshots cleanly" case_f10_sh_app_bundle_demo_launch
run_case 2 "F-10" "f10-sh-demo-no-network-or-real-home-calls" "Demo sources avoid host/network calls and MacSweepApp has zero third-party dylibs" case_f10_sh_demo_no_network_or_real_home_calls
run_case 2 "F-10" "f10-sh-demo-flag-precedence" "CLI --demo-mode and MACSWEEP_DEMO_MODE=1 both activate demo export cleanly" case_f10_sh_demo_flag_precedence
run_case 2 "F-10" "f10-sh-demo-missing-export-value-fails-cleanly" "Missing --export-screenshots argument exits non-zero without hanging or crashing" case_f10_sh_demo_missing_export_value_fails_cleanly

run_case 1 "F-11" "f11-sh-eight-screenshots-exist" "All 8 docs/screenshots/*.png exist with >=1600x1000 even Retina dimensions" case_f11_sh_eight_screenshots_exist
run_case 1 "F-11" "f11-sh-readme-gallery-embeds-screenshots" "README.md, README_EN.md, and README_ZH.md embed screenshots and PLANNING.md" case_f11_sh_readme_gallery_embeds_screenshots
run_case 2 "F-11" "f11-sh-readme-no-stale-29-or-4-tabs" "README*.md have zero stale 29-check or 4-tab references" case_f11_sh_readme_no_stale_29_or_4_tabs
run_case 2 "F-11" "f11-sh-export-overwrite-idempotent" "Repeated --export-screenshots into same directory overwrites cleanly without .tmp leftovers" case_f11_sh_export_overwrite_idempotent
run_case 2 "F-11" "f11-sh-export-readonly-dest-fails-gracefully" "Exporting into 0555 read-only destination fails cleanly without crash or hang" case_f11_sh_export_readonly_dest_fails_gracefully

echo "E2E_SUMMARY tier=$TIER passed=$PASSED failed=$FAILED total=$TOTAL"
write_json_report

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
