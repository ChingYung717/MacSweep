#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="${MACSWEEP_E2E_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO_ROOT="${MACSWEEP_REPO_ROOT:-$(cd "$E2E_DIR/../.." && pwd)}"
SWIFT_BIN="${MACSWEEP_SWIFT_BIN:-/usr/bin/swift}"
PYTHON_BIN="${MACSWEEP_PYTHON_BIN:-/usr/bin/python3}"
OTOOL_BIN="/usr/bin/otool"
SIPS_BIN="/usr/bin/sips"
CODESIGN_BIN="/usr/bin/codesign"
LIPO_BIN="/usr/bin/lipo"
DITTO_BIN="/usr/bin/ditto"

TIER="all"
FILTER=""
JSON_PATH=""

usage() {
    cat <<'EOF'
Usage: tier3_tier4_e2e.sh [options]
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
        --)
            shift
            if [ $# -gt 0 ]; then
                echo "Error: Unexpected positional argument: $1" >&2
                exit 2
            fi
            break
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

validate_tier "$TIER"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macsweep-e2e-t3-t4.XXXXXXXXXX")"
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

CHECKS_BIN=""
CHECKS_BUILD_ATTEMPTED=0
CHECKS_BUILD_ERROR=""

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
    "probeName": "tier3_tier4_e2e.sh",
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

if [ "$TIER" = "1" ] || [ "$TIER" = "2" ]; then
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

ensure_checks_binary() {
    local err_file="$1"
    if [ "$CHECKS_BUILD_ATTEMPTED" -eq 1 ]; then
        if [ -n "$CHECKS_BIN" ] && [ -x "$CHECKS_BIN" ]; then
            return 0
        fi
        printf '%s' "$CHECKS_BUILD_ERROR" > "$err_file"
        return 1
    fi
    CHECKS_BUILD_ATTEMPTED=1
    local build_log="$WORK_DIR/macsweepchecks_debug_build.log"
    if ! "$SWIFT_BIN" build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" -c debug --product MacSweepChecks >"$build_log" 2>&1; then
        CHECKS_BUILD_ERROR="swift build MacSweepChecks failed: $(tail -n 3 "$build_log" | tr '\n' ' ')"
        printf '%s' "$CHECKS_BUILD_ERROR" > "$err_file"
        return 1
    fi
    local bin_dir
    if ! bin_dir="$("$SWIFT_BIN" build --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" -c debug --show-bin-path 2>"$build_log")"; then
        CHECKS_BUILD_ERROR="swift build --show-bin-path failed"
        printf '%s' "$CHECKS_BUILD_ERROR" > "$err_file"
        return 1
    fi
    CHECKS_BIN="$bin_dir/MacSweepChecks"
    if [ ! -x "$CHECKS_BIN" ]; then
        CHECKS_BUILD_ERROR="Built MacSweepChecks binary missing at $CHECKS_BIN"
        printf '%s' "$CHECKS_BUILD_ERROR" > "$err_file"
        return 1
    fi
    return 0
}

# Usage: run_pg_timeout <timeout_s> <err_file> <stdout_file> <env_json> <cmd> [args...]
# Prints exit code to stdout; returns 0 if process exited, 124 on timeout.
run_pg_timeout() {
    local timeout_s="$1"
    local err_file="$2"
    local stdout_file="$3"
    local env_json="$4"
    shift 4

    "$PYTHON_BIN" - "$timeout_s" "$err_file" "$stdout_file" "$env_json" "$@" <<'PYEOF'
import json
import os
import signal
import subprocess
import sys

timeout_s = float(sys.argv[1])
err_file = sys.argv[2]
stdout_file = sys.argv[3]
env_overrides = json.loads(sys.argv[4])
cmd = sys.argv[5:]

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
    if stdout_file:
        with open(stdout_file, "wb") as sf:
            sf.write(out)
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
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.communicate(timeout=0.5)
    except Exception:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            proc.communicate(timeout=2.0)
        except Exception:
            pass
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(f"timed out after {timeout_s}s (process group killed; M4 demo CLI pending?)")
    print(124)
    sys.exit(124)
PYEOF
}

# Usage: run_pg_dwell <dwell_s> <err_file> <env_json> <cmd> [args...]
run_pg_dwell() {
    local dwell_s="$1"
    local err_file="$2"
    local env_json="$3"
    shift 3

    "$PYTHON_BIN" - "$dwell_s" "$err_file" "$env_json" "$@" <<'PYEOF'
import json
import os
import signal
import subprocess
import sys
import time

dwell_s = float(sys.argv[1])
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
deadline = time.monotonic() + dwell_s
while time.monotonic() < deadline:
    rc = proc.poll()
    if rc is not None:
        out, err = proc.communicate()
        detail = err.decode("utf-8", errors="replace").strip() or out.decode("utf-8", errors="replace").strip()
        with open(err_file, "w", encoding="utf-8") as ef:
            ef.write(f"GUI demo process exited prematurely with rc={rc}: {detail[:200]}")
        sys.exit(1)
    time.sleep(0.2)

try:
    os.killpg(proc.pid, signal.SIGTERM)
except ProcessLookupError:
    pass
try:
    proc.communicate(timeout=1.0)
except Exception:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.communicate(timeout=2.0)
    except Exception:
        pass
sys.exit(0)
PYEOF
}

check_isolated_home_untouched() {
    local home_dir="$1"
    local err_file="$2"
    local app_support="$home_dir/Library/Application Support/MacSweep"
    if [ -e "$app_support/preferences.json" ] || [ -e "$app_support/history.json" ]; then
        echo "Demo mode unexpectedly wrote real state files under $app_support" > "$err_file"
        return 1
    fi
    if [ -d "$home_dir/.Trash" ]; then
        local trash_count
        trash_count="$(find "$home_dir/.Trash" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
        if [ "${trash_count:-0}" -gt 0 ]; then
            echo "Demo mode unexpectedly wrote files to $home_dir/.Trash" > "$err_file"
            return 1
        fi
    fi
    return 0
}

verify_png_set_and_privacy() {
    local dir="$1"
    local err_file="$2"
    local require_all_eight="${3:-1}"
    "$PYTHON_BIN" - "$dir" "$err_file" "$require_all_eight" "$SIPS_BIN" "$WORK_DIR" <<'PYEOF'
import glob
import hashlib
import math
import os
import pwd
import re
import struct
import subprocess
import sys
import zlib

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
for name in sorted(os.listdir(d)):
    if name.startswith(".") or not name.lower().endswith(".png"):
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

pw = pwd.getpwuid(os.getuid())
host_user = pw.pw_name
host_home = os.path.realpath(os.path.expanduser("~"))
gecos = pw.pw_gecos.split(",")[0].strip()
sensitive_tokens = []
for tok in (host_home, f"/Users/{host_user}" if host_user != "alex" else "", host_user if (len(host_user) >= 4 and host_user != "alex") else "", gecos if (len(gecos) >= 4 and gecos.lower() != "alex") else ""):
    if tok and tok not in sensitive_tokens:
        sensitive_tokens.append(tok)

def extract_png_text_chunks(raw_bytes):
    texts = []
    pos = 8
    total_len = len(raw_bytes)
    while pos + 12 <= total_len:
        length, ctype = struct.unpack(">I4s", raw_bytes[pos:pos + 8])
        data_start = pos + 8
        data_end = data_start + length
        if data_end + 4 > total_len:
            break
        payload = raw_bytes[data_start:data_end]
        if ctype == b"tEXt":
            texts.append(payload.decode("latin-1", errors="replace"))
        elif ctype == b"zTXt":
            nul = payload.find(b"\x00")
            if nul != -1 and nul + 2 <= len(payload):
                key = payload[:nul].decode("latin-1", errors="replace")
                try:
                    val = zlib.decompress(payload[nul + 2:]).decode("latin-1", errors="replace")
                except Exception:
                    val = ""
                texts.append(f"{key}:{val}")
        elif ctype == b"iTXt":
            nul = payload.find(b"\x00")
            if nul != -1 and nul + 3 <= len(payload):
                key = payload[:nul].decode("utf-8", errors="replace")
                comp_flag = payload[nul + 1]
                rest = payload[nul + 3:]
                # Skip language tag and translated keyword (2 NULs)
                idx = rest.find(b"\x00")
                if idx != -1:
                    idx2 = rest.find(b"\x00", idx + 1)
                    if idx2 != -1:
                        body = rest[idx2 + 1:]
                        if comp_flag == 1:
                            try:
                                body = zlib.decompress(body)
                            except Exception:
                                body = b""
                        texts.append(f"{key}:{body.decode('utf-8', errors='replace')}")
        pos = data_end + 4
        if ctype == b"IEND":
            break
    return "\n".join(texts)

probe_bmp = os.path.join(work_dir, "probe_t3t4_64x64.bmp")
hashes = {}

for name, p in png_entries:
    sz = os.path.getsize(p)
    if sz <= 1024:
        fail(f"PNG {name} too small ({sz} bytes)")
    with open(p, "rb") as f:
        raw = f.read()
    if len(raw) < 24 or raw[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"Invalid PNG header in {name}")
    if raw[12:16] != b"IHDR":
        fail(f"Missing IHDR chunk in {name}")
    ihdr_w, ihdr_h = struct.unpack(">II", raw[16:24])

    chunk_text = extract_png_text_chunks(raw)
    chunk_lower = chunk_text.lower()
    for tok in sensitive_tokens:
        if tok.lower() in chunk_lower:
            fail(f"PII token leaked in PNG metadata chunk of {name}")

    hashes[name] = hashlib.sha256(raw).hexdigest()

    sips_dim = subprocess.run(
        [sips_bin, "-g", "pixelWidth", "-g", "pixelHeight", p],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if sips_dim.returncode != 0:
        fail(f"sips failed reading {name}: {sips_dim.stderr.strip()}")
    mw = re.search(r"pixelWidth:\s*(\d+)", sips_dim.stdout)
    mh = re.search(r"pixelHeight:\s*(\d+)", sips_dim.stdout)
    if not mw or not mh:
        fail(f"sips missing pixelWidth/pixelHeight for {name}")
    sips_w, sips_h = int(mw.group(1)), int(mh.group(1))
    if sips_w != ihdr_w or sips_h != ihdr_h:
        fail(f"IHDR ({ihdr_w}x{ihdr_h}) != sips ({sips_w}x{sips_h}) for {name}")
    if sips_w < 1600 or sips_h < 1000:
        fail(f"screenshot {name} dimensions {sips_w}x{sips_h} below 1600x1000")
    if (sips_w % 2) != 0 or (sips_h % 2) != 0:
        fail(f"screenshot {name} dimensions {sips_w}x{sips_h} not even Retina pixels")

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
    stddev = math.sqrt(sum((v - mean) ** 2 for v in lumas) / n)
    if len(distinct_colors) < 16:
        fail(f"blank/solid-color PNG {name} (distinct_colors={len(distinct_colors)} < 16)")
    if stddev < 2.0:
        fail(f"low-variance/blank PNG {name} (luma_stddev={stddev:.2f} < 2.0)")

if require_all_eight == "1":
    canonical_hashes = [hashes[name] for name in EXPECTED_SCREENSHOTS]
    if len(set(canonical_hashes)) != len(EXPECTED_SCREENSHOTS):
        fail("duplicate SHA-256 detected among the 8 canonical screenshots")
PYEOF
}

verify_docs_parity_and_links() {
    local err_file="$1"
    local expected_check_count="${2:-}"
    "$PYTHON_BIN" - "$REPO_ROOT" "$err_file" "$expected_check_count" <<'PYEOF'
import os
import pwd
import re
import sys

repo_root, err_file, expected_count = sys.argv[1:4]
real_root = os.path.realpath(repo_root)

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

def strip_code(markdown):
    lines = markdown.splitlines()
    kept = []
    in_fence = False
    fence_char = ""
    fence_len = 0
    for line in lines:
        stripped = line.lstrip()
        m = re.match(r'^(`{3,}|~{3,})', stripped)
        if m:
            tok = m.group(1)
            if not in_fence:
                in_fence = True
                fence_char = tok[0]
                fence_len = len(tok)
                continue
            elif tok[0] == fence_char and len(tok) >= fence_len and stripped[len(tok):].strip() == "":
                in_fence = False
                fence_char = ""
                fence_len = 0
                continue
        if not in_fence:
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

screenshots_dir = os.path.join(repo_root, "docs", "screenshots")
for shot in EXPECTED_SCREENSHOTS:
    sp = os.path.join(screenshots_dir, shot)
    if not os.path.isfile(sp):
        fail(f"missing canonical screenshot docs/screenshots/{shot}")

planning_path = os.path.join(repo_root, "docs", "PLANNING.md")
if not os.path.isfile(planning_path):
    fail("missing docs/PLANNING.md")

planning_real = os.path.realpath(planning_path)
license_real = os.path.realpath(os.path.join(repo_root, "LICENSE"))
security_real = os.path.realpath(os.path.join(repo_root, "SECURITY.md"))
screenshots_real = os.path.realpath(screenshots_dir)

pw = pwd.getpwuid(os.getuid())
host_user = pw.pw_name
host_home = os.path.realpath(os.path.expanduser("~"))

stale_re = re.compile(
    r"(?<![0-9A-Za-z_.])(?:29\s+(?:sandbox\b|(?:[a-z]+\s+){0,2}(?:checks?|tests?))|29\s*项|all\s+29|4\s+(?:[a-z]+\s+){0,2}tabs?|4\s*大功能页签)(?![0-9A-Za-z_])",
    re.IGNORECASE,
)

# Verify links across docs/PLANNING.md + README*.md
for rel_doc in ("docs/PLANNING.md", "README.md", "README_EN.md", "README_ZH.md"):
    doc_path = os.path.join(repo_root, rel_doc)
    if not os.path.isfile(doc_path):
        fail(f"missing {rel_doc}")
    with open(doc_path, "r", encoding="utf-8") as f:
        content = f.read()

    if host_home and host_home in content:
        fail(f"PII leak (host HOME) in {rel_doc}")
    if host_user != "alex" and f"/Users/{host_user}" in content:
        fail(f"PII leak (/Users/{host_user}) in {rel_doc}")

    base_dir = os.path.dirname(doc_path)
    for target, is_img in extract_links(content):
        joined = os.path.normpath(os.path.join(base_dir, target))
        resolved = os.path.realpath(joined)
        if not (resolved == real_root or resolved.startswith(real_root + os.sep)):
            fail(f"escaping link '{target}' in {rel_doc}")
        if not os.path.exists(joined):
            fail(f"broken link '{target}' in {rel_doc} -> {joined}")
        if is_img and os.path.isdir(joined):
            fail(f"image link '{target}' in {rel_doc} points to directory")

union_screenshots = set()
for readme_name in ("README.md", "README_EN.md", "README_ZH.md"):
    p = os.path.join(repo_root, readme_name)
    with open(p, "r", encoding="utf-8") as f:
        content = f.read()
    low = content.lower()

    m_stale = stale_re.search(content)
    if m_stale:
        fail(f"{readme_name} contains stale reference: '{m_stale.group(0)}'")

    if expected_count:
        count_re = re.compile(rf"(?<![0-9A-Za-z_]){re.escape(expected_count)}(?![0-9A-Za-z_])")
        if not count_re.search(content):
            fail(f"{readme_name} missing exact MacSweepChecks count {expected_count}")

    if "--demo-mode" not in content or "--export-screenshots" not in content:
        fail(f"{readme_name} missing --demo-mode or --export-screenshots CLI documentation")

    # Verify all 7 feature modules are described (bilingual tokens)
    module_checks = [
        ("Applications", ("applications", "应用卸载")),
        ("Startup", ("startup", "开机自启", "启动项")),
        ("Extensions", ("extensions", "系统扩展", "浏览器扩展")),
        ("Leftovers", ("leftovers", "残留")),
        ("File Manager", ("file manager", "文件管理")),
        ("Junk Cleaner", ("junk", "垃圾", "缓存清理")),
        ("Resource Release", ("resource", "内存", "重复文件", "大文件", "资源释放")),
    ]
    for label, tokens in module_checks:
        if not any(tok in low for tok in tokens):
            fail(f"{readme_name} missing coverage of module '{label}'")

    base_dir = os.path.dirname(p)
    links = extract_links(content)
    has_planning = False
    has_license = False
    has_security = False
    embedded_shots = set()
    for target, _ in links:
        resolved = os.path.realpath(os.path.normpath(os.path.join(base_dir, target)))
        if resolved == planning_real:
            has_planning = True
        if resolved == license_real:
            has_license = True
        if resolved == security_real:
            has_security = True
        if resolved.startswith(screenshots_real + os.sep) and target.lower().endswith(".png"):
            bname = os.path.basename(resolved)
            embedded_shots.add(bname)
            union_screenshots.add(bname)

    if not has_planning:
        fail(f"{readme_name} does not link to docs/PLANNING.md")
    if not has_license or not has_security:
        fail(f"{readme_name} missing LICENSE or SECURITY.md link")
    if len(embedded_shots) < 4:
        fail(f"{readme_name} embeds only {len(embedded_shots)} screenshots (expected >= 4)")

if not set(EXPECTED_SCREENSHOTS).issubset(union_screenshots):
    missing_union = sorted(set(EXPECTED_SCREENSHOTS) - union_screenshots)
    fail(f"README*.md union omits canonical screenshot(s): {', '.join(missing_union)}")
PYEOF
}

# MARK: - Tier 3 Shell Cases (4 cases)

case_t3_sh_planning_readme_parity() {
    local err_file="$1"
    verify_docs_parity_and_links "$err_file" ""
}

case_t3_sh_demo_multilang_theme_export() {
    local err_file="$1"
    ensure_app_binary "$err_file" || return 1

    local home_en="$WORK_DIR/t3-ml-home-en"
    local tmp_en="$WORK_DIR/t3-ml-tmp-en"
    local out_en="$WORK_DIR/t3-ml-out-en"
    local home_zh="$WORK_DIR/t3-ml-home-zh"
    local tmp_zh="$WORK_DIR/t3-ml-tmp-zh"
    local out_zh="$WORK_DIR/t3-ml-out-zh"
    local home_cmp_en="$WORK_DIR/t3-ml-home-cmp-en"
    local tmp_cmp_en="$WORK_DIR/t3-ml-tmp-cmp-en"
    local out_cmp_en="$WORK_DIR/t3-ml-out-cmp-en"
    local home_cmp_zh="$WORK_DIR/t3-ml-home-cmp-zh"
    local tmp_cmp_zh="$WORK_DIR/t3-ml-tmp-cmp-zh"
    local out_cmp_zh="$WORK_DIR/t3-ml-out-cmp-zh"
    mkdir -p "$home_en" "$tmp_en" "$out_en" "$home_zh" "$tmp_zh" "$out_zh" \
        "$home_cmp_en" "$tmp_cmp_en" "$out_cmp_en" "$home_cmp_zh" "$tmp_cmp_zh" "$out_cmp_zh"

    local rc
    rc="$(run_pg_timeout 25 "$err_file" "$WORK_DIR/t3-ml-en.stdout" "{\"HOME\": \"$home_en\", \"CFFIXED_USER_HOME\": \"$home_en\", \"TMPDIR\": \"$tmp_en\", \"MACSWEEP_DEMO_MODE\": null}" \
        "$APP_BIN" --demo-mode --demo-lang en --demo-theme deepOcean --export-screenshots "$out_en")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "EN/deepOcean export exited $rc" > "$err_file"
        return 1
    fi
    verify_png_set_and_privacy "$out_en" "$err_file" 1 || return 1
    check_isolated_home_untouched "$home_en" "$err_file" || return 1

    rc="$(run_pg_timeout 25 "$err_file" "$WORK_DIR/t3-ml-zh.stdout" "{\"HOME\": \"$home_zh\", \"CFFIXED_USER_HOME\": \"$home_zh\", \"TMPDIR\": \"$tmp_zh\", \"MACSWEEP_DEMO_MODE\": null}" \
        "$APP_BIN" --demo-mode --demo-lang zh --demo-theme system --export-screenshots "$out_zh")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "ZH/system export exited $rc" > "$err_file"
        return 1
    fi
    verify_png_set_and_privacy "$out_zh" "$err_file" 1 || return 1
    check_isolated_home_untouched "$home_zh" "$err_file" || return 1

    rc="$(run_pg_timeout 20 "$err_file" "$WORK_DIR/t3-ml-cmp-en.stdout" "{\"HOME\": \"$home_cmp_en\", \"CFFIXED_USER_HOME\": \"$home_cmp_en\", \"TMPDIR\": \"$tmp_cmp_en\", \"MACSWEEP_DEMO_MODE\": null}" \
        "$APP_BIN" --demo-mode --demo-tab fileManager --demo-lang en --demo-theme deepOcean --export-screenshots "$out_cmp_en")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "fileManager EN/deepOcean export exited $rc" > "$err_file"
        return 1
    fi
    verify_png_set_and_privacy "$out_cmp_en" "$err_file" 0 || return 1

    rc="$(run_pg_timeout 20 "$err_file" "$WORK_DIR/t3-ml-cmp-zh.stdout" "{\"HOME\": \"$home_cmp_zh\", \"CFFIXED_USER_HOME\": \"$home_cmp_zh\", \"TMPDIR\": \"$tmp_cmp_zh\", \"MACSWEEP_DEMO_MODE\": null}" \
        "$APP_BIN" --demo-mode --demo-tab fileManager --demo-lang zh --demo-theme system --export-screenshots "$out_cmp_zh")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "fileManager ZH/system export exited $rc" > "$err_file"
        return 1
    fi
    verify_png_set_and_privacy "$out_cmp_zh" "$err_file" 0 || return 1

    "$PYTHON_BIN" - "$out_cmp_en" "$out_cmp_zh" "$err_file" <<'PYEOF'
import hashlib
import os
import sys

dir_en, dir_zh, err_file = sys.argv[1:4]
pngs_en = sorted(f for f in os.listdir(dir_en) if f.lower().endswith(".png"))
pngs_zh = sorted(f for f in os.listdir(dir_zh) if f.lower().endswith(".png"))
if not pngs_en or not pngs_zh:
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write("missing fileManager comparison PNG(s)")
    sys.exit(1)

h_en = {hashlib.sha256(open(os.path.join(dir_en, f), "rb").read()).hexdigest() for f in pngs_en}
h_zh = {hashlib.sha256(open(os.path.join(dir_zh, f), "rb").read()).hexdigest() for f in pngs_zh}
if h_en == h_zh:
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write("EN/deepOcean and ZH/system fileManager renders produced identical PNG bytes")
    sys.exit(1)
PYEOF
}

case_t3_sh_demo_tabs_isolated_home() {
    local err_file="$1"
    ensure_app_binary "$err_file" || return 1

    local tabs=(applications startup extensions leftovers fileManager junkCleaner resourceRelease)
    for tab in "${tabs[@]}"; do
        local tab_home="$WORK_DIR/t3-tabs-home-$tab"
        local tab_tmp="$WORK_DIR/t3-tabs-tmp-$tab"
        local tab_out="$WORK_DIR/t3-tabs-out-$tab"
        mkdir -p "$tab_home" "$tab_tmp" "$tab_out"

        local rc
        if [ "$tab" = "junkCleaner" ] || [ "$tab" = "resourceRelease" ]; then
            rc="$(run_pg_timeout 15 "$err_file" "$WORK_DIR/t3-tabs-$tab.stdout" "{\"HOME\": \"$tab_home\", \"CFFIXED_USER_HOME\": \"$tab_home\", \"TMPDIR\": \"$tab_tmp\", \"MACSWEEP_DEMO_MODE\": \"1\"}" \
                "$APP_BIN" --demo-tab "$tab" --export-screenshots "$tab_out")" || return 1
        else
            rc="$(run_pg_timeout 15 "$err_file" "$WORK_DIR/t3-tabs-$tab.stdout" "{\"HOME\": \"$tab_home\", \"CFFIXED_USER_HOME\": \"$tab_home\", \"TMPDIR\": \"$tab_tmp\", \"MACSWEEP_DEMO_MODE\": null}" \
                "$APP_BIN" --demo-mode --demo-tab "$tab" --export-screenshots "$tab_out")" || return 1
        fi
        if [ "$rc" -ne 0 ]; then
            [ -s "$err_file" ] || echo "Demo export for tab '$tab' exited $rc" > "$err_file"
            return 1
        fi
        verify_png_set_and_privacy "$tab_out" "$err_file" 0 || return 1
        check_isolated_home_untouched "$tab_home" "$err_file" || return 1
    done

    local gui_home="$WORK_DIR/t3-tabs-gui-home"
    local gui_tmp="$WORK_DIR/t3-tabs-gui-tmp"
    mkdir -p "$gui_home" "$gui_tmp"
    run_pg_dwell 2.5 "$err_file" "{\"HOME\": \"$gui_home\", \"CFFIXED_USER_HOME\": \"$gui_home\", \"TMPDIR\": \"$gui_tmp\", \"MACSWEEP_DEMO_MODE\": null}" \
        "$APP_BIN" --demo-mode --demo-tab fileManager || return 1
    check_isolated_home_untouched "$gui_home" "$err_file"
}

case_t3_sh_checks_live_audit_readme_count() {
    local err_file="$1"
    ensure_checks_binary "$err_file" || return 1

    local home_dir="$WORK_DIR/t3-chk-home"
    local tmp_dir="$WORK_DIR/t3-chk-tmp"
    local checks_out="$WORK_DIR/t3-chk.stdout"
    local audit_out="$WORK_DIR/t3-audit.stdout"
    mkdir -p "$home_dir" "$tmp_dir"

    local rc
    rc="$(run_pg_timeout 45 "$err_file" "$checks_out" "{\"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\", \"TMPDIR\": \"$tmp_dir\"}" "$CHECKS_BIN")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "MacSweepChecks exited $rc" > "$err_file"
        return 1
    fi

    rc="$(run_pg_timeout 45 "$err_file" "$audit_out" "{\"HOME\": \"$home_dir\", \"CFFIXED_USER_HOME\": \"$home_dir\", \"TMPDIR\": \"$tmp_dir\"}" "$CHECKS_BIN" --live-audit)" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "MacSweepChecks --live-audit exited $rc" > "$err_file"
        return 1
    fi

    local passed_count
    passed_count="$("$PYTHON_BIN" - "$checks_out" "$audit_out" "$err_file" <<'PYEOF'
import re
import sys

checks_out, audit_out, err_file = sys.argv[1:4]
def fail(msg):
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(msg)
    sys.exit(1)

with open(checks_out, "r", encoding="utf-8", errors="replace") as f:
    checks_txt = f.read()
m = re.search(r"MacSweepChecks summary:\s*(\d+)\s*passed,\s*(\d+)\s*failed", checks_txt)
if not m:
    fail("Could not parse MacSweepChecks summary line")
passed, failed = int(m.group(1)), int(m.group(2))
if failed != 0 or passed < 100:
    fail(f"Unexpected MacSweepChecks summary: passed={passed}, failed={failed}")

with open(audit_out, "r", encoding="utf-8", errors="replace") as f:
    audit_txt = f.read()
for required in ("MemorySnapshot: total=", "JunkCacheScanner:", "badVendorOrAppleHits=[]", "osLeakHits: []"):
    if required not in audit_txt:
        fail(f"Live audit output missing '{required}'")
print(passed)
PYEOF
)" || return 1

    "$PYTHON_BIN" - "$REPO_ROOT" "$passed_count" "$err_file" <<'PYEOF'
import os
import re
import sys

repo_root, passed_count, err_file = sys.argv[1:4]
count_re = re.compile(rf"(?<![0-9A-Za-z_]){re.escape(passed_count)}(?![0-9A-Za-z_])")
stale_re = re.compile(
    r"(?<![0-9A-Za-z_.])(?:29\s+(?:sandbox\b|(?:[a-z]+\s+){0,2}(?:checks?|tests?))|29\s*项|all\s+29)(?![0-9A-Za-z_])",
    re.IGNORECASE,
)
for doc in ("README.md", "README_EN.md", "README_ZH.md"):
    p = os.path.join(repo_root, doc)
    if not os.path.isfile(p):
        with open(err_file, "w", encoding="utf-8") as ef:
            ef.write(f"missing {doc}")
        sys.exit(1)
    with open(p, "r", encoding="utf-8") as f:
        content = f.read()
    m_stale = stale_re.search(content)
    if m_stale:
        with open(err_file, "w", encoding="utf-8") as ef:
            ef.write(f"{doc} contains stale count '{m_stale.group(0)}'")
        sys.exit(1)
    if not count_re.search(content):
        with open(err_file, "w", encoding="utf-8") as ef:
            ef.write(f"{doc} does not match MacSweepChecks passed count {passed_count}")
        sys.exit(1)
PYEOF
}

# MARK: - Tier 4 Shell Cases (2 cases)

case_t4_sh_desensitized_release_screenshots() {
    local err_file="$1"
    local dist_dir="$WORK_DIR/t4-dist"
    local make_home="$WORK_DIR/t4-make-home"
    local make_tmp="$WORK_DIR/t4-make-tmp"
    local home_a="$WORK_DIR/t4-home-a"
    local tmp_a="$WORK_DIR/t4-tmp-a"
    local shots_a="$WORK_DIR/t4-shots-a"
    local home_b="$WORK_DIR/t4-home-b"
    local tmp_b="$WORK_DIR/t4-tmp-b"
    local shots_b="$WORK_DIR/t4-shots-b"
    mkdir -p "$dist_dir" "$make_home" "$make_tmp" "$home_a" "$tmp_a" "$shots_a" "$home_b" "$tmp_b" "$shots_b"

    local make_log="$WORK_DIR/t4-make-app.log"
    if ! MACSWEEP_SCRATCH_PATH="$SCRATCH_PATH" MACSWEEP_SIGN_IDENTITY="-" HOME="$make_home" CFFIXED_USER_HOME="$make_home" TMPDIR="$make_tmp" \
        /bin/bash "$REPO_ROOT/make_app.sh" "$dist_dir" >"$make_log" 2>&1; then
        echo "make_app.sh failed: $(tail -n 3 "$make_log" | tr '\n' ' ')" > "$err_file"
        return 1
    fi

    local app_bundle="$dist_dir/MacSweep.app"
    local bundled_bin="$app_bundle/Contents/MacOS/MacSweepApp"
    if [ ! -x "$bundled_bin" ]; then
        echo "Bundled executable missing at $bundled_bin" > "$err_file"
        return 1
    fi
    if ! "$CODESIGN_BIN" --verify --deep --strict "$app_bundle" >/dev/null 2>&1; then
        echo "codesign --verify --deep --strict failed on $app_bundle" > "$err_file"
        return 1
    fi
    if "$OTOOL_BIN" -L "$bundled_bin" | grep -E "/opt/homebrew|/usr/local" >/dev/null 2>&1; then
        echo "Bundled MacSweepApp links disallowed /opt/homebrew or /usr/local dylibs" > "$err_file"
        return 1
    fi

    local rc
    rc="$(run_pg_timeout 25 "$err_file" "$WORK_DIR/t4-shots-a.stdout" "{\"HOME\": \"$home_a\", \"CFFIXED_USER_HOME\": \"$home_a\", \"TMPDIR\": \"$tmp_a\", \"MACSWEEP_DEMO_MODE\": null}" \
        "$bundled_bin" --demo-mode --export-screenshots "$shots_a")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "Bundled --demo-mode export exited $rc" > "$err_file"
        return 1
    fi
    verify_png_set_and_privacy "$shots_a" "$err_file" 1 || return 1
    check_isolated_home_untouched "$home_a" "$err_file" || return 1

    rc="$(run_pg_timeout 25 "$err_file" "$WORK_DIR/t4-shots-b.stdout" "{\"HOME\": \"$home_b\", \"CFFIXED_USER_HOME\": \"$home_b\", \"TMPDIR\": \"$tmp_b\", \"MACSWEEP_DEMO_MODE\": \"1\"}" \
        "$bundled_bin" --demo-lang zh --demo-theme system --export-screenshots "$shots_b")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "Bundled MACSWEEP_DEMO_MODE=1 export exited $rc" > "$err_file"
        return 1
    fi
    verify_png_set_and_privacy "$shots_b" "$err_file" 1 || return 1
    check_isolated_home_untouched "$home_b" "$err_file" || return 1

    local repo_shots="$REPO_ROOT/docs/screenshots"
    if [ ! -d "$repo_shots" ]; then
        echo "missing committed docs/screenshots directory" > "$err_file"
        return 1
    fi
    "$PYTHON_BIN" - "$shots_a" "$repo_shots" "$err_file" <<'PYEOF'
import os
import sys

shots_a, repo_shots, err_file = sys.argv[1:4]
expected = {f for f in os.listdir(shots_a) if f.lower().endswith(".png")}
committed = {f for f in os.listdir(repo_shots) if f.lower().endswith(".png")}
if not expected.issubset(committed):
    missing = sorted(expected - committed)
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(f"docs/screenshots missing exported files: {', '.join(missing)}")
    sys.exit(1)
PYEOF
}

case_t4_sh_full_release_bundle_and_docs_audit() {
    local err_file="$1"
    local dist_dir="$WORK_DIR/t4-release-dist"
    local make_home="$WORK_DIR/t4-rel-home"
    local make_tmp="$WORK_DIR/t4-rel-tmp"
    local unzip_dir="$WORK_DIR/t4-unzip"
    mkdir -p "$dist_dir" "$make_home" "$make_tmp" "$unzip_dir"

    local make_log="$WORK_DIR/t4-rel-make.log"
    if ! MACSWEEP_SCRATCH_PATH="$SCRATCH_PATH" MACSWEEP_SIGN_IDENTITY="-" HOME="$make_home" CFFIXED_USER_HOME="$make_home" TMPDIR="$make_tmp" \
        /bin/bash "$REPO_ROOT/make_app.sh" "$dist_dir" >"$make_log" 2>&1; then
        echo "make_app.sh failed: $(tail -n 3 "$make_log" | tr '\n' ' ')" > "$err_file"
        return 1
    fi

    local app_bundle="$dist_dir/MacSweep.app"
    local bundled_bin="$app_bundle/Contents/MacOS/MacSweepApp"
    local arch_name
    arch_name="$(uname -m)"
    local zip_path="$dist_dir/MacSweep-${arch_name}.zip"
    if [ ! -f "$zip_path" ]; then
        echo "missing release zip $zip_path" > "$err_file"
        return 1
    fi
    if ! "$CODESIGN_BIN" --verify --deep --strict --verbose=1 "$app_bundle" >/dev/null 2>&1; then
        echo "codesign --verify --deep --strict failed" > "$err_file"
        return 1
    fi
    if "$OTOOL_BIN" -L "$bundled_bin" | grep -E "/opt/homebrew|/usr/local" >/dev/null 2>&1; then
        echo "Bundled binary links disallowed third-party dylibs" > "$err_file"
        return 1
    fi
    local lipo_archs
    lipo_archs="$("$LIPO_BIN" -archs "$bundled_bin" 2>/dev/null || true)"
    case "$lipo_archs" in
        *arm64*|*x86_64*) ;;
        *)
            echo "Unexpected lipo -archs output: '$lipo_archs'" > "$err_file"
            return 1
            ;;
    esac

    "$PYTHON_BIN" - "$app_bundle" "$err_file" <<'PYEOF'
import os
import plistlib
import sys

app_bundle, err_file = sys.argv[1:3]
def fail(msg):
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(msg)
    sys.exit(1)

plist_path = os.path.join(app_bundle, "Contents", "Info.plist")
if not os.path.isfile(plist_path):
    fail("missing Contents/Info.plist")
with open(plist_path, "rb") as f:
    plist = plistlib.load(f)
for k in ("CFBundleIdentifier", "CFBundleName", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundlePackageType"):
    if not plist.get(k):
        fail(f"Info.plist missing key {k}")
if not os.path.isfile(os.path.join(app_bundle, "Contents", "Resources", "AppIcon.icns")):
    fail("missing Contents/Resources/AppIcon.icns")
if not os.path.isfile(os.path.join(app_bundle, "Contents", "Resources", "LICENSE")):
    fail("missing Contents/Resources/LICENSE")
pkginfo_path = os.path.join(app_bundle, "Contents", "PkgInfo")
if not os.path.isfile(pkginfo_path) or open(pkginfo_path, "rb").read() != b"APPL????":
    fail("missing or invalid Contents/PkgInfo")
PYEOF
    [ $? -eq 0 ] || return 1

    if ! "$DITTO_BIN" -x -k "$zip_path" "$unzip_dir" >/dev/null 2>&1; then
        echo "ditto -x -k failed extracting $zip_path" > "$err_file"
        return 1
    fi
    if [ ! -x "$unzip_dir/MacSweep.app/Contents/MacOS/MacSweepApp" ]; then
        echo "Extracted zip missing MacSweep.app executable" > "$err_file"
        return 1
    fi

    # Static architecture & demo hygiene
    "$PYTHON_BIN" - "$REPO_ROOT" "$err_file" <<'PYEOF'
import os
import re
import sys

repo_root, err_file = sys.argv[1:3]
def fail(msg):
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(msg)
    sys.exit(1)

core_dir = os.path.join(repo_root, "Sources", "MacSweepCore")
app_dir = os.path.join(repo_root, "Sources", "MacSweepApp")
demo_dir = os.path.join(core_dir, "Demo")
exporter_path = os.path.join(app_dir, "State", "DemoScreenshotExporter.swift")

for root_dir, _, files in os.walk(core_dir):
    for fn in files:
        if fn.endswith(".swift"):
            p = os.path.join(root_dir, fn)
            txt = open(p, "r", encoding="utf-8", errors="replace").read()
            if re.search(r"^\s*import\s+SwiftUI\b", txt, re.MULTILINE):
                fail(f"MacSweepCore imports SwiftUI in {fn}")

for root_dir, _, files in os.walk(app_dir):
    for fn in files:
        if fn.endswith(".swift"):
            p = os.path.join(root_dir, fn)
            txt = open(p, "r", encoding="utf-8", errors="replace").read()
            if re.search(r"@State\s+(?:private\s+)?var\b", txt):
                fail(f"MacSweepApp uses @State in {fn}")

if not os.path.isdir(demo_dir) or not os.path.isfile(exporter_path):
    fail("M4 Demo sources missing (Sources/MacSweepCore/Demo or DemoScreenshotExporter.swift)")

demo_files = [exporter_path]
for root_dir, _, files in os.walk(demo_dir):
    for fn in sorted(files):
        if fn.endswith(".swift"):
            demo_files.append(os.path.join(root_dir, fn))

forbidden = re.compile(
    r"\b(?:NSUserName|NSFullUserName|NSHomeDirectory|homeDirectoryForCurrentUser|URLSession|getpwuid(?:_r)?)\b"
    r"|ProcessInfo\s*\.\s*processInfo\s*\.\s*(?:userName|fullUserName)\b"
)
for p in demo_files:
    txt = open(p, "r", encoding="utf-8", errors="replace").read()
    m = forbidden.search(txt)
    if m:
        fail(f"Forbidden host/network call '{m.group(0)}' in {os.path.relpath(p, repo_root)}")
PYEOF
    [ $? -eq 0 ] || return 1

    # Run MacSweepChecks and verify README exact count + docs + screenshots
    ensure_checks_binary "$err_file" || return 1
    local chk_home="$WORK_DIR/t4-chk-home"
    local chk_tmp="$WORK_DIR/t4-chk-tmp"
    local chk_out="$WORK_DIR/t4-chk.stdout"
    mkdir -p "$chk_home" "$chk_tmp"
    local rc
    rc="$(run_pg_timeout 45 "$err_file" "$chk_out" "{\"HOME\": \"$chk_home\", \"CFFIXED_USER_HOME\": \"$chk_home\", \"TMPDIR\": \"$chk_tmp\"}" "$CHECKS_BIN")" || return 1
    if [ "$rc" -ne 0 ]; then
        [ -s "$err_file" ] || echo "MacSweepChecks exited $rc" > "$err_file"
        return 1
    fi

    local passed_count
    passed_count="$("$PYTHON_BIN" - "$chk_out" "$err_file" <<'PYEOF'
import re
import sys

chk_out, err_file = sys.argv[1:3]
txt = open(chk_out, "r", encoding="utf-8", errors="replace").read()
m = re.search(r"MacSweepChecks summary:\s*(\d+)\s*passed,\s*(\d+)\s*failed", txt)
if not m:
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write("Could not parse MacSweepChecks summary")
    sys.exit(1)
p, f = int(m.group(1)), int(m.group(2))
if f != 0 or p < 100:
    with open(err_file, "w", encoding="utf-8") as ef:
        ef.write(f"MacSweepChecks failed: passed={p}, failed={f}")
    sys.exit(1)
print(p)
PYEOF
)" || return 1

    verify_docs_parity_and_links "$err_file" "$passed_count" || return 1
    verify_png_set_and_privacy "$REPO_ROOT/docs/screenshots" "$err_file" 1
}

# Execute 6 disjoint Tier 3 & Tier 4 shell cases
run_case 3 "F-1+F-11" "t3-sh-planning-readme-parity" "PLANNING.md and README*.md parity, link integrity, and 8 screenshots exist" case_t3_sh_planning_readme_parity
run_case 3 "F-10+F-11" "t3-sh-demo-multilang-theme-export" "Demo mode EN/deepOcean and ZH/system exports produce distinct Retina PNGs with zero PII" case_t3_sh_demo_multilang_theme_export
run_case 3 "F-10" "t3-sh-demo-tabs-isolated-home" "All 7 --demo-tab views export cleanly and dwell in isolated HOME without disk writes" case_t3_sh_demo_tabs_isolated_home
run_case 3 "F-1+F-6+F-11" "t3-sh-checks-live-audit-readme-count" "MacSweepChecks + --live-audit pass and README*.md counts match exact check count" case_t3_sh_checks_live_audit_readme_count

run_case 4 "F-10+F-11" "t4-sh-desensitized-release-screenshots" "Bundled make_app.sh MacSweep.app exports 8 valid zero-PII Retina screenshots matching docs/screenshots" case_t4_sh_desensitized_release_screenshots
run_case 4 "F-1+F-10+F-11" "t4-sh-full-release-bundle-and-docs-audit" "Full GitHub release gate: bundle signing/libs/zip, static hygiene, MacSweepChecks, docs, and screenshots" case_t4_sh_full_release_bundle_and_docs_audit

echo "E2E_SUMMARY tier=$TIER passed=$PASSED failed=$FAILED total=$TOTAL"
write_json_report

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
