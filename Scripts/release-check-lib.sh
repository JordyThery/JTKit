#!/bin/zsh
# JTKit release check, loaded by each app’s
# Scripts/release-check.sh from the JTKit version the app resolved, so the
# script matches the JTKit under test.
#
# The app’s script sets, then calls `release_check_main "$@"`:
#   APP_NAME APP_CODE PROJECT SCHEME UNIT_TESTS UI_TESTS SMOKE_CLASS
#   SIGNIN_TEST CLEANUP_TEST LIVE_TESTS=(…) ROLES=(…)
#   CREDENTIALS=("role:service:item" …)   read from the Keychain the allow-list names
#     right before stage 1's sign-in and stage 4, and forgotten in between
#   FINGERPRINT_PATHS=(…) KEYCHAIN_PREFIXES=(…)
#   FINGERPRINT_DEFAULTS=("<domain> <key>" …)   optional: single
#     UserDefaults values, for apps whose connections share a preferences file
#     with window frames and other state macOS changes during a UI test
#   TEST_HOST_CONTAINER="<bundle ID>"   optional, for a sandboxed app:
#     its test host can only reach its own container, so the live folder (the
#     allow-list copy, ledger and results) lives there, readable by you only
#   SMOKE_FILE="<path of the smoke-test class’s file>"   its test1…testN run in order
#   APP_FAULTS=(…)   optional: the app’s own --fault cases, handled by
#     its tests through JTKIT_LIVE_FAULT; the report says FAULT TEST as for the others
#   READ_ONLY_ROLES=(…)   optional: roles this app keeps read only,
#     whatever access the allow-list grants (stricter only, never looser)
#   HOST_KEYCHAIN_TEST="<selection>"   optional: a test in the app’s
#     test host that calls LiveCheckRun.recordHostKeychainNames(services:accessGroups:), for
#     Keychain items `security` can’t list (the data-protection keychain, e.g.
#     MSAL’s cache in its own access group). Run after the build ("before")
#     and after cleanup ("after"), also when stage 4 didn’t run; only hashes of
#     the item names are written, and the two must be equal.
#   LEGACY_PREFIXES is ignored: the one-time sweep of older test prefixes is over.
#
# Apple Business or Apple School Manager: every request to an organization,
# sign-in included, is paced to 9 a minute and capped at 40 a run (all test
# processes together, counted in the live folder’s apple-requests.jsonl); the
# report shows the count per role.
#
# Production roles in ROLES (marked production on the allow-list) take part
# only with --include-production: otherwise they are left out, and
# their CREDENTIALS aren’t read.
#
# One release check per Mac at a time: a lock in state/ beside the
# allow-list; a second check stops before it reads or changes anything.
#
# A test selection passes only when it ran at least one test and, except the
# unit tests (where live checks skip themselves), skipped none; a live step
# must also have added its line to results.jsonl, and the cleanup its
# "cleanup" line. Live steps and the cleanup are never run twice (a crash may
# already have changed a tenant); the other selections run once more when
# xcodebuild gave no result. Every test runs with JTKIT_RELEASE_CHECK=1.
#
# Stages, stopping at the first failure (cleanup and the report run either way):
#   1 build from the app’s own project and sign in to its allow-listed tenants
#   2 unit tests   3 UI smoke tests in demo mode   4 live checks   5 report
#
# Options: --local-jtkit (build in Apps.xcworkspace against the local JTKit;
# the report says "pre-release"), --tenants (sign in to every allow-listed
# tenant), --include-production, --stop-before-live (stages 1–3, then report),
# --fault <case> (tests the check itself; the report says FAULT TEST and never
# "passed"): break-build (a compile error in the test target), fail-live-step
# (a live step fails after creating objects), interrupt-live (stage 4 is killed
# without cleanup once objects exist; the next run must find and remove them).
# Apps may add their own cases (APP_FAULTS).
#
# A check that can’t run (a Python block or a command that fails, an
# unreadable file) fails the run and is named in the report; only a
# file that isn’t there yet counts as "none".
# Without --fault no fault can be on: inherited fault variables are cleared.
#
# Secrets: read from the login Keychain into TEST_RUNNER_* variables only,
# never echoed, never written to a file; xcodebuild’s output goes to logs in
# the run folder, which never contain them (tests paste, never print).

setopt pipe_fail

RC_BASE="$HOME/Library/Application Support/JTKit Release Check"
# Always this file: no setting moves it.
RC_ALLOWLIST="$RC_BASE/allowlist.json"
RC_PY=/usr/bin/python3

rc_log() { print -r -- "[$(date +%H:%M:%S)] $*" | tee -a "$RC_RUN/run.log" }
rc_stage() { RC_STAGE_NAMES+=("$1"); RC_STAGE_STATUS+=("$2"); rc_log "Stage $1: $2" }
rc_fail() { rc_log "FAILED: $*"; RC_FAILED="$*"; exit 1 }
# A check that couldn’t run (a Python block or command that failed) fails the
# run, named in the report: never skipped, never taken as passed.
rc_check_failed() { rc_log "CHECK FAILED: $*"; RC_CHECK_ERRORS+=("$*") }

# MARK: Preflight

rc_check_allowlist() {
    [[ -f "$RC_ALLOWLIST" ]] || rc_fail "No allow-list at $RC_ALLOWLIST"
    local mode=$(stat -f %Lp "$RC_ALLOWLIST")
    [[ "$mode" == 600 || "$mode" == 400 ]] || rc_fail "The allow-list must be readable by you only (chmod 600); it is $mode"
    local dir="${RC_ALLOWLIST:h}"
    while [[ "$dir" != "/" ]]; do
        [[ -e "$dir/.git" ]] && rc_fail "The allow-list lies inside a git work tree ($dir)"
        dir="${dir:h}"
    done
    "$RC_PY" - "$RC_ALLOWLIST" "${ROLES[@]}" <<'EOF' || rc_fail "The app’s roles aren’t all on the allow-list"
import json, sys
tenants = json.load(open(sys.argv[1]))["tenants"]
known = {t["role"] for t in tenants}
missing = [r for r in sys.argv[2:] if r not in known]
if missing:
    print("Not on the allow-list: " + ", ".join(missing)); sys.exit(1)
EOF
}

# The Keychain service the allow-list names for a role’s service.
rc_keychain_service() {
    "$RC_PY" - "$RC_ALLOWLIST" "$1" "$2" <<'EOF'
import json, sys
for t in json.load(open(sys.argv[1]))["tenants"]:
    if t["role"] == sys.argv[2] and t["service"] == sys.argv[3]:
        print(t.get("keychainService") or ""); break
EOF
}

# Reads each CREDENTIALS item into TEST_RUNNER_JTKIT_LIVE_<ROLE>_<ITEM>.
# The value goes straight into the variable; nothing is printed.
rc_read_credentials() {
    local spec role service item kc account var value
    for spec in "${CREDENTIALS[@]}"; do
        role="${spec%%:*}"; service="${${spec#*:}%%:*}"; item="${spec##*:}"
        # A role left out of this run (production without --include-production): not read.
        (( ${RC_ROLES[(Ie)$role]} )) || continue
        kc="$(rc_keychain_service "$role" "$service")" || rc_fail "Check failed: reading the allow-list’s Keychain service for $role ($service)"
        [[ -n "$kc" ]] || rc_fail "The allow-list names no Keychain service for $role ($service)"
        account="$item"
        [[ "$kc" == "be.jordythery.release-check" ]] && account="$role/$item"
        var="TEST_RUNNER_JTKIT_LIVE_${${(U)role}//[^A-Z0-9]/_}_${${(U)item}//[^A-Z0-9]/_}"
        if ! value="$(security find-generic-password -s "$kc" -a "$account" -w 2>/dev/null)"; then
            rc_fail "No Keychain item $kc / $account for $role. Run: $RC_LIB_DIR/release-check-setup.sh $role $item"
        fi
        export "$var=$value"
        RC_SECRET_VARS+=("$var")
    done
    unset value
}

rc_forget_credentials() {
    local var
    for var in "${RC_SECRET_VARS[@]}"; do unset "$var"; done
    RC_SECRET_VARS=()
}

# MARK: JTKit version

# The JTKit under test: its own `JTKit.version` and the commit, e.g.
# "0.13.1 (5be67d9)" (with --dirty: "-dirty" for uncommitted changes). Read
# from the source, not from git tags, which a package checkout may not have.
rc_jtkit_version() {
    local root="$RC_LIB_DIR/.." version commit
    version="$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' "$root/Sources/JTKit/JTKit.swift" 2>/dev/null | head -1)"
    commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)"
    if [[ "$1" == --dirty && -n "$commit" && -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
        commit="$commit-dirty"
    fi
    print -r -- "${version:-unknown}${commit:+ ($commit)}"
}

# MARK: Fingerprint (no secrets read)

rc_fingerprint() {
    local out="$1" item hash
    : > "$out.names" || { rc_check_failed "fingerprint: can’t write $out.names"; return 1 }
    # An app that leaves one of these lists unset gets one empty entry in
    # zsh ("${unset[@]}"): empty entries are skipped, never fingerprinted.
    for item in "${FINGERPRINT_PATHS[@]}"; do
        [[ -n "$item" ]] || continue
        if [[ -d "$item" ]]; then
            # Every file must be readable: an unreadable one fails the check.
            hash="$(cd "$item" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)" \
                || rc_check_failed "fingerprint of the folder $item"
            print -r -- "dir $item $hash" >> "$out.names"
        elif [[ -f "$item" ]]; then
            hash="$(shasum -a 256 < "$item" | cut -c1-16)" || rc_check_failed "fingerprint of the file $item"
            print -r -- "file $item $hash" >> "$out.names"
        else
            print -r -- "absent $item" >> "$out.names"
        fi
    done
    # Single settings: only a hash of each value is kept, never the value.
    local pair domain key value
    for pair in "${FINGERPRINT_DEFAULTS[@]}"; do
        [[ "$pair" == ?*" "?* ]] || continue
        domain="${pair%% *}"; key="${pair#* }"
        # defaults read answers 1 for a missing key: that is "absent".
        if value="$(/usr/bin/defaults read "$domain" "$key" 2>/dev/null)"; then
            hash="$(print -rn -- "$value" | shasum -a 256 | cut -c1-16)" || rc_check_failed "fingerprint of the setting $key"
            print -r -- "defaults $domain $key $hash" >> "$out.names"
        else
            print -r -- "defaults $domain $key absent" >> "$out.names"
        fi
    done
    unset value
    # Keychain item names only: service and account attributes, never data.
    local prefix names
    for prefix in "${KEYCHAIN_PREFIXES[@]}"; do
        [[ -n "$prefix" ]] || continue
        # A Keychain that can’t be listed (locked) fails the check, never "no items".
        names="$(security dump-keychain "$HOME/Library/Keychains/login.keychain-db" | "$RC_PY" -c '
import sys, re
prefix = sys.argv[1]; acct = None; items = []
for line in sys.stdin:
    if line.startswith("keychain:"): acct = None
    m = re.search(r"\"acct\"<blob>=\"(.*)\"", line)
    if m: acct = m.group(1)
    m = re.search(r"\"svce\"<blob>=\"(.*)\"", line)
    if m and m.group(1).startswith(prefix): items.append(m.group(1) + " / " + (acct or ""))
for i in sorted(set(items)): print("keychain " + i)
' "$prefix")" || { rc_check_failed "fingerprint of the Keychain items $prefix…"; continue }
        [[ -n "$names" ]] && print -r -- "$names" >> "$out.names"
    done
    shasum -a 256 < "$out.names" | cut -c1-16 > "$out" || rc_check_failed "fingerprint: hashing $out.names"
}

# MARK: Running tests

rc_xcodebuild_base() {
    if (( RC_LOCAL )); then
        RC_XB=(xcodebuild -workspace "$RC_WORKSPACE" -scheme "$SCHEME" -configuration Debug
               -destination "platform=macOS,arch=arm64" -derivedDataPath "$RC_DERIVED")
    else
        RC_XB=(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug
               -destination "platform=macOS,arch=arm64" -derivedDataPath "$RC_DERIVED"
               -clonedSourcePackagesDirPath "$RC_PACKAGES")
    fi
}

# Reads a test run’s result: answers 0 (passed: at least one test ran, none
# failed, and none was skipped unless $2 is 1), 3 (failed, with the reason
# printed) or 4 (no result at all). The result bundle ($3) comes first: its
# summary counts passed, failed and skipped tests whatever the log looks like.
# Without one, the xcodebuild log ($1): XCTest’s "Executed N tests, with K
# tests skipped and F failures", or its "Test case '…' passed|failed|skipped
# on '…'" lines, and Swift Testing’s "Test run with N tests … passed|failed"
# (N counts its skipped tests, each named on a "Test … skipped" line).
rc_test_outcome() {
    "$RC_PY" - "$1" "${2:-0}" "${3:-}" <<'EOF'
import json, os, re, subprocess, sys
path, allow_skips, bundle = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
text = ""
try:
    with open(path, errors="replace") as f: text = f.read()
except FileNotFoundError:
    if not bundle: print("no log"); sys.exit(4)
summary = None
if bundle and os.path.isdir(bundle):
    try:
        out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle],
                             capture_output=True, text=True, timeout=120)
        if out.returncode == 0:
            summary = json.loads(out.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        summary = None
if summary is not None and all(k in summary for k in ("passedTests", "failedTests", "skippedTests")):
    ran, skipped = int(summary["passedTests"]), int(summary["skippedTests"])
    failed = int(summary["failedTests"]) > 0 or summary.get("result") == "Failed"
    xc_failed = st_failed = 0
else:
    failed = False
    xctest = [(int(m.group(1)), int(m.group(2) or 0), int(m.group(3)))
              for m in re.finditer(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", text)]
    cases = re.findall(r"(?m)^Test case '[^'\n]+' (passed|failed|skipped) on '", text)
    swift = re.findall(r"Test run with (\d+) tests?\b[^\n]*? (passed|failed)\b", text)
    if not xctest and not cases and not swift:
        print("no result"); sys.exit(4)
    executed = max((e[0] for e in xctest), default=0)
    xc_skipped = max((e[1] for e in xctest), default=0)
    xc_failed = max((e[2] for e in xctest), default=0)
    if not xctest and cases:
        executed, xc_skipped, xc_failed = len(cases), cases.count("skipped"), cases.count("failed")
    st_total = int(swift[-1][0]) if swift else 0
    st_failed = bool(swift) and swift[-1][1] == "failed"
    st_skipped = len(re.findall(r"(?m)(?:^|\s)Test (?!Case |case |Suite |suite |run with )\S[^\n]*? skipped(?:[.:]|$)", text)) if swift else 0
    ran = (executed - xc_skipped) + (st_total - st_skipped)
    skipped = xc_skipped + st_skipped
if failed or xc_failed or st_failed or "** TEST EXECUTE FAILED **" in text or "** TEST FAILED **" in text:
    print("failed"); sys.exit(3)
if ran < 1:
    print(f"ran no tests ({skipped} skipped)" if skipped else "ran no tests"); sys.exit(3)
if skipped and not allow_skips:
    print(f"{skipped} skipped (a skipped test checks nothing)"); sys.exit(3)
print(f"{ran} passed" + (f", {skipped} skipped" if skipped else ""))
EOF
}

# The number of lines in the live folder’s results.jsonl (0 before the first).
rc_results_count() {
    local file="$RC_LIVE_DIR/results.jsonl" count
    [[ -e "$file" ]] || { print 0; return 0 }
    count="$(wc -l < "$file")" || return 1
    print $(( count ))
}

# Whether results.jsonl gained, after line $1, a line ($2 any) or the
# cleanup’s own "cleanup" line ($2 cleanup): 0 yes, 3 no.
rc_results_since() {
    "$RC_PY" - "$RC_LIVE_DIR/results.jsonl" "$1" "$2" <<'EOF'
import json, sys
path, start, kind = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    with open(path) as f: lines = [json.loads(l) for l in f.read().splitlines()[start:] if l.strip()]
except FileNotFoundError:
    lines = []
found = any(l.get("step") == "cleanup" for l in lines) if kind == "cleanup" else bool(lines)
sys.exit(0 if found else 3)
EOF
}

# Runs one -only-testing selection and reads its result (rc_test_outcome).
#   --once           never run again, also without a result (live steps and the
#                    cleanup: a crash may already have changed a tenant)
#   --allow-skips    the unit tests, where the live checks skip themselves
#   --results-line   a live step: it must add a line to results.jsonl
#   --cleanup-line   the cleanup: it must add its "cleanup" line
#   --label <name>   a second run of the same selection (its own logs and result bundle)
rc_test() {
    local selection="$1"; shift
    local retry=1 skips=0 needs="" label=""
    while (( $# )); do
        case "$1" in
            --once) retry=0 ;;
            --allow-skips) skips=1 ;;
            --results-line) needs=any ;;
            --cleanup-line) needs=cleanup ;;
            --label) shift; label=".$1" ;;
        esac
        shift
    done
    local name="${selection//\//-}$label" log attempt code verdict state before=0
    if [[ -n "$needs" ]]; then
        before="$(rc_results_count)" || { rc_check_failed "counting results.jsonl before $selection"; return 1 }
    fi
    for attempt in 1 2; do
        log="$RC_RUN/logs/$name.$attempt.log"
        "${RC_XB[@]}" test-without-building -only-testing:"$selection" -resultBundlePath "$RC_RUN/results/$name.$attempt.xcresult" > "$log" 2>&1
        code=$?
        verdict="$(rc_test_outcome "$log" "$skips" "$RC_RUN/results/$name.$attempt.xcresult")"
        state=$?
        case $state in
            0)
                if (( code )); then rc_log "  $selection: xcodebuild failed ($code) after: $verdict"; return 1; fi
                [[ -z "$needs" ]] && return 0
                rc_results_since "$before" "$needs"
                case $? in
                    0) return 0 ;;
                    3) rc_log "  $selection: passed, but added no $needs line to results.jsonl"; return 1 ;;
                    *) rc_check_failed "reading results.jsonl after $selection"; return 1 ;;
                esac ;;
            3) rc_log "  $selection: $verdict"; return 1 ;;
            4) ;;
            *) rc_check_failed "reading the result of $selection (logs/${log:t})"; return 1 ;;
        esac
        rc_log "  no result from $selection (attempt $attempt)"
        (( retry )) || return 1
        sleep "${RC_RETRY_WAIT:-5}"
    done
    return 1
}

rc_tests_in() {
    # The test methods of a class file, in file order.
    grep -hoE 'func (test[A-Za-z0-9_]+)\(\)' "$1" | sed -E 's/func (test[A-Za-z0-9_]+)\(\)/\1/'
}

rc_live_environment() {
    export TEST_RUNNER_JTKIT_LIVE=1
    export TEST_RUNNER_JTKIT_LIVE_RUN_DIR="$RC_LIVE_DIR"
    export TEST_RUNNER_JTKIT_LIVE_PREFIX="$RC_PREFIX"
    export TEST_RUNNER_JTKIT_LIVE_ROLES="${(j:,:)RC_ROLES}"
    (( RC_PRODUCTION )) && export TEST_RUNNER_JTKIT_LIVE_INCLUDE_PRODUCTION=1
    if [[ -n "$RC_FAULT" ]]; then export TEST_RUNNER_JTKIT_LIVE_FAULT="$RC_FAULT"; else unset TEST_RUNNER_JTKIT_LIVE_FAULT; fi
    # Writes (and so the sweep) only in stage 4; earlier stages read.
    export TEST_RUNNER_JTKIT_LIVE_WRITES="${1:-0}"
    # Only roles of this run: a production role left out isn’t named.
    local strict=() role
    for role in "${READ_ONLY_ROLES[@]}"; do (( ${RC_ROLES[(Ie)$role]} )) && strict+=("$role"); done
    if (( ${#strict} )); then export TEST_RUNNER_JTKIT_LIVE_READ_ONLY_ROLES="${(j:,:)strict}"; else unset TEST_RUNNER_JTKIT_LIVE_READ_ONLY_ROLES; fi
}

rc_live_off() {
    unset TEST_RUNNER_JTKIT_LIVE TEST_RUNNER_JTKIT_LIVE_RUN_DIR TEST_RUNNER_JTKIT_LIVE_PREFIX TEST_RUNNER_JTKIT_LIVE_ROLES \
          TEST_RUNNER_JTKIT_LIVE_INCLUDE_PRODUCTION TEST_RUNNER_JTKIT_LIVE_WRITES \
          TEST_RUNNER_JTKIT_LIVE_FAULT TEST_RUNNER_JTKIT_LIVE_READ_ONLY_ROLES
}

# --fault interrupt-live: runs the first live test, and once the ledger holds
# objects kills it and everything it started (as a crash or power cut would),
# then ends the run without cleanup. The next run’s stage 1 counts the
# leftovers and its stage 4 sweep removes them.
rc_interrupt_live() {
    local selection="$1" name="${1//\//-}"
    rc_log "  live (to be interrupted): $selection"
    "${RC_XB[@]}" test-without-building -only-testing:"$selection" > "$RC_RUN/logs/$name.interrupted.log" 2>&1 &
    local xb=$! waited=0 count
    while (( waited < 900 )); do
        count=$("$RC_PY" -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))))
except FileNotFoundError: print(0)' "$RC_LIVE_DIR/ledger.json") || { rc_check_failed "counting the ledger while interrupting"; break }
        (( count >= 2 )) && break
        kill -0 $xb 2>/dev/null || break
        sleep 2; (( waited += 2 ))
    done
    kill -9 $xb 2>/dev/null
    pkill -9 -f "$RC_DERIVED/Build/Products" 2>/dev/null
    sleep 2
    rc_stage "4 live checks" "INTERRUPTED on purpose (--fault interrupt-live), no cleanup"
    RC_CLEANUP_STATUS="skipped (interrupted on purpose)"
    RC_LIVE_STARTED=0
    rc_fail "Interrupted on purpose in stage 4 with test objects created; cleanup skipped, as after a crash"
}

# MARK: One release check per Mac

# Every release check sweeps its tenants for JTKTEST objects and adopts an
# earlier run’s live folder, so two at once (of any apps) could remove each
# other’s objects. The lock is a kernel lock (lockf) on a file beside the
# allow-list: taking it is one step, so two checks can’t both get it, and it
# ends with its holder, so there’s never a stale lock to remove.
#
# The holder is a small helper process, not this shell: while a zsh script
# holds a `zsystem flock` lock, its EXIT trap reads every `$(…)` as having
# succeeded, so the cleanup and the report (which run there) would miss a
# failure. The helper ends within a second once this shell is gone (also
# after a crash or kill -9) or its .held file is removed (rc_unlock);
# taking the lock waits that long. The holder’s
# process ID and app are in the .owner file beside it, for the message only.
RC_LOCK="$RC_BASE/state/release-check.lock"
rc_lock() {
    mkdir -p "$RC_BASE/state" && chmod 700 "$RC_BASE/state" || rc_fail "Can’t make $RC_BASE/state"
    [[ -e "$RC_LOCK" ]] || : >> "$RC_LOCK" || rc_fail "Can’t make the release-check lock at $RC_LOCK"
    local held="$RC_LOCK.held.$$" waited=0
    rm -f "$held"
    /usr/bin/lockf -s -t 2 "$RC_LOCK" /bin/sh -c \
        ': > "$2" || exit 1; while kill -0 "$1" 2>/dev/null && [ -e "$2" ]; do sleep 1; done; rm -f "$2"' \
        rc-lock $$ "$held" 2>/dev/null &!
    RC_LOCK_PID=$!
    # Taken once the helper says so; refused once it ends without saying so.
    while [[ ! -e "$held" ]] && kill -0 "$RC_LOCK_PID" 2>/dev/null && (( waited < 100 )); do
        sleep 0.05; (( waited++ ))
    done
    if [[ ! -e "$held" ]]; then
        kill "$RC_LOCK_PID" 2>/dev/null
        local holder="$(cat "$RC_LOCK.owner" 2>/dev/null)"
        rc_fail "Another release check is running on this Mac (${holder#* }, process ${holder%% *}); one at a time"
    fi
    RC_LOCKED=1
    print -r -- "$$ $APP_NAME" > "$RC_LOCK.owner"
}

rc_unlock() {
    (( ${RC_LOCKED:-0} )) || return 0
    [[ "$(cat "$RC_LOCK.owner" 2>/dev/null)" == "$$ $APP_NAME" ]] && rm -f "$RC_LOCK.owner"
    kill "$RC_LOCK_PID" 2>/dev/null
    rm -f "$RC_LOCK.held.$$"
    RC_LOCKED=0
}

# MARK: Live folder

# Where the test host reads the allow-list and writes the ledger and results:
# $RC_RUN/live, or for a sandboxed test host (TEST_HOST_CONTAINER) a folder of
# this run’s in the app’s container, readable by you only, with a copy of the
# allow-list. What the tests write there is copied back to $RC_RUN/live for
# the report. A folder an earlier run left (it crashed, or its cleanup didn’t
# finish) is kept until this run has read its ledger and removed its objects.
rc_live_setup() {
    RC_LIVE_DIR="$RC_RUN/live" RC_LIVE_ALLOWLIST="$RC_ALLOWLIST" RC_LIVE_PARENT=""
    if [[ -n "${TEST_HOST_CONTAINER:-}" ]]; then
        local data="$HOME/Library/Containers/$TEST_HOST_CONTAINER/Data"
        [[ -d "$data/tmp" ]] || rc_fail "No container for $TEST_HOST_CONTAINER at $data (open the app once)"
        RC_LIVE_PARENT="$data/tmp/JTKitReleaseCheck"
        mkdir -p "$RC_LIVE_PARENT" && chmod 700 "$RC_LIVE_PARENT" || rc_fail "Can’t make $RC_LIVE_PARENT"
        RC_LIVE_DIR="$RC_LIVE_PARENT/${RC_RUN:t}"
        mkdir -m 700 "$RC_LIVE_DIR" || rc_fail "Can’t make the live folder $RC_LIVE_DIR"
        local mode dir
        for dir in "$RC_LIVE_PARENT" "$RC_LIVE_DIR"; do
            mode=$(stat -f %Lp "$dir")
            [[ "$mode" == 700 && "$(stat -f %u "$dir")" == "$(id -u)" ]] || rc_fail "$dir must be yours and readable by you only (700); it is $mode"
        done
        RC_LIVE_ALLOWLIST="$RC_LIVE_DIR/allowlist.json"
        ( umask 077; cp "$RC_ALLOWLIST" "$RC_LIVE_ALLOWLIST" ) && chmod 600 "$RC_LIVE_ALLOWLIST" || rc_fail "Can’t copy the allow-list"
        RC_ALLOWLIST_HASH="$(shasum -a 256 < "$RC_ALLOWLIST" | cut -d' ' -f1)"
        [[ "$(shasum -a 256 < "$RC_LIVE_ALLOWLIST" | cut -d' ' -f1)" == "$RC_ALLOWLIST_HASH" ]] || rc_fail "The allow-list copy differs from the allow-list"
        rc_log "Live folder (in the app’s container, 700): ${RC_LIVE_DIR:t}"
    fi
    rc_adopt_earlier_ledgers
}

# Earlier runs’ outstanding objects join this run’s ledger, so this run’s
# cleanup removes them: from this app’s run folders (runs/<APP_CODE>-*/live)
# and, for a sandboxed test host, its live folders in the app’s container.
# An object that can’t be adopted (not named as a test object, or on a
# tenant this run doesn’t use) fails stage 1. The folders are listed for
# rc_live_finish; a run folder whose objects are all removed is marked
# live/taken-over and not read again.
rc_adopt_earlier_ledgers() {
    "$RC_PY" - "$RC_BASE/runs" "$APP_CODE" "${RC_RUN:t}" "${RC_LIVE_PARENT:-}" "$RC_LIVE_DIR" "$RC_RUN/earlier-ledgers.json" \
        "$RC_ALLOWLIST" "${RC_ROLES[@]}" <<'EOF' || rc_fail "An earlier run’s ledger can’t be used (see run.log)"
import json, os, sys
runs, app, this_run, parent, current, out, allowlist = sys.argv[1:8]
roles = set(sys.argv[8:])
# The ledger targets of this run’s tenants (as LiveCheckRun.target names them).
targets = set()
with open(allowlist) as f:
    for t in json.load(f)["tenants"]:
        if t["role"] not in roles: continue
        service = t["service"]
        if service == "jamfPlatform": targets.add("platform:" + (t.get("environmentID") or ""))
        elif service in ("jamfPro", "jamfSchool"): targets.add(t.get("host") or "")
        elif service == "intune": targets.add("intune:" + (t.get("entraTenantID") or ""))
        else: targets.add("apple:" + (t.get("clientID") or ""))
targets = {t.lower() for t in targets}
folders = []
if parent:
    for name in sorted(os.listdir(parent)):
        folder = os.path.join(parent, name)
        if folder != current and os.path.isdir(folder): folders.append(("container", name, folder))
if os.path.isdir(runs):
    for name in sorted(os.listdir(runs)):
        folder = os.path.join(runs, name, "live")
        if name.startswith(app + "-") and name != this_run and os.path.isdir(folder) \
                and not os.path.exists(os.path.join(folder, "taken-over")):
            folders.append(("runs", name, folder))
merged, earlier = [], []
key = lambda i: (i["target"], i["resource"], i["id"])
for kind, name, folder in folders:
    try:
        with open(os.path.join(folder, "ledger.json")) as f: items = json.load(f)
    except FileNotFoundError: items = []
    except (OSError, ValueError) as error:
        print(f"Unreadable ledger in {name}: {error}"); sys.exit(1)
    left = [i for i in items if not i.get("removed")]
    if kind == "runs" and not left: continue
    for i in left:
        if not str(i.get("name", "")).startswith("JTKTEST "):
            print(f"{name}’s ledger lists “{i.get('name')}”, which isn’t named as a test object"); sys.exit(1)
        if str(i.get("target", "")).lower() not in targets:
            print(f"{name}’s ledger lists {i.get('resource')} “{i.get('name')}” on a tenant this run doesn’t use: it can’t be removed"); sys.exit(1)
    earlier.append({"kind": kind, "folder": name, "items": [list(key(i)) for i in left]})
    for i in left:
        if key(i) not in {key(m) for m in merged}:
            # Read back by the network before its delete (an earlier run’s word only).
            merged.append(dict(i, removed=False, fromSweep=True, confirmed=False))
    print(f"Earlier {'live folder' if kind == 'container' else 'run'} {name}: {len(left)} objects still to remove")
if merged:
    os.makedirs(current, exist_ok=True)
    with open(os.path.join(current, "ledger.json"), "w") as f: json.dump(merged, f, indent=2, sort_keys=True)
with open(out, "w") as f: json.dump(earlier, f, indent=2)
EOF
}

# Copies what the tests wrote into the run folder (sandboxed test hosts only).
rc_live_sync() {
    [[ -n "${RC_LIVE_PARENT:-}" && -d "$RC_LIVE_DIR" ]] || return 0
    local file
    for file in ledger.json results.jsonl refusals.jsonl apple-requests.jsonl host-keychain.before host-keychain.after deletes.jsonl \
                unrecorded-creates.jsonl; do
        [[ -f "$RC_LIVE_DIR/$file" ]] && cp "$RC_LIVE_DIR/$file" "$RC_RUN/live/$file"
    done
    return 0
}

# Checks the allow-list copy (sandboxed test hosts), then finishes the
# folders whose objects are all gone: removes this run’s live folder and each
# earlier one in the app’s container, and marks each earlier run folder
# live/taken-over.
rc_live_finish() {
    if [[ -n "${RC_LIVE_PARENT:-}" ]]; then
        if [[ ! -f "$RC_LIVE_ALLOWLIST" ]]; then
            RC_ALLOWLIST_COPY="FAILED: the allow-list copy is missing"
        elif [[ "$(shasum -a 256 < "$RC_LIVE_ALLOWLIST" | cut -d' ' -f1)" != "$RC_ALLOWLIST_HASH" ]]; then
            RC_ALLOWLIST_COPY="FAILED: the allow-list copy changed during the run"
        else
            RC_ALLOWLIST_COPY="unchanged"
        fi
    fi
    local entry kind folder folders
    folders="$("$RC_PY" - "$RC_LIVE_DIR" "$RC_RUN/earlier-ledgers.json" "${RC_LIVE_PARENT:+container}" <<'EOF'
import json, os, sys
current, earlier_path, sandboxed = sys.argv[1], sys.argv[2], sys.argv[3] == "container"
try:
    with open(os.path.join(current, "ledger.json")) as f: items = json.load(f)
except FileNotFoundError: items = []
removed = {(i["target"], i["resource"], i["id"]) for i in items if i.get("removed")}
if sandboxed and all(i.get("removed") for i in items): print("container " + os.path.basename(current))
try:
    with open(earlier_path) as f: earlier = json.load(f)
except FileNotFoundError: earlier = []
for e in earlier:
    if all(tuple(k) in removed for k in e["items"]): print(e.get("kind", "container") + " " + e["folder"])
EOF
    )" || { rc_check_failed "deciding which live folders are finished"; folders="" }
    for entry in ${(f)folders}; do
        kind="${entry%% *}" folder="${entry#* }"
        [[ -n "$folder" && "$folder" != */* && "$folder" != .* ]] || continue
        if [[ "$kind" == container && -n "${RC_LIVE_PARENT:-}" && -d "$RC_LIVE_PARENT/$folder" ]]; then
            rm -rf "$RC_LIVE_PARENT/$folder" && rc_log "Live folder removed: $folder"
        elif [[ "$kind" == runs && -d "$RC_BASE/runs/$folder/live" ]]; then
            print -r -- "${RC_RUN:t}" > "$RC_BASE/runs/$folder/live/taken-over" && rc_log "Earlier run’s objects all removed: $folder"
        fi
    done
    [[ -n "${RC_LIVE_PARENT:-}" && -d "$RC_LIVE_DIR" ]] && rc_log "Live folder kept, objects still to remove: ${RC_LIVE_DIR:t}"
    return 0
}

# MARK: Cleanup and report

rc_cleanup() {
    (( ${RC_READY:-0} )) || return 0
    (( RC_CLEANED )) && return 0
    RC_CLEANED=1
    setopt local_options no_err_exit
    if (( RC_LIVE_STARTED )); then
        rc_log "Cleanup: removing this run’s test objects"
        rc_live_environment 1
        if rc_test "$CLEANUP_TEST" --once --cleanup-line; then
            RC_CLEANUP_STATUS="passed"
        else
            RC_CLEANUP_STATUS="FAILED (see logs/${CLEANUP_TEST//\//-}.*.log)"
        fi
    fi
    rc_live_off
    rc_forget_credentials
    if [[ -n "${HOST_KEYCHAIN_TEST:-}" ]] && (( ${RC_BUILT:-0} )); then
        rc_live_environment 0
        export TEST_RUNNER_JTKIT_LIVE_HOST_KEYCHAIN=after
        rc_test "$HOST_KEYCHAIN_TEST" --label after || rc_check_failed "the test host’s Keychain names after the run (logs/${HOST_KEYCHAIN_TEST//\//-}.after.*.log)"
        unset TEST_RUNNER_JTKIT_LIVE_HOST_KEYCHAIN
        rc_live_off
    fi
    [[ -n "${RC_CAFFEINATE:-}" ]] && kill "$RC_CAFFEINATE" 2>/dev/null
    rc_live_sync
    rc_live_finish
    rc_fingerprint "$RC_RUN/fingerprint.after"
    rc_report
    rc_unlock
}

rc_report() {
    local result="passed"
    [[ -n "${RC_FAILED:-}" ]] && result="FAILED: $RC_FAILED"
    if [[ ! -f "$RC_RUN/fingerprint.before" ]]; then
        # Stopped before the first fingerprint (e.g. another check held the lock).
        [[ "$result" == passed ]] && result="FAILED: the fingerprint before the run wasn’t taken"
    elif [[ "$(cat "$RC_RUN/fingerprint.before")" != "$(cat "$RC_RUN/fingerprint.after" 2>/dev/null)" ]]; then
        result="FAILED: saved connections or Keychain item names changed"
    fi
    if [[ "${RC_CLEANUP_STATUS:-}" == FAILED* ]]; then
        # The cleanup test can fail on a check of its own after removing
        # everything (an app’s last "nothing attempted under tests" step):
        # then the report names that check, not the cleanup.
        local after_cleanup
        after_cleanup="$("$RC_PY" -c '
import json, os, sys
live = sys.argv[1]
try:
    steps = [json.loads(l) for l in open(os.path.join(live, "results.jsonl")) if l.strip()]
except FileNotFoundError:
    sys.exit(0)
path = os.path.join(live, "ledger.json")
ledger = json.load(open(path)) if os.path.exists(path) else []
last = max((i for i, s in enumerate(steps) if s.get("step") == "cleanup"), default=None)
if last is None or not steps[last].get("passed") or any(not i.get("removed") for i in ledger):
    sys.exit(0)
print("; ".join(dict.fromkeys(s["step"] for s in steps[last + 1:] if not s.get("passed"))))
' "$RC_RUN/live")" || rc_check_failed "reading the cleanup’s results"
        if [[ -n "$after_cleanup" ]]; then
            RC_CLEANUP_STATUS="passed (every test object removed); the cleanup test then failed on: $after_cleanup"
            [[ "$result" == passed ]] && result="FAILED: $after_cleanup"
        else
            result="FAILED: cleanup"
        fi
    fi
    [[ "${RC_ALLOWLIST_COPY:-}" == FAILED* ]] && result="$RC_ALLOWLIST_COPY"
    # Anything a read-back still finds fails the run, by name: a
    # delete’s own answer never counts as removed.
    local not_removed
    not_removed="$("$RC_PY" -c '
import json, sys
try: items = json.load(open(sys.argv[1]))
except FileNotFoundError: items = []
left = [i for i in items if not i.get("removed")]
print("; ".join("%s %s “%s”" % (i.get("resource", ""), i.get("id", ""), i.get("name", "")) for i in left))
' "$RC_RUN/live/ledger.json")" || rc_check_failed "the ledger’s not-removed objects"
    [[ -n "$not_removed" ]] && result="FAILED: not removed (a read-back still finds them): $not_removed"
    # A create the ledger doesn’t hold may still be on the tenant: it fails the run, by name.
    local unrecorded
    unrecorded="$("$RC_PY" -c '
import json, sys
try: lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except FileNotFoundError: lines = []
print("; ".join("%s “%s” (%s)" % (c.get("resource", ""), c.get("name", ""), c.get("reason", "")) for c in lines))
' "$RC_RUN/live/unrecorded-creates.jsonl")" || rc_check_failed "the creates the ledger doesn’t hold"
    [[ -n "$unrecorded" ]] && result="FAILED: created but not in the ledger: $unrecorded"
    # The test host’s Keychain names: both taken, and equal.
    RC_HOST_KEYCHAIN=""
    if [[ -n "${HOST_KEYCHAIN_TEST:-}" ]] && (( ${RC_BUILT:-0} )); then
        local hb="$RC_RUN/live/host-keychain.before" ha="$RC_RUN/live/host-keychain.after"
        if [[ ! -f "$hb" || ! -f "$ha" ]]; then
            RC_HOST_KEYCHAIN="FAILED: not taken both before and after"
        else
            local hbh hah
            hbh="$(shasum -a 256 < "$hb" | cut -c1-16)" && hah="$(shasum -a 256 < "$ha" | cut -c1-16)" \
                || rc_check_failed "comparing the test host’s Keychain names"
            if [[ -n "$hbh" && "$hbh" == "$hah" ]]; then
                RC_HOST_KEYCHAIN="unchanged ($(grep -c . "$hb") items, $hbh)"
            else
                RC_HOST_KEYCHAIN="CHANGED (before $hbh, after $hah)"
            fi
        fi
        [[ "$RC_HOST_KEYCHAIN" != unchanged* && "$result" == passed ]] && result="FAILED: the test host’s Keychain item names: $RC_HOST_KEYCHAIN"
    fi
    # A check that couldn’t run fails the run, named.
    if (( ${#RC_CHECK_ERRORS} )); then
        local checks="a check couldn’t run: ${(j:; :)RC_CHECK_ERRORS}"
        if [[ "$result" == passed ]]; then result="FAILED: $checks"; else result="$result; $checks"; fi
    fi
    if [[ -n "$RC_FAULT" && "$result" == "passed" ]]; then
        result="FAILED: the injected fault ($RC_FAULT) didn’t stop the check"
    fi
    RC_LIVE_IN_CONTAINER="${TEST_HOST_CONTAINER:-}" RC_ALLOWLIST_COPY="${RC_ALLOWLIST_COPY:-}" \
    RC_READ_ONLY_ROLES="${(j:, :)READ_ONLY_ROLES}" RC_HOST_KEYCHAIN="${RC_HOST_KEYCHAIN:-}" \
    RC_CHECK_ERRORS_TEXT="${(j:|:)RC_CHECK_ERRORS}" \
    "$RC_PY" - "$RC_RUN" "$APP_NAME" "$result" "$RC_KIND" "$RC_JTKIT" "${RC_CLEANUP_STATUS:-not needed}" \
        "${(j:|:)RC_STAGE_NAMES}" "${(j:|:)RC_STAGE_STATUS}" <<'EOF'
import json, os, sys
run, app, status, kind, jtkit, cleanup, names, statuses = sys.argv[1:9]
# A file that isn’t there is "none"; one that can’t be read fails the report.
def load(path, default):
    try:
        with open(os.path.join(run, path)) as f: return json.load(f)
    except FileNotFoundError: return default
def lines_of(path):
    try:
        with open(os.path.join(run, path)) as f: return [json.loads(l) for l in f if l.strip()]
    except FileNotFoundError: return []
results = lines_of("live/results.jsonl")
ledger = load("live/ledger.json", [])
# Each test process appends its refusals to refusals.jsonl as they happen.
refusals = lines_of("live/refusals.jsonl")
before = open(os.path.join(run, "fingerprint.before")).read().strip() if os.path.exists(os.path.join(run, "fingerprint.before")) else "?"
after = open(os.path.join(run, "fingerprint.after")).read().strip() if os.path.exists(os.path.join(run, "fingerprint.after")) else "?"
lines = [f"# Release check: {app}", "", f"- Result: **{status}**", f"- Kind: {kind}", f"- JTKit: {jtkit}", ""]
lines += ["## Stages", "", "| Stage | Status |", "|---|---|"]
for n, s in zip(names.split("|") if names else [], statuses.split("|") if statuses else []):
    lines.append(f"| {n} | {s} |")
lines += ["", "## Live steps", ""]
if results:
    lines += ["| Step | Result | Note |", "|---|---|---|"]
    for r in results:
        lines.append(f"| {r['step']} | {'passed' if r['passed'] else 'FAILED'} | {r.get('note') or ''} |")
else:
    lines.append("None ran.")
created = [i for i in ledger if not i.get("fromSweep")]
swept = [i for i in ledger if i.get("fromSweep")]
left = [i for i in ledger if not i.get("removed")]
lines += ["", "## Test objects", "",
          f"- Created by this run: {len(created)}, removed: {sum(1 for i in created if i.get('removed'))}",
          f"- Left-overs found by the sweep: {len(swept)}, removed: {sum(1 for i in swept if i.get('removed'))}",
          f"- Cleanup: {cleanup}"]
earlier = load("earlier-ledgers.json", [])
if earlier:
    keys = {(i["target"], i["resource"], i["id"]) for i in ledger if i.get("removed")}
    items = [tuple(k) for e in earlier for k in e["items"]]
    lines.append(f"- From earlier runs' live folders ({len(earlier)}): {len(items)} objects, removed: {sum(1 for k in items if k in keys)}")
if os.environ.get("RC_LIVE_IN_CONTAINER"):
    lines.append(f"- Live folder in the app’s container (readable by you only); allow-list copy: {os.environ.get('RC_ALLOWLIST_COPY') or 'not checked'}")
for i in left:
    lines.append(f"- **Not removed:** {i['resource']} {i['id']} “{i['name']}”")
for c in lines_of("live/unrecorded-creates.jsonl"):
    lines.append(f"- **Created but not in the ledger:** {c.get('resource', '')} “{c.get('name', '')}” ({c.get('reason', '')})")
# Every delete is confirmed by a read-back.
deletes = lines_of("live/deletes.jsonl")
if deletes:
    confirmed = sum(1 for d in deletes if d.get("confirmed"))
    fallback = sum(1 for d in deletes if d.get("throughJamfPro"))
    lines.append(f"- Deletes confirmed by a read-back: {confirmed} of {len(deletes)}"
                 + (f"; {fallback} Platform group(s) deleted again through the Jamf Pro API" if fallback else ""))
    for d in deletes:
        if not d.get("confirmed"):
            lines.append(f"- **Delete not confirmed** (answered {d['status']}): {d['resource']} {d['id']} “{d.get('name', '')}”")
if os.environ.get("RC_READ_ONLY_ROLES"):
    lines.append(f"- Kept read only for this app: {os.environ['RC_READ_ONLY_ROLES']}")
# Apple requests per organization: role and time only.
apple = {}
for entry in lines_of("live/apple-requests.jsonl"):
    apple[entry["role"]] = apple.get(entry["role"], 0) + 1
if apple:
    lines += ["", "## Apple requests (paced to 9 a minute, at most 40 a run per organization)", ""]
    lines += [f"- {role}: {count}" for role, count in sorted(apple.items())]
checks = [c for c in os.environ.get("RC_CHECK_ERRORS_TEXT", "").split("|") if c]
if checks:
    lines += ["", f"## Checks that couldn’t run ({len(checks)})", ""]
    lines += [f"- **{c}**" for c in checks]
lines += ["", f"## Refused requests ({len(refusals)})", ""]
lines += [f"- {r['method']} {r['location']}: {r['reason']}" for r in refusals] or ["None."]
lines += ["", "## Saved connections and Keychain item names", "",
          f"- Fingerprint before: {before}", f"- Fingerprint after: {after}",
          "- " + ("Unchanged." if before == after else "**CHANGED** (compare fingerprint.before.names and fingerprint.after.names)")]
if os.environ.get("RC_HOST_KEYCHAIN"):
    lines.append(f"- Keychain item names seen by the test host (hashes only): {os.environ['RC_HOST_KEYCHAIN']}")
open(os.path.join(run, "report.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
EOF
    if (( $? )); then
        # The report itself couldn’t be written: a short one says so, FAILED.
        print -r -- "# Release check: $APP_NAME

- Result: **FAILED: the report couldn’t be written (see run.log); $result**" | tee "$RC_RUN/report.md"
        rc_log "CHECK FAILED: writing the report"
    fi
}

# MARK: Main

release_check_main() {
    RC_LOCAL=0 RC_ALL_TENANTS=0 RC_PRODUCTION=0 RC_STOP_BEFORE_LIVE=0 RC_FAULT=""
    # A fault is only ever on when --fault names it on this command line.
    unset JTKIT_LIVE_FAULT TEST_RUNNER_JTKIT_LIVE_FAULT
    while (( $# )); do
        case "$1" in
            --local-jtkit) RC_LOCAL=1 ;;
            --tenants) RC_ALL_TENANTS=1 ;;
            --include-production) RC_PRODUCTION=1 ;;
            --stop-before-live) RC_STOP_BEFORE_LIVE=1 ;;
            --fault)
                shift
                if [[ "${1:-}" == (break-build|fail-live-step|interrupt-live) ]] || (( ${APP_FAULTS[(Ie)${1:-}]} )); then
                    RC_FAULT="$1"
                else
                    print -u2 "--fault needs one of: break-build fail-live-step interrupt-live ${APP_FAULTS[*]}"; return 2
                fi ;;
            *) print -u2 "Unknown option $1"; return 2 ;;
        esac
        shift
    done
    RC_LIB_DIR="${${(%):-%x}:A:h}"
    RC_PREFIX="$(print "JTKTEST $APP_CODE $(date +%m%d-%H%M)")"
    RC_RUN="$RC_BASE/runs/$APP_CODE-$(date +%Y%m%d-%H%M%S)"
    # Xcode’s own build folder: the sandboxed UI test runner can’t attach
    # to an app built under Application Support.
    RC_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE"
    RC_PACKAGES="$RC_DERIVED/SourcePackages"
    RC_WORKSPACE="${JTKIT_WORKSPACE:-$HOME/Developer/Apps.xcworkspace}"
    RC_ROLES=("${ROLES[@]}")
    RC_STAGE_NAMES=() RC_STAGE_STATUS=() RC_SECRET_VARS=() RC_CLEANED=0 RC_LIVE_STARTED=0 RC_FAILED="" RC_BUILT=0 RC_CHECK_ERRORS=()
    # Set here too, not only in rc_live_setup: a run that stops before it
    # must never clean up a folder named by an inherited RC_LIVE_PARENT.
    RC_LIVE_DIR="$RC_RUN/live" RC_LIVE_ALLOWLIST="$RC_ALLOWLIST" RC_LIVE_PARENT="" RC_ALLOWLIST_COPY=""
    # The tests’ JTKitUITestCase and LiveCheckRun see the release check.
    export TEST_RUNNER_JTKIT_RELEASE_CHECK=1
    mkdir -p "$RC_RUN/logs" "$RC_RUN/results" "$RC_RUN/live" && chmod 700 "$RC_BASE" "$RC_RUN"
    RC_READY=1 RC_LOCKED=0
    rc_lock

    if (( RC_LOCAL )); then
        RC_KIND="pre-release (local JTKit in Apps.xcworkspace, not the published version)"
        RC_JTKIT="local $(rc_jtkit_version --dirty)"
    else
        RC_KIND="release (the app’s own project, published JTKit)"
        RC_JTKIT="$(rc_jtkit_version)"
    fi
    [[ -n "$RC_FAULT" ]] && RC_KIND="FAULT TEST (--fault $RC_FAULT), not a release check; $RC_KIND"
    rc_log "Release check for $APP_NAME, $RC_KIND"
    rc_log "Run folder: $RC_RUN"
    rc_xcodebuild_base

    # Stage 1: build and sign in
    rc_check_allowlist
    if (( RC_ALL_TENANTS )); then
        local all_roles
        all_roles="$("$RC_PY" -c 'import json,sys; print(" ".join(sorted({t["role"] for t in json.load(open(sys.argv[1]))["tenants"] if sys.argv[2]=="1" or not t.get("production")})))' "$RC_ALLOWLIST" "$RC_PRODUCTION")" \
            || rc_fail "Check failed: reading the roles from the allow-list"
        RC_ROLES=(${=all_roles})
    elif (( ! RC_PRODUCTION )); then
        # The app’s production roles take part only with --include-production.
        local kept_roles
        kept_roles="$("$RC_PY" -c 'import json,sys; prod={t["role"] for t in json.load(open(sys.argv[1]))["tenants"] if t.get("production")}; print(" ".join(r for r in sys.argv[2:] if r not in prod))' "$RC_ALLOWLIST" "${ROLES[@]}")" \
            || rc_fail "Check failed: reading the production roles from the allow-list"
        RC_ROLES=(${=kept_roles})
        local left_out=() role
        for role in "${ROLES[@]}"; do (( ${RC_ROLES[(Ie)$role]} )) || left_out+=("$role"); done
        (( ${#left_out} )) && rc_log "Left out (production, no --include-production): ${(j:, :)left_out}"
    fi
    rc_live_setup
    rc_fingerprint "$RC_RUN/fingerprint.before"
    rc_log "Building for testing ($SCHEME)"
    local build_settings=()
    # The test target holds `#if JTKIT_FAULT_BREAK_BUILD #error`; only this fault sets it.
    [[ "$RC_FAULT" == break-build ]] && build_settings=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) JTKIT_FAULT_BREAK_BUILD')
    if ! "${RC_XB[@]}" build-for-testing "${build_settings[@]}" > "$RC_RUN/logs/build.log" 2>&1; then
        rc_stage "1 build" "FAILED"
        grep -E "error:" "$RC_RUN/logs/build.log" | head -20 | tee -a "$RC_RUN/run.log"
        rc_fail "The build failed (logs/build.log)"
    fi
    RC_BUILT=1
    if [[ -n "${HOST_KEYCHAIN_TEST:-}" ]]; then
        rc_live_environment 0
        export TEST_RUNNER_JTKIT_LIVE_HOST_KEYCHAIN=before
        rc_test "$HOST_KEYCHAIN_TEST" --label before || { rc_stage "1 build and sign in" "FAILED"; rc_fail "The test host’s Keychain names couldn’t be taken (logs/${HOST_KEYCHAIN_TEST//\//-}.before.*.log)"; }
        unset TEST_RUNNER_JTKIT_LIVE_HOST_KEYCHAIN
        rc_live_off
    fi
    rc_read_credentials
    rc_live_environment 0
    if ! rc_test "$SIGNIN_TEST"; then
        rc_stage "1 build and sign in" "FAILED"
        rc_fail "Sign-in failed (logs/${SIGNIN_TEST//\//-}.*.log)"
    fi
    rc_live_off
    # Stages 2 and 3 need no credentials: they’re read again for stage 4.
    rc_forget_credentials
    rc_stage "1 build and sign in" "passed (${(j:, :)RC_ROLES})"

    # Stage 2: unit tests (live checks skip themselves: JTKIT_LIVE isn’t set)
    if ! rc_test "$UNIT_TESTS" --allow-skips; then
        rc_stage "2 unit tests" "FAILED"
        rc_fail "Unit tests failed (logs/${UNIT_TESTS//\//-}.*.log)"
    fi
    rc_stage "2 unit tests" "passed"

    # Stage 3: UI smoke tests in demo mode, one test at a time
    caffeinate -dimsu & RC_CAFFEINATE=$!
    local test failed=() smoke=()
    [[ -f "$SMOKE_FILE" ]] && smoke=($(rc_tests_in "$SMOKE_FILE"))
    if (( ! ${#smoke} )); then
        rc_stage "3 UI smoke tests" "FAILED: no smoke tests in $SMOKE_FILE"
        rc_fail "No smoke tests found in $SMOKE_FILE"
    fi
    for test in "${smoke[@]}"; do
        rc_log "  smoke: $test"
        rc_test "$UI_TESTS/$SMOKE_CLASS/$test" || failed+=("$test")
    done
    if (( ${#failed} )); then
        rc_stage "3 UI smoke tests" "FAILED: ${(j:, :)failed}"
        rc_fail "Smoke tests failed: ${(j:, :)failed}"
    fi
    rc_stage "3 UI smoke tests" "passed"

    # Stage 4: live checks
    if (( RC_STOP_BEFORE_LIVE )); then
        rc_stage "4 live checks" "not run (--stop-before-live)"
        return 0
    fi
    rc_read_credentials
    RC_LIVE_STARTED=1
    rc_live_environment 1
    if [[ "$RC_FAULT" == interrupt-live ]]; then
        rc_interrupt_live "${LIVE_TESTS[1]}"
    fi
    for test in "${LIVE_TESTS[@]}"; do
        rc_log "  live: $test"
        if ! rc_test "$test" --once --results-line; then
            rc_stage "4 live checks" "FAILED: $test"
            rc_fail "Live check failed: $test"
        fi
    done
    rc_stage "4 live checks" "passed"
    return 0
}

# zsh runs an EXIT trap set inside a function when that function returns, so
# the traps are set here, at the script’s top level, when it’s loaded.
RC_READY=0
trap rc_cleanup EXIT
trap 'RC_FAILED="interrupted"; rc_cleanup; exit 130' INT TERM
