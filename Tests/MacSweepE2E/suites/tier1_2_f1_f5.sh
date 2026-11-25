#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="${MACSWEEP_E2E_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO_ROOT="${MACSWEEP_REPO_ROOT:-$(cd "$E2E_DIR/../.." && pwd)}"
PYTHON_BIN="${MACSWEEP_PYTHON_BIN:-/usr/bin/python3}"

TIER="all"
FILTER=""

usage() {
    cat <<'EOF'
Usage: tier1_2_f1_f5.sh [OPTIONS]

Options:
  --tier <1|2|3|4|all>   Select tier to execute (default: all)
  --filter <pattern>     Case-insensitive substring filter on "<id> <feature> <name>"
  -h, --help             Show help and exit
EOF
}

validate_tier() {
    case "$1" in
        1|2|3|4|all) return 0 ;;
        *)
            echo "Error: invalid --tier '$1' (expected 1, 2, 3, 4, or all)" >&2
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
        --)
            shift
            if [ $# -gt 0 ]; then
                echo "Error: unexpected positional arguments after --: $*" >&2
                exit 2
            fi
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

"$PYTHON_BIN" - "$REPO_ROOT" "$TIER" "$FILTER" <<'PYEOF'
import getpass
import os
import pwd
import re
import subprocess
import sys

repo_root, req_tier, text_filter = sys.argv[1:4]
planning_path = os.path.join(repo_root, "docs", "PLANNING.md")

def read_planning_bytes():
    with open(planning_path, "rb") as f:
        return f.read()

def read_planning_text():
    return read_planning_bytes().decode("utf-8")

def check_doc_exists_nonempty():
    if not os.path.lexists(planning_path):
        return False, "docs/PLANNING.md does not exist"
    if os.path.islink(planning_path):
        return False, "docs/PLANNING.md must be a regular file, not a symlink"
    if not os.path.isfile(planning_path):
        return False, "docs/PLANNING.md is not a regular file"
    raw = read_planning_bytes()
    if len(raw) <= 10000:
        return False, f"docs/PLANNING.md too small ({len(raw)} bytes <= 10000)"
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return False, f"docs/PLANNING.md invalid UTF-8: {exc}"
    return True, ""

def check_covers_file_manager():
    text = read_planning_text()
    required = [
        ("Space Analyzer", ["Space Analyzer", "空间分析"]),
        ("DiskSpaceAnalyzer", ["DiskSpaceAnalyzer"]),
        ("General File Browser", ["File Browser", "文件浏览"]),
        ("FileBrowserService", ["FileBrowserService"]),
        ("Preview", ["QuickLook", "SafeFileReader"]),
        ("FileOperationsEngine", ["FileOperationsEngine"]),
        ("SafetyGuard", ["SafetyGuard"]),
    ]
    missing = [label for label, tokens in required if not any(t in text for t in tokens)]
    if missing:
        return False, "missing File Manager coverage: " + ", ".join(missing)
    return True, ""

def check_covers_junk_and_resources():
    text = read_planning_text()
    required = [
        ("JunkCacheScanner", ["JunkCacheScanner"]),
        ("Junk categories", ["sharedVendorFolderNames", "Browser Caches", "浏览器缓存", "Developer Caches", "开发者工具缓存", "Trash", "废纸篓"]),
        ("Large Files", ["LargeAndDuplicateScanner", "LargeFileItem", "大文件"]),
        ("3-stage SHA256 Duplicates", ["DuplicateGroup", "SHA-256", "SHA256", "CryptoKit.SHA256"]),
        ("Mach VM Memory Monitor & Release", ["MemoryReleaseService", "MemorySnapshot", "host_statistics64", "vm.swapusage"]),
    ]
    missing = [label for label, tokens in required if not any(t in text for t in tokens)]
    if missing:
        return False, "missing Junk/Resource coverage: " + ", ".join(missing)
    return True, ""

def check_covers_demo_and_readme():
    text = read_planning_text()
    required = [
        ("--demo-mode", ["--demo-mode", "MACSWEEP_DEMO_MODE"]),
        ("/Users/alex", ["/Users/alex"]),
        ("DemoFixtureCatalog", ["DemoFixtureCatalog"]),
        ("Retina screenshots", ["docs/screenshots/", "DemoScreenshotExporter", "2x Retina", "2240x1400"]),
        ("README showcase layout", ["README.md", "README_EN.md", "README_ZH.md"]),
    ]
    missing = [label for label, tokens in required if not any(t in text for t in tokens)]
    if missing:
        return False, "missing Demo/README coverage: " + ", ".join(missing)
    return True, ""

def check_covers_phased_roadmap():
    text = read_planning_text()
    required = ["M1", "M2", "M3", "M4", "M5", "E2E", "Acceptance Criteria"]
    missing = [tok for tok in required if tok not in text]
    if missing:
        return False, "missing Roadmap/Acceptance tokens: " + ", ".join(missing)
    if not re.search(r"^\|\s*\*?\*?M1\*?\*?\s*\|", text, re.MULTILINE):
        return False, "missing phased roadmap table row for M1"
    if not re.search(r"^\|\s*\*?\*?M5\*?\*?\s*\|", text, re.MULTILINE):
        return False, "missing phased roadmap table row for M5"
    if not re.search(r"^\s*-\s*\[[ xX]\]", text, re.MULTILINE):
        return False, "missing Acceptance Criteria checklist items"
    return True, ""

def check_zero_placeholders():
    text = read_planning_text()
    matches = re.findall(r"\b(?:TODO|TBD|FIXME|XXX|PLACEHOLDER)\b", text, flags=re.IGNORECASE)
    if matches:
        unique = sorted(set(m.upper() for m in matches))
        return False, f"found placeholder marker(s): {', '.join(unique)}"
    return True, ""

def check_zero_host_pii():
    text = read_planning_text()
    candidates = set()
    for env_key in ("USER", "LOGNAME"):
        val = os.environ.get(env_key, "").strip()
        if val:
            candidates.add(val)
    try:
        candidates.add(getpass.getuser().strip())
    except Exception:
        pass
    try:
        pw = pwd.getpwuid(os.getuid())
        if pw.pw_name:
            candidates.add(pw.pw_name.strip())
    except Exception:
        pass
    for cmd in (["id", "-un"], ["whoami"]):
        try:
            out = subprocess.check_output(cmd, text=True, timeout=5).strip()
            if out:
                candidates.add(out)
        except Exception:
            pass

    home_paths = set()
    for hp in (os.path.expanduser("~"), os.environ.get("HOME", "")):
        hp = hp.strip()
        if hp and hp != "/Users/alex":
            home_paths.add(hp)
            home_paths.add(os.path.realpath(hp))

    for hp in sorted(home_paths):
        if hp in text:
            return False, "real host home path leaked in docs/PLANNING.md"

    for uname in sorted(candidates):
        if not uname or uname.lower() == "alex":
            continue
        if re.search(r"/Users/" + re.escape(uname) + r"(?:\b|/)", text, flags=re.IGNORECASE):
            return False, "real host /Users/<user> path leaked in docs/PLANNING.md"
        if len(uname) >= 3 and re.search(r"(?<![A-Za-z0-9_])" + re.escape(uname) + r"(?![A-Za-z0-9_])", text, flags=re.IGNORECASE):
            return False, "real host username leaked in docs/PLANNING.md"

    return True, ""

def check_markdown_integrity():
    text = read_planning_text()
    lines = text.splitlines()

    h1_count = 0
    h2_count = 0
    fence_count = 0
    fence_char = None
    fence_len = 0
    i = 0
    repo_real = os.path.realpath(repo_root)

    def is_within_repo(cand_path):
        cand_real = os.path.realpath(cand_path)
        try:
            return os.path.commonpath([repo_real, cand_real]) == repo_real
        except ValueError:
            return False

    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        if fence_char is None:
            fence_open = re.match(r"^(`{3,}|~{3,})(.*)$", stripped)
            if fence_open:
                seq, info = fence_open.group(1), fence_open.group(2)
                if not (seq[0] == "`" and "`" in info):
                    fence_char = seq[0]
                    fence_len = len(seq)
                    fence_count += 1
                    i += 1
                    continue
        else:
            fence_close = re.match(r"^(" + re.escape(fence_char) + r"{" + str(fence_len) + r",})\s*$", stripped)
            if fence_close:
                fence_char = None
                fence_len = 0
                fence_count += 1
                i += 1
                continue

        if fence_char is None:
            if line.startswith("# "):
                h1_count += 1
            elif line.startswith("## "):
                h2_count += 1

            # Parse contiguous Markdown tables
            if re.match(r"^\s*\|.*\|\s*$", line):
                table_lines = []
                while i < len(lines) and re.match(r"^\s*\|.*\|\s*$", lines[i]):
                    table_lines.append((i + 1, lines[i].strip()))
                    i += 1
                if len(table_lines) < 2:
                    return False, f"malformed table at line {table_lines[0][0]} (fewer than 2 rows)"
                def split_cols(row):
                    # Count unescaped pipes inside outer | ... |
                    inner = row[1:-1]
                    cols = re.split(r"(?<!\\)\|", inner)
                    return len(cols)
                header_cols = split_cols(table_lines[0][1])
                sep_line_no, sep_row = table_lines[1]
                if not re.match(r"^\|(\s*:?-{3,}:?\s*\|)+\s*$", sep_row):
                    return False, f"missing or invalid table separator at line {sep_line_no}"
                for ln, row in table_lines:
                    c = split_cols(row)
                    if c != header_cols:
                        return False, f"table column mismatch at line {ln}: expected {header_cols}, got {c}"
                continue

            # Check local Markdown links and image links outside inline code spans
            cleaned = re.sub(r"`[^`]*`", "", line)
            for match in re.finditer(r"!?\[([^\]]*)\]\(([^)]+)\)", cleaned):
                target = match.group(2).strip()
                if not target or target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                target_path = target.split("#", 1)[0]
                if not target_path:
                    continue
                cand_docs = os.path.normpath(os.path.join(os.path.dirname(planning_path), target_path))
                cand_root = os.path.normpath(os.path.join(repo_root, target_path))
                ok = False
                for cand in (cand_docs, cand_root):
                    if is_within_repo(cand) and os.path.exists(cand):
                        ok = True
                        break
                if not ok:
                    return False, f"broken local Markdown link target '{target}' at line {i + 1}"
        i += 1

    if fence_char is not None or fence_count % 2 != 0:
        return False, f"unbalanced fenced code blocks (count={fence_count})"
    if h1_count < 1 or h2_count < 5:
        return False, f"insufficient Markdown headings (h1={h1_count}, h2={h2_count})"
    return True, ""

def check_repo_paths_and_conventions():
    text = read_planning_text()
    cited_baseline_paths = [
        "Package.swift",
        "make_app.sh",
        ".github/workflows/ci.yml",
        "README.md",
        "README_EN.md",
        "README_ZH.md",
        "Resources/AppIcon-1024.png",
        "SECURITY.md",
        "scripts/publish_preview.sh",
        "docs/PLANNING.md",
    ]
    for rel in cited_baseline_paths:
        if rel not in text:
            return False, f"expected baseline path '{rel}' not cited in docs/PLANNING.md"
        full = os.path.join(repo_root, rel)
        if not os.path.exists(full):
            return False, f"cited baseline path '{rel}' does not exist on disk"

    # Every /Users/<name> path in planning doc must be /Users/alex
    for user_ref in re.findall(r"/Users/([A-Za-z0-9._-]+)", text):
        if user_ref != "alex":
            return False, f"non-fictional /Users/{user_ref} path found in docs/PLANNING.md"

    if "../" in text:
        return False, "parent-directory traversal '../' found in docs/PLANNING.md"

    return True, ""

def check_utf8_bilingual_and_status_sanity():
    raw = read_planning_bytes()
    if b"\x00" in raw:
        return False, "NUL byte found in docs/PLANNING.md"
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return False, f"invalid UTF-8: {exc}"

    for idx, line in enumerate(text.splitlines(), start=1):
        if len(line) > 2000:
            return False, f"oversized line {idx} ({len(line)} chars > 2000)"

    has_cjk = any("\u4e00" <= ch <= "\u9fff" for ch in text)
    has_ascii_words = bool(re.search(r"[A-Za-z]{4,}", text))
    if not (has_cjk and has_ascii_words):
        return False, "docs/PLANNING.md must contain bilingual Chinese + English technical content"

    if ("Status Legend" not in text and "M0 Baseline" not in text) or ("Planned" not in text and "规划演进" not in text):
        return False, "missing baseline vs planned status distinction"

    if "29" not in text or "59" not in text:
        return False, "missing stale README check count remediation plan (29 vs 59)"

    return True, ""

CASES = [
    (1, "F-1", "f1-doc-exists-nonempty", "docs/PLANNING.md exists as regular non-symlink UTF-8 file > 10000 bytes", check_doc_exists_nonempty),
    (1, "F-1", "f1-covers-file-manager", "docs/PLANNING.md covers Space Analyzer and General File Browser with SafetyGuard and FileOperationsEngine", check_covers_file_manager),
    (1, "F-1", "f1-covers-junk-and-resources", "docs/PLANNING.md covers JunkCacheScanner categories, Large Files, 3-stage SHA256 Duplicates, and Mach VM Memory Release", check_covers_junk_and_resources),
    (1, "F-1", "f1-covers-demo-and-readme", "docs/PLANNING.md covers --demo-mode, /Users/alex, DemoFixtureCatalog, Retina screenshot plan, and README layout", check_covers_demo_and_readme),
    (1, "F-1", "f1-covers-phased-roadmap", "docs/PLANNING.md covers M1-M5 + E2E phased roadmap table and Acceptance Criteria checklist", check_covers_phased_roadmap),
    (2, "F-1", "f1-zero-placeholders", "docs/PLANNING.md has zero TODO/TBD/FIXME/XXX/PLACEHOLDER markers", check_zero_placeholders),
    (2, "F-1", "f1-zero-host-pii", "docs/PLANNING.md has zero real host username, HOME, or /Users/<realuser> leaks", check_zero_host_pii),
    (2, "F-1", "f1-markdown-integrity", "docs/PLANNING.md has valid headings, balanced code fences, consistent tables, and zero broken local links", check_markdown_integrity),
    (2, "F-1", "f1-repo-paths-and-conventions", "docs/PLANNING.md cited baseline/M1 repo-relative paths exist on disk and follow repo conventions", check_repo_paths_and_conventions),
    (2, "F-1", "f1-utf8-bilingual-and-status-sanity", "docs/PLANNING.md is clean UTF-8 without NUL or oversized lines, bilingual, and tracks baseline vs planned status + stale README count fix", check_utf8_bilingual_and_status_sanity),
]

passed = 0
failed = 0
total = 0
filter_lower = text_filter.lower()

for tier, feature, case_id, name, fn in CASES:
    if req_tier != "all" and str(tier) != req_tier:
        continue
    if filter_lower and filter_lower not in f"{case_id} {feature} {name}".lower():
        continue

    total += 1
    try:
        ok, reason = fn()
    except Exception as exc:
        ok, reason = False, f"unexpected exception: {exc}"

    if ok:
        passed += 1
        print(f"[TIER-{tier}][{feature}] {case_id}: PASS", flush=True)
    else:
        failed += 1
        single_line = " ".join(str(reason).splitlines()).strip()
        print(f"[TIER-{tier}][{feature}] {case_id}: FAIL ({single_line})", flush=True)

print(f"E2E_SUMMARY tier={req_tier} passed={passed} failed={failed} total={total}", flush=True)
sys.exit(0 if failed == 0 else 1)
PYEOF
