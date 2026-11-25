#!/usr/bin/env bash
set -euo pipefail

CALLER_PWD="$PWD"
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
E2E_BUILD_PATH="${MACSWEEP_E2E_SCRATCH_PATH:-$E2E_DIR/.build}"
SWIFT_BIN="${MACSWEEP_SWIFT_BIN:-/usr/bin/swift}"
PYTHON_BIN="${MACSWEEP_PYTHON_BIN:-/usr/bin/python3}"

export MACSWEEP_REPO_ROOT="$REPO_ROOT"
export MACSWEEP_E2E_DIR="$E2E_DIR"
export MACSWEEP_SCRATCH_PATH="${MACSWEEP_SCRATCH_PATH:-$E2E_DIR/.build/app-scratch}"

TIER="all"
MODE="strict"
JSON_OUTPUT=""
FILTER=""
PROBE_ARGS=()

usage() {
    cat <<'EOF'
Usage: run_e2e.sh [OPTIONS]

Options:
  --tier <1|2|3|4|all>   Run a specific E2E tier or all tiers (default: all)
  --strict               Fail on any compile error, test failure, or threshold shortfall (default)
  --available            Smoke mode: skip non-baseline compile failures and stub probes;
                         still fails on E2EBaselineProbe compile errors or any executed test failure
  --probe <name>         Run only matching Swift probe(s) or shell suite(s) (repeatable or comma-separated)
  --filter <pattern>     Filter test cases by substring (passed to probes/suites)
  --json <path>          Write aggregated JSON report to <path> (resolved relative to caller PWD)
  -h, --help             Show this help message and exit

Thresholds (--strict mode without --probe/--filter):
  Tier 1 >= 55, Tier 2 >= 55, Tier 3 >= 11, Tier 4 >= 6, Total >= 127
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

add_probe_arg() {
    local raw="$1"
    local added=0
    local items=()
    IFS=',' read -r -a items <<< "$raw"
    for item in ${items[@]+"${items[@]}"}; do
        if [ -n "$item" ]; then
            PROBE_ARGS+=("$item")
            added=$((added + 1))
        fi
    done
    if [ "$added" -eq 0 ]; then
        echo "Error: --probe requires at least one non-empty probe name" >&2
        exit 2
    fi
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
        --strict)
            MODE="strict"
            shift
            ;;
        --available)
            MODE="available"
            shift
            ;;
        --probe)
            [ $# -ge 2 ] || { echo "Error: --probe requires a value" >&2; exit 2; }
            [ -n "$2" ] || { echo "Error: --probe requires a non-empty value" >&2; exit 2; }
            add_probe_arg "$2"
            shift 2
            ;;
        --probe=*)
            val="${1#--probe=}"
            [ -n "$val" ] || { echo "Error: --probe requires a non-empty value" >&2; exit 2; }
            add_probe_arg "$val"
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
            [ $# -ge 2 ] || { echo "Error: --json requires a path" >&2; exit 2; }
            [ -n "$2" ] || { echo "Error: --json requires a non-empty path" >&2; exit 2; }
            JSON_OUTPUT="$2"
            shift 2
            ;;
        --json=*)
            val="${1#--json=}"
            [ -n "$val" ] || { echo "Error: --json requires a non-empty path" >&2; exit 2; }
            JSON_OUTPUT="$val"
            shift
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

# Resolve --json path relative to caller's original PWD before any directory changes.
RESOLVED_JSON=""
if [ -n "$JSON_OUTPUT" ]; then
    RESOLVED_JSON="$("$PYTHON_BIN" -c 'import os, sys; print(os.path.abspath(os.path.join(sys.argv[1], sys.argv[2])))' "$CALLER_PWD" "$JSON_OUTPUT")"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macsweep-e2e-run.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
MANIFEST_TSV="$WORK_DIR/manifest.tsv"
: > "$MANIFEST_TSV"

# Discover Swift executable targets from Package.swift in deterministic order.
DUMP_PKG_JSON="$("$SWIFT_BIN" package --package-path "$E2E_DIR" --scratch-path "$E2E_BUILD_PATH" dump-package)"
DISCOVERED_PROBES_RAW="$("$PYTHON_BIN" -c '
import json, sys
pkg = json.load(sys.stdin)
preferred = ["E2EBaselineProbe", "E2EM1Probe", "E2EM2Probe", "E2EM3Probe", "E2EM4Probe", "E2ETier3Tier4Probe"]
execs = [t["name"] for t in pkg.get("targets", []) if t.get("type") == "executable"]
ordered = [p for p in preferred if p in execs]
extras = sorted(e for e in execs if e not in preferred)
for name in ordered + extras:
    print(name)
' <<< "$DUMP_PKG_JSON")"
DISCOVERED_PROBES=()
while IFS= read -r line; do
    if [ -n "$line" ]; then
        DISCOVERED_PROBES+=("$line")
    fi
done <<< "$DISCOVERED_PROBES_RAW"

# Discover executable shell suites in Tests/MacSweepE2E/suites/*.sh if present.
DISCOVERED_SUITES=()
if [ -d "$E2E_DIR/suites" ]; then
    for suite in "$E2E_DIR/suites"/*.sh; do
        [ -e "$suite" ] || continue
        if [ -x "$suite" ]; then
            DISCOVERED_SUITES+=("$suite")
        else
            echo "[WARN] Skipping non-executable suite script: $suite" >&2
        fi
    done
fi

probe_matches_filter() {
    local kind="$1"
    local name="$2"
    local path="$3"
    if [ ${#PROBE_ARGS[@]} -eq 0 ]; then
        return 0
    fi
    local req
    for req in "${PROBE_ARGS[@]}"; do
        if [ "$req" = "$name" ]; then
            return 0
        fi
        if [ "$kind" = "shell_suite" ]; then
            local base="${name%.sh}"
            if [ "$req" = "$base" ] || [ "$req" = "suites/$name" ] || [ "$req" = "$path" ]; then
                return 0
            fi
        fi
    done
    return 1
}

SELECTED_PROBES=()
for p in ${DISCOVERED_PROBES[@]+"${DISCOVERED_PROBES[@]}"}; do
    if probe_matches_filter "swift_probe" "$p" "$p"; then
        SELECTED_PROBES+=("$p")
    fi
done

SELECTED_SUITES=()
for s in ${DISCOVERED_SUITES[@]+"${DISCOVERED_SUITES[@]}"}; do
    sname="$(basename "$s")"
    if probe_matches_filter "shell_suite" "$sname" "$s"; then
        SELECTED_SUITES+=("$s")
    fi
done

if [ ${#PROBE_ARGS[@]} -gt 0 ] && [ ${#SELECTED_PROBES[@]} -eq 0 ] && [ ${#SELECTED_SUITES[@]} -eq 0 ]; then
    echo "Error: no probes or suites matched --probe selection: ${PROBE_ARGS[*]}" >&2
    exit 2
fi

echo "=== MacSweep E2E Runner (mode=$MODE tier=$TIER) ==="
echo "E2E Dir:      $E2E_DIR"
echo "Repo Root:    $REPO_ROOT"
echo "E2E Build:    $E2E_BUILD_PATH"
echo "App Scratch:  $MACSWEEP_SCRATCH_PATH"

BIN_DIR=""
TARGET_INDEX=0

for probe in ${SELECTED_PROBES[@]+"${SELECTED_PROBES[@]}"}; do
    TARGET_INDEX=$((TARGET_INDEX + 1))
    build_log="$WORK_DIR/${TARGET_INDEX}_${probe}.build.log"
    run_log="$WORK_DIR/${TARGET_INDEX}_${probe}.run.log"
    : > "$run_log"

    echo "--- Building Swift probe: $probe ---"
    set +e
    "$SWIFT_BIN" build --package-path "$E2E_DIR" --scratch-path "$E2E_BUILD_PATH" --product "$probe" >"$build_log" 2>&1
    build_rc=$?
    set -e

    if [ $build_rc -ne 0 ]; then
        if [ "$MODE" = "available" ] && [ "$probe" != "E2EBaselineProbe" ]; then
            echo "[UNAVAILABLE] $probe failed to compile (skipped under --available)"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$probe" "swift_probe" "unavailable" "$build_rc" "$build_log" "$run_log" >> "$MANIFEST_TSV"
            continue
        else
            echo "[COMPILE_FAILED] $probe failed to compile (exit $build_rc):" >&2
            cat "$build_log" >&2
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$probe" "swift_probe" "compile_failed" "$build_rc" "$build_log" "$run_log" >> "$MANIFEST_TSV"
            continue
        fi
    fi

    if [ -z "$BIN_DIR" ]; then
        BIN_DIR="$("$SWIFT_BIN" build --package-path "$E2E_DIR" --scratch-path "$E2E_BUILD_PATH" --show-bin-path)"
    fi

    probe_bin="$BIN_DIR/$probe"
    if [ ! -x "$probe_bin" ]; then
        echo "[COMPILE_FAILED] Missing built executable at $probe_bin" >&2
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$probe" "swift_probe" "compile_failed" "127" "$build_log" "$run_log" >> "$MANIFEST_TSV"
        continue
    fi

    cmd_args=("--tier" "$TIER")
    if [ -n "$FILTER" ]; then
        cmd_args+=("--filter" "$FILTER")
    fi

    echo "--- Running Swift probe: $probe (${cmd_args[*]}) ---"
    set +e
    "$probe_bin" "${cmd_args[@]}" >"$run_log" 2>&1
    run_rc=$?
    set -e
    cat "$run_log"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$probe" "swift_probe" "executed" "$run_rc" "$build_log" "$run_log" >> "$MANIFEST_TSV"
done

for suite in ${SELECTED_SUITES[@]+"${SELECTED_SUITES[@]}"}; do
    TARGET_INDEX=$((TARGET_INDEX + 1))
    sname="$(basename "$suite")"
    build_log="$WORK_DIR/${TARGET_INDEX}_${sname}.build.log"
    run_log="$WORK_DIR/${TARGET_INDEX}_${sname}.run.log"
    : > "$build_log"
    : > "$run_log"

    cmd_args=("--tier" "$TIER")
    if [ -n "$FILTER" ]; then
        cmd_args+=("--filter" "$FILTER")
    fi

    echo "--- Running shell suite: $sname (${cmd_args[*]}) ---"
    set +e
    "$suite" "${cmd_args[@]}" >"$run_log" 2>&1
    run_rc=$?
    set -e
    cat "$run_log"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sname" "shell_suite" "executed" "$run_rc" "$build_log" "$run_log" >> "$MANIFEST_TSV"
done

NARROWED="0"
if [ ${#PROBE_ARGS[@]} -gt 0 ] || [ -n "$FILTER" ]; then
    NARROWED="1"
fi

PROBE_FILTER_STR=""
if [ ${#PROBE_ARGS[@]} -gt 0 ]; then
    PROBE_FILTER_STR="$(printf '%s,' "${PROBE_ARGS[@]}")"
    PROBE_FILTER_STR="${PROBE_FILTER_STR%,}"
fi

"$PYTHON_BIN" - "$MANIFEST_TSV" "$MODE" "$TIER" "$NARROWED" "$PROBE_FILTER_STR" "$FILTER" "$RESOLVED_JSON" <<'PYEOF'
import json
import os
import re
import sys

manifest_path, mode, req_tier, narrowed_flag, probe_filter_str, text_filter, json_out_path = sys.argv[1:8]
narrowed = (narrowed_flag == "1")
probe_filter = [p for p in probe_filter_str.split(",") if p] if probe_filter_str else []
text_filter_val = text_filter if text_filter else None

ansi_re = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
case_re = re.compile(r"^\[TIER-([1-4])\]\[([^\]]+)\]\s+(.+?):\s+(PASS|FAIL)(?:\s+(.*))?$")
summary_re = re.compile(r"^E2E_SUMMARY\s+tier=(\S+)\s+passed=(\d+)\s+failed=(\d+)\s+total=(\d+)\s*$")
stub_re = re.compile(r"^(?:E2E_STUB\b|\[STUB\])")

THRESHOLDS = {"1": 55, "2": 55, "3": 11, "4": 6}
TOTAL_THRESHOLD = 127

tiers = {str(t): {"passed": 0, "failed": 0, "total": 0} for t in range(1, 5)}
cases = []
targets = []
unavailable_probes = []
stub_probes = []
failures_reasons = []

with open(manifest_path, "r", encoding="utf-8") as mf:
    rows = [line.rstrip("\n").split("\t") for line in mf if line.strip()]

for name, kind, exec_state, exit_code_str, build_log_path, run_log_path in rows:
    exit_code = int(exit_code_str)

    if exec_state == "unavailable":
        unavailable_probes.append(name)
        targets.append({
            "name": name,
            "kind": kind,
            "status": "unavailable",
            "exit_code": exit_code,
            "passed": 0,
            "failed": 0,
            "total": 0,
        })
        continue

    if exec_state == "compile_failed":
        failures_reasons.append(f"compile_failed: {name} (exit {exit_code})")
        targets.append({
            "name": name,
            "kind": kind,
            "status": "compile_failed",
            "exit_code": exit_code,
            "passed": 0,
            "failed": 0,
            "total": 0,
        })
        continue

    with open(run_log_path, "r", encoding="utf-8", errors="replace") as rf:
        raw_lines = rf.readlines()

    is_stub_marker = False
    target_cases = []
    summaries = []

    for raw_line in raw_lines:
        line = ansi_re.sub("", raw_line).rstrip("\r\n")
        if stub_re.match(line):
            is_stub_marker = True
        cm = case_re.match(line)
        if cm:
            tier_num = int(cm.group(1))
            feature = cm.group(2).strip()
            case_id = cm.group(3).strip()
            status = cm.group(4)
            target_cases.append((tier_num, feature, case_id, status))
            cases.append({
                "tier": tier_num,
                "feature": feature,
                "id": case_id,
                "status": status,
                "target": name,
            })
            t_key = str(tier_num)
            tiers[t_key]["total"] += 1
            if status == "PASS":
                tiers[t_key]["passed"] += 1
            else:
                tiers[t_key]["failed"] += 1
            continue

        sm = summary_re.match(line)
        if sm:
            summaries.append({
                "tier": sm.group(1),
                "passed": int(sm.group(2)),
                "failed": int(sm.group(3)),
                "total": int(sm.group(4)),
            })

    case_passed = sum(1 for c in target_cases if c[3] == "PASS")
    case_failed = sum(1 for c in target_cases if c[3] == "FAIL")
    case_total = len(target_cases)

    if case_total == 0 and len(summaries) > 0:
        # Fallback if a shell suite only emitted E2E_SUMMARY tier=<1..4>
        sum_passed = sum(s["passed"] for s in summaries)
        sum_failed = sum(s["failed"] for s in summaries)
        sum_total = sum(s["total"] for s in summaries)
        for s in summaries:
            if s["tier"] in ("1", "2", "3", "4"):
                tiers[s["tier"]]["passed"] += s["passed"]
                tiers[s["tier"]]["failed"] += s["failed"]
                tiers[s["tier"]]["total"] += s["total"]
        target_passed, target_failed, target_total = sum_passed, sum_failed, sum_total
    else:
        target_passed, target_failed, target_total = case_passed, case_failed, case_total

    summary_mismatch = False
    if summaries and case_total > 0:
        distinct_per_tier = (
            len(summaries) > 1
            and all(s["tier"] in ("1", "2", "3", "4") for s in summaries)
            and len({s["tier"] for s in summaries}) == len(summaries)
        )
        if distinct_per_tier:
            sum_passed = sum(s["passed"] for s in summaries)
            sum_failed = sum(s["failed"] for s in summaries)
            sum_total = sum(s["total"] for s in summaries)
            if (
                sum_passed != case_passed
                or sum_failed != case_failed
                or sum_total != case_total
            ):
                summary_mismatch = True
        else:
            last_sum = summaries[-1]
            if (
                last_sum["passed"] != case_passed
                or last_sum["failed"] != case_failed
                or last_sum["total"] != case_total
            ):
                summary_mismatch = True

    if is_stub_marker and target_total == 0 and exit_code == 0 and not summary_mismatch:
        stub_probes.append(name)
        targets.append({
            "name": name,
            "kind": kind,
            "status": "stub_failed" if mode == "strict" else "stub",
            "exit_code": exit_code,
            "passed": 0,
            "failed": 0,
            "total": 0,
        })
        continue

    target_status = "passed"
    if exit_code != 0 or target_failed > 0 or summary_mismatch:
        target_status = "failed"
        if exit_code != 0:
            failures_reasons.append(f"nonzero_exit: {name} (exit {exit_code})")
        if target_failed > 0:
            failures_reasons.append(f"failed_cases: {name} ({target_failed} failed)")
        if summary_mismatch:
            failures_reasons.append(f"summary_mismatch: {name}")

    targets.append({
        "name": name,
        "kind": kind,
        "status": target_status,
        "exit_code": exit_code,
        "passed": target_passed,
        "failed": target_failed,
        "total": target_total,
    })

totals_passed = sum(t["passed"] for t in tiers.values())
totals_failed = sum(t["failed"] for t in tiers.values())
totals_total = sum(t["total"] for t in tiers.values())

if mode == "strict" and len(stub_probes) > 0:
    failures_reasons.append(f"stub_in_strict: {', '.join(stub_probes)}")

if mode == "available":
    executed_non_stub = [t for t in targets if t["status"] in ("passed", "failed")]
    if not executed_non_stub and not stub_probes:
        failures_reasons.append("no_targets_executed")

threshold_violations = []
tiers_json = {}
for t_key in ("1", "2", "3", "4"):
    entry = dict(tiers[t_key])
    req = THRESHOLDS[t_key]
    met = entry["total"] >= req
    entry["threshold"] = req
    entry["threshold_met"] = met
    tiers_json[t_key] = entry

    if mode == "strict" and not narrowed:
        if req_tier == "all" or req_tier == t_key:
            if not met:
                threshold_violations.append(
                    f"Tier {t_key} count {entry['total']} < required {req}"
                )

if mode == "strict" and not narrowed and req_tier == "all":
    if totals_total < TOTAL_THRESHOLD:
        threshold_violations.append(
            f"Total count {totals_total} < required {TOTAL_THRESHOLD}"
        )

for tv in threshold_violations:
    failures_reasons.append(f"threshold_violation: {tv}")

overall_passed = (len(failures_reasons) == 0)

report = {
    "mode": mode,
    "requested_tier": req_tier,
    "narrowed": narrowed,
    "probe_filter": probe_filter,
    "text_filter": text_filter_val,
    "passed": overall_passed,
    "totals": {
        "passed": totals_passed,
        "failed": totals_failed,
        "total": totals_total,
    },
    "tiers": tiers_json,
    "targets": targets,
    "unavailable_probes": unavailable_probes,
    "stub_probes": stub_probes,
    "threshold_violations": threshold_violations,
    "cases": cases,
}

if json_out_path:
    parent = os.path.dirname(json_out_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(json_out_path, "w", encoding="utf-8") as jf:
        json.dump(report, jf, indent=2, sort_keys=False)
        jf.write("\n")

print("")
print("=== E2E Aggregation Summary ===")
print(f"Mode: {mode} | Requested Tier: {req_tier} | Narrowed: {narrowed}")
for t_key in ("1", "2", "3", "4"):
    t = tiers_json[t_key]
    print(
        f"  Tier {t_key}: passed={t['passed']} failed={t['failed']} total={t['total']} "
        f"(threshold>={t['threshold']}, met={t['threshold_met']})"
    )
print(f"  Total:  passed={totals_passed} failed={totals_failed} total={totals_total}")
if stub_probes:
    print(f"  Stub / Unimplemented: {', '.join(stub_probes)}")
if unavailable_probes:
    print(f"  Unavailable (compile skipped): {', '.join(unavailable_probes)}")
if threshold_violations:
    print("  Threshold Violations:")
    for tv in threshold_violations:
        print(f"    - {tv}")
if failures_reasons:
    print("  Result: FAIL")
    for fr in failures_reasons:
        print(f"    - {fr}")
else:
    print("  Result: PASS")

sys.exit(0 if overall_passed else 1)
PYEOF
