#!/bin/zsh
# JTKit release check (ROADMAP step 11), loaded by each app's
# Scripts/release-check.sh from the JTKit version the app resolved, so the
# script matches the JTKit under test.
#
# The app's script sets, then calls `release_check_main "$@"`:
#   APP_NAME APP_CODE PROJECT SCHEME UNIT_TESTS UI_TESTS SMOKE_CLASS
#   SIGNIN_TEST CLEANUP_TEST LIVE_TESTS=(…) ROLES=(…)
#   CREDENTIALS=("role:service:item" …)   read from the Keychain the allow-list names
#   LEGACY_PREFIXES="UIT - |…"           swept once, on the first live run
#   FINGERPRINT_PATHS=(…) KEYCHAIN_PREFIXES=(…)
#   FINGERPRINT_DEFAULTS=("<domain> <key>" …)   optional (0.12.1): single
#     UserDefaults values, for apps whose connections share a preferences file
#     with window frames and other state macOS changes during a UI test
#   TEST_HOST_CONTAINER="<bundle ID>"   optional (0.12.2), for a sandboxed app:
#     its test host can only reach its own container, so the live folder (the
#     allow-list copy, ledger and results) lives there, readable by you only
#   SMOKE_FILE="<path of the smoke-test class's file>"   its test1…testN run in order
#   APP_FAULTS=(…)   optional (0.12.3): the app's own --fault cases, handled by
#     its tests through JTKIT_LIVE_FAULT; the report says FAULT TEST as for the others
#
# Production roles in ROLES (marked production on the allow-list) take part
# only with --include-production (0.12.3): otherwise they are left out, and
# their CREDENTIALS aren't read.
#
# One release check per Mac at a time (0.12.2): a lock in state/ beside the
# allow-list; a second check stops before it reads or changes anything.
#
# Stages, stopping at the first failure (cleanup and the report run either way):
#   1 build from the app's own project and sign in to its allow-listed tenants
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
# Without --fault no fault can be on: inherited fault variables are cleared.
#
# Secrets: read from the login Keychain into TEST_RUNNER_* variables only,
# never echoed, never written to a file; xcodebuild's output goes to logs in
# the run folder, which never contain them (tests paste, never print).

setopt pipe_fail

RC_BASE="$HOME/Library/Application Support/JTKit Release Check"
RC_ALLOWLIST="${JTKIT_ALLOWLIST:-$RC_BASE/allowlist.json}"
RC_PY=/usr/bin/python3
RC_RETRY_PATTERN='Test Case .*(passed|failed|skipped)|Test .* (passed|failed|skipped)|Test run with .* (passed|failed)|with [0-9]+ failures?'

rc_log() { print -r -- "[$(date +%H:%M:%S)] $*" | tee -a "$RC_RUN/run.log" }
rc_stage() { RC_STAGE_NAMES+=("$1"); RC_STAGE_STATUS+=("$2"); rc_log "Stage $1: $2" }
rc_fail() { rc_log "FAILED: $*"; RC_FAILED="$*"; exit 1 }

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
    "$RC_PY" - "$RC_ALLOWLIST" "${ROLES[@]}" <<'EOF' || rc_fail "The app's roles aren't all on the allow-list"
import json, sys
tenants = json.load(open(sys.argv[1]))["tenants"]
known = {t["role"] for t in tenants}
missing = [r for r in sys.argv[2:] if r not in known]
if missing:
    print("Not on the allow-list: " + ", ".join(missing)); sys.exit(1)
EOF
}

# The Keychain service the allow-list names for a role's service.
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
        kc="$(rc_keychain_service "$role" "$service")"
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

# MARK: Fingerprint (no secrets read)

rc_fingerprint() {
    local out="$1" item
    : > "$out.names"
    for item in "${FINGERPRINT_PATHS[@]}"; do
        if [[ -d "$item" ]]; then
            print -r -- "dir $item $(cd "$item" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | cut -c1-16)" >> "$out.names"
        elif [[ -f "$item" ]]; then
            print -r -- "file $item $(shasum -a 256 < "$item" | cut -c1-16)" >> "$out.names"
        else
            print -r -- "absent $item" >> "$out.names"
        fi
    done
    # Single settings: only a hash of each value is kept, never the value.
    local pair domain key value
    for pair in "${FINGERPRINT_DEFAULTS[@]}"; do
        domain="${pair%% *}"; key="${pair#* }"
        if value="$(/usr/bin/defaults read "$domain" "$key" 2>/dev/null)"; then
            print -r -- "defaults $domain $key $(print -rn -- "$value" | shasum -a 256 | cut -c1-16)" >> "$out.names"
        else
            print -r -- "defaults $domain $key absent" >> "$out.names"
        fi
    done
    unset value
    # Keychain item names only: service and account attributes, never data.
    local prefix
    for prefix in "${KEYCHAIN_PREFIXES[@]}"; do
        security dump-keychain "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | "$RC_PY" -c '
import sys, re
prefix = sys.argv[1]; acct = None; items = []
for line in sys.stdin:
    if line.startswith("keychain:"): acct = None
    m = re.search(r"\"acct\"<blob>=\"(.*)\"", line)
    if m: acct = m.group(1)
    m = re.search(r"\"svce\"<blob>=\"(.*)\"", line)
    if m and m.group(1).startswith(prefix): items.append(m.group(1) + " / " + (acct or ""))
for i in sorted(set(items)): print("keychain " + i)
' "$prefix" >> "$out.names"
    done
    shasum -a 256 < "$out.names" | cut -c1-16 > "$out"
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

# Runs one -only-testing selection, retried once when no result came back.
rc_test() {
    local selection="$1" name="${1//\//-}" log attempt
    for attempt in 1 2; do
        log="$RC_RUN/logs/$name.$attempt.log"
        "${RC_XB[@]}" test-without-building -only-testing:"$selection" -resultBundlePath "$RC_RUN/results/$name.$attempt.xcresult" > "$log" 2>&1
        local code=$?
        if grep -qE "$RC_RETRY_PATTERN" "$log"; then
            return $code
        fi
        rc_log "  no result from $selection (attempt $attempt)"
        sleep 5
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
    export TEST_RUNNER_JTKIT_LIVE_ALLOWLIST="$RC_LIVE_ALLOWLIST"
    (( RC_PRODUCTION )) && export TEST_RUNNER_JTKIT_LIVE_INCLUDE_PRODUCTION=1
    if [[ -n "$RC_FAULT" ]]; then export TEST_RUNNER_JTKIT_LIVE_FAULT="$RC_FAULT"; else unset TEST_RUNNER_JTKIT_LIVE_FAULT; fi
    # Writes (and so the sweep) only in stage 4; earlier stages read.
    export TEST_RUNNER_JTKIT_LIVE_WRITES="${1:-0}"
    if [[ ! -e "$RC_BASE/state/$APP_CODE.legacy-swept" ]]; then
        export TEST_RUNNER_JTKIT_LIVE_LEGACY_PREFIXES="$LEGACY_PREFIXES"
    else
        unset TEST_RUNNER_JTKIT_LIVE_LEGACY_PREFIXES
    fi
}

rc_live_off() {
    unset TEST_RUNNER_JTKIT_LIVE TEST_RUNNER_JTKIT_LIVE_RUN_DIR TEST_RUNNER_JTKIT_LIVE_PREFIX TEST_RUNNER_JTKIT_LIVE_ROLES \
          TEST_RUNNER_JTKIT_LIVE_ALLOWLIST TEST_RUNNER_JTKIT_LIVE_INCLUDE_PRODUCTION TEST_RUNNER_JTKIT_LIVE_WRITES \
          TEST_RUNNER_JTKIT_LIVE_LEGACY_PREFIXES TEST_RUNNER_JTKIT_LIVE_FAULT
}

# --fault interrupt-live: runs the first live test, and once the ledger holds
# objects kills it and everything it started (as a crash or power cut would),
# then ends the run without cleanup. The next run's stage 1 counts the
# leftovers and its stage 4 sweep removes them.
rc_interrupt_live() {
    local selection="$1" name="${1//\//-}"
    rc_log "  live (to be interrupted): $selection"
    "${RC_XB[@]}" test-without-building -only-testing:"$selection" > "$RC_RUN/logs/$name.interrupted.log" 2>&1 &
    local xb=$! waited=0
    while (( waited < 900 )); do
        local count=$("$RC_PY" -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))))
except Exception: print(0)' "$RC_LIVE_DIR/ledger.json")
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

# MARK: One release check per Mac (0.12.2)

# Every release check sweeps its tenants for JTKTEST objects and adopts an
# earlier run's live folder, so two at once (of any apps) could remove each
# other's objects. The lock beside the allow-list holds the running check's
# process ID; a lock whose process has ended is stale and taken over.
RC_LOCK="$RC_BASE/state/release-check.lock"
rc_lock() {
    mkdir -p "$RC_BASE/state" && chmod 700 "$RC_BASE/state"
    local attempt holder
    for attempt in 1 2; do
        if ( set -o noclobber; print -r -- "$$ $APP_NAME" > "$RC_LOCK" ) 2>/dev/null; then
            RC_LOCKED=1
            return 0
        fi
        holder="$(cat "$RC_LOCK" 2>/dev/null)"
        if [[ -n "$holder" ]] && kill -0 "${holder%% *}" 2>/dev/null; then
            rc_fail "Another release check is running on this Mac (${holder#* }, process ${holder%% *}); one at a time"
        fi
        rc_log "Removing a stale lock (${holder:-empty})"
        rm -f "$RC_LOCK"
    done
    rc_fail "Can't take the release-check lock at $RC_LOCK"
}

rc_unlock() {
    (( ${RC_LOCKED:-0} )) || return 0
    [[ "$(cat "$RC_LOCK" 2>/dev/null)" == "$$ $APP_NAME" ]] && rm -f "$RC_LOCK"
    RC_LOCKED=0
}

# MARK: Live folder (0.12.2)

# Where the test host reads the allow-list and writes the ledger and results:
# $RC_RUN/live, or for a sandboxed test host (TEST_HOST_CONTAINER) a folder of
# this run's in the app's container, readable by you only, with a copy of the
# allow-list. What the tests write there is copied back to $RC_RUN/live for
# the report. A folder an earlier run left (it crashed, or its cleanup didn't
# finish) is kept until this run has read its ledger and removed its objects.
rc_live_setup() {
    RC_LIVE_DIR="$RC_RUN/live" RC_LIVE_ALLOWLIST="$RC_ALLOWLIST" RC_LIVE_PARENT=""
    [[ -n "${TEST_HOST_CONTAINER:-}" ]] || return 0
    local data="$HOME/Library/Containers/$TEST_HOST_CONTAINER/Data"
    [[ -d "$data/tmp" ]] || rc_fail "No container for $TEST_HOST_CONTAINER at $data (open the app once)"
    RC_LIVE_PARENT="$data/tmp/JTKitReleaseCheck"
    mkdir -p "$RC_LIVE_PARENT" && chmod 700 "$RC_LIVE_PARENT" || rc_fail "Can't make $RC_LIVE_PARENT"
    RC_LIVE_DIR="$RC_LIVE_PARENT/${RC_RUN:t}"
    mkdir -m 700 "$RC_LIVE_DIR" || rc_fail "Can't make the live folder $RC_LIVE_DIR"
    local mode
    for dir in "$RC_LIVE_PARENT" "$RC_LIVE_DIR"; do
        mode=$(stat -f %Lp "$dir")
        [[ "$mode" == 700 && "$(stat -f %u "$dir")" == "$(id -u)" ]] || rc_fail "$dir must be yours and readable by you only (700); it is $mode"
    done
    RC_LIVE_ALLOWLIST="$RC_LIVE_DIR/allowlist.json"
    ( umask 077; cp "$RC_ALLOWLIST" "$RC_LIVE_ALLOWLIST" ) && chmod 600 "$RC_LIVE_ALLOWLIST" || rc_fail "Can't copy the allow-list"
    RC_ALLOWLIST_HASH="$(shasum -a 256 < "$RC_ALLOWLIST" | cut -d' ' -f1)"
    [[ "$(shasum -a 256 < "$RC_LIVE_ALLOWLIST" | cut -d' ' -f1)" == "$RC_ALLOWLIST_HASH" ]] || rc_fail "The allow-list copy differs from the allow-list"
    rc_log "Live folder (in the app's container, 700): ${RC_LIVE_DIR:t}"
    # Earlier runs' outstanding objects join this run's ledger, so this run's
    # cleanup removes them; their folders are listed for rc_live_finish.
    "$RC_PY" - "$RC_LIVE_PARENT" "$RC_LIVE_DIR" "$RC_RUN/earlier-ledgers.json" <<'EOF' || rc_fail "An earlier run's ledger can't be used (see run.log)"
import json, os, sys
parent, current, out = sys.argv[1:4]
ledger_path = os.path.join(current, "ledger.json")
merged, earlier = [], []
key = lambda i: (i["target"], i["resource"], i["id"])
for name in sorted(os.listdir(parent)):
    folder = os.path.join(parent, name)
    if folder == current or not os.path.isdir(folder): continue
    try:
        with open(os.path.join(folder, "ledger.json")) as f: items = json.load(f)
    except FileNotFoundError: items = []
    except Exception as error:
        print(f"Unreadable ledger in {name}: {error}"); sys.exit(1)
    left = [i for i in items if not i.get("removed")]
    for i in left:
        if not i.get("name", "").startswith("JTKTEST "):
            print(f"{name}'s ledger lists “{i.get('name')}”, which isn't named as a test object"); sys.exit(1)
    earlier.append({"folder": name, "items": [list(key(i)) for i in left]})
    for i in left:
        if key(i) not in {key(m) for m in merged}:
            merged.append(dict(i, removed=False, fromSweep=True))
    print(f"Earlier live folder {name}: {len(left)} objects still to remove")
if merged:
    with open(ledger_path, "w") as f: json.dump(merged, f, indent=2, sort_keys=True)
with open(out, "w") as f: json.dump(earlier, f, indent=2)
EOF
}

# Copies what the tests wrote into the run folder (sandboxed test hosts only).
rc_live_sync() {
    [[ -n "${RC_LIVE_PARENT:-}" && -d "$RC_LIVE_DIR" ]] || return 0
    local file
    for file in ledger.json results.jsonl refusals.jsonl; do
        [[ -f "$RC_LIVE_DIR/$file" ]] && cp "$RC_LIVE_DIR/$file" "$RC_RUN/live/$file"
    done
    return 0
}

# Checks the allow-list copy, then removes the live folders whose objects are
# all gone: this run's, and each earlier one whose objects this run removed.
rc_live_finish() {
    [[ -n "${RC_LIVE_PARENT:-}" ]] || return 0
    if [[ ! -f "$RC_LIVE_ALLOWLIST" ]]; then
        RC_ALLOWLIST_COPY="FAILED: the allow-list copy is missing"
    elif [[ "$(shasum -a 256 < "$RC_LIVE_ALLOWLIST" | cut -d' ' -f1)" != "$RC_ALLOWLIST_HASH" ]]; then
        RC_ALLOWLIST_COPY="FAILED: the allow-list copy changed during the run"
    else
        RC_ALLOWLIST_COPY="unchanged"
    fi
    local folder
    for folder in $("$RC_PY" - "$RC_LIVE_DIR" "$RC_RUN/earlier-ledgers.json" <<'EOF'
import json, os, sys
current, earlier_path = sys.argv[1:3]
try:
    with open(os.path.join(current, "ledger.json")) as f: items = json.load(f)
except Exception: items = []
removed = {(i["target"], i["resource"], i["id"]) for i in items if i.get("removed")}
if all(i.get("removed") for i in items): print(os.path.basename(current))
try:
    with open(earlier_path) as f: earlier = json.load(f)
except Exception: earlier = []
for e in earlier:
    if all(tuple(k) in removed for k in e["items"]): print(e["folder"])
EOF
    ); do
        [[ -n "$folder" && "$folder" != */* && "$folder" != .* && -d "$RC_LIVE_PARENT/$folder" ]] || continue
        rm -rf "$RC_LIVE_PARENT/$folder" && rc_log "Live folder removed: $folder"
    done
    [[ -d "$RC_LIVE_DIR" ]] && rc_log "Live folder kept, objects still to remove: ${RC_LIVE_DIR:t}"
    return 0
}

# MARK: Cleanup and report

rc_cleanup() {
    (( ${RC_READY:-0} )) || return 0
    (( RC_CLEANED )) && return 0
    RC_CLEANED=1
    setopt local_options no_err_exit
    if (( RC_LIVE_STARTED )); then
        rc_log "Cleanup: removing this run's test objects"
        rc_live_environment 1
        if rc_test "$CLEANUP_TEST"; then
            RC_CLEANUP_STATUS="passed"
            mkdir -p "$RC_BASE/state" && touch "$RC_BASE/state/$APP_CODE.legacy-swept"
        else
            RC_CLEANUP_STATUS="FAILED (see logs/${CLEANUP_TEST//\//-}.*.log)"
        fi
    fi
    rc_live_off
    rc_forget_credentials
    [[ -n "${RC_CAFFEINATE:-}" ]] && kill "$RC_CAFFEINATE" 2>/dev/null
    rc_live_sync
    rc_live_finish
    rc_fingerprint "$RC_RUN/fingerprint.after"
    rc_report
    rm -rf "$RC_WORK"
    rc_unlock
}

rc_report() {
    local result="passed"
    [[ -n "${RC_FAILED:-}" ]] && result="FAILED: $RC_FAILED"
    [[ "$(cat "$RC_RUN/fingerprint.before" 2>/dev/null)" != "$(cat "$RC_RUN/fingerprint.after" 2>/dev/null)" ]] && result="FAILED: saved connections or Keychain item names changed"
    if [[ "${RC_CLEANUP_STATUS:-}" == FAILED* ]]; then
        # The cleanup test can fail on a check of its own after removing
        # everything (an app's last "nothing attempted under tests" step,
        # 0.12.3): then the report names that check, not the cleanup.
        local after_cleanup
        after_cleanup="$("$RC_PY" -c '
import json, os, sys
live = sys.argv[1]
try:
    steps = [json.loads(l) for l in open(os.path.join(live, "results.jsonl")) if l.strip()]
    path = os.path.join(live, "ledger.json")
    ledger = json.load(open(path)) if os.path.exists(path) else []
except Exception:
    sys.exit(0)
last = max((i for i, s in enumerate(steps) if s.get("step") == "cleanup"), default=None)
if last is None or not steps[last].get("passed") or any(not i.get("removed") for i in ledger):
    sys.exit(0)
print("; ".join(dict.fromkeys(s["step"] for s in steps[last + 1:] if not s.get("passed"))))
' "$RC_RUN/live")"
        if [[ -n "$after_cleanup" ]]; then
            RC_CLEANUP_STATUS="passed (every test object removed); the cleanup test then failed on: $after_cleanup"
            [[ "$result" == passed ]] && result="FAILED: $after_cleanup"
        else
            result="FAILED: cleanup"
        fi
    fi
    [[ "${RC_ALLOWLIST_COPY:-}" == FAILED* ]] && result="$RC_ALLOWLIST_COPY"
    if [[ -n "$RC_FAULT" && "$result" == "passed" ]]; then
        result="FAILED: the injected fault ($RC_FAULT) didn't stop the check"
    fi
    RC_LIVE_IN_CONTAINER="${TEST_HOST_CONTAINER:-}" RC_ALLOWLIST_COPY="${RC_ALLOWLIST_COPY:-}" \
    "$RC_PY" - "$RC_RUN" "$APP_NAME" "$result" "$RC_KIND" "$RC_JTKIT" "${RC_CLEANUP_STATUS:-not needed}" \
        "${(j:|:)RC_STAGE_NAMES}" "${(j:|:)RC_STAGE_STATUS}" <<'EOF'
import json, os, sys
run, app, status, kind, jtkit, cleanup, names, statuses = sys.argv[1:9]
def load(path, default):
    try:
        with open(os.path.join(run, path)) as f: return json.load(f)
    except Exception: return default
results = []
try:
    with open(os.path.join(run, "live", "results.jsonl")) as f:
        results = [json.loads(l) for l in f if l.strip()]
except Exception: pass
ledger = load("live/ledger.json", [])
# Each test process appends its refusals to refusals.jsonl as they happen (0.12.3).
refusals = []
try:
    with open(os.path.join(run, "live", "refusals.jsonl")) as f:
        refusals = [json.loads(l) for l in f if l.strip()]
except Exception: pass
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
    lines.append(f"- Live folder in the app's container (readable by you only); allow-list copy: {os.environ.get('RC_ALLOWLIST_COPY') or 'not checked'}")
for i in left:
    lines.append(f"- **Not removed:** {i['resource']} {i['id']} “{i['name']}”")
lines += ["", f"## Refused requests ({len(refusals)})", ""]
lines += [f"- {r['method']} {r['location']}: {r['reason']}" for r in refusals] or ["None."]
lines += ["", "## Saved connections and Keychain item names", "",
          f"- Fingerprint before: {before}", f"- Fingerprint after: {after}",
          "- " + ("Unchanged." if before == after else "**CHANGED** (compare fingerprint.before.names and fingerprint.after.names)")]
open(os.path.join(run, "report.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
EOF
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
    RC_WORK="$(mktemp -d "${TMPDIR:-/tmp}/jtkit-release-check.XXXXXX")"
    # Xcode's own build folder: the sandboxed UI test runner can't attach
    # to an app built under Application Support.
    RC_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE"
    RC_PACKAGES="$RC_DERIVED/SourcePackages"
    RC_WORKSPACE="${JTKIT_WORKSPACE:-$HOME/Developer/Apps.xcworkspace}"
    RC_ROLES=("${ROLES[@]}")
    RC_STAGE_NAMES=() RC_STAGE_STATUS=() RC_SECRET_VARS=() RC_CLEANED=0 RC_LIVE_STARTED=0 RC_FAILED=""
    RC_LIVE_DIR="$RC_RUN/live" RC_LIVE_ALLOWLIST="$RC_ALLOWLIST" RC_LIVE_PARENT="" RC_ALLOWLIST_COPY=""
    mkdir -p "$RC_RUN/logs" "$RC_RUN/results" "$RC_RUN/live" && chmod 700 "$RC_BASE" "$RC_RUN"
    RC_READY=1 RC_LOCKED=0
    rc_lock

    if (( RC_LOCAL )); then
        RC_KIND="pre-release (local JTKit in Apps.xcworkspace, not the published version)"
        RC_JTKIT="local $(git -C "$RC_LIB_DIR/.." describe --tags --always --dirty 2>/dev/null)"
    else
        RC_KIND="release (the app's own project, published JTKit)"
        RC_JTKIT="$(git -C "$RC_LIB_DIR/.." describe --tags --always 2>/dev/null)"
    fi
    [[ -n "$RC_FAULT" ]] && RC_KIND="FAULT TEST (--fault $RC_FAULT), not a release check; $RC_KIND"
    rc_log "Release check for $APP_NAME, $RC_KIND"
    rc_log "Run folder: $RC_RUN"
    rc_xcodebuild_base

    # Stage 1: build and sign in
    rc_check_allowlist
    rc_live_setup
    if (( RC_ALL_TENANTS )); then
        RC_ROLES=($("$RC_PY" -c 'import json,sys; print(" ".join(sorted({t["role"] for t in json.load(open(sys.argv[1]))["tenants"] if sys.argv[2]=="1" or not t.get("production")})))' "$RC_ALLOWLIST" "$RC_PRODUCTION"))
    elif (( ! RC_PRODUCTION )); then
        # The app's production roles take part only with --include-production.
        RC_ROLES=($("$RC_PY" -c 'import json,sys; prod={t["role"] for t in json.load(open(sys.argv[1]))["tenants"] if t.get("production")}; print(" ".join(r for r in sys.argv[2:] if r not in prod))' "$RC_ALLOWLIST" "${ROLES[@]}"))
        local left_out=() role
        for role in "${ROLES[@]}"; do (( ${RC_ROLES[(Ie)$role]} )) || left_out+=("$role"); done
        (( ${#left_out} )) && rc_log "Left out (production, no --include-production): ${(j:, :)left_out}"
    fi
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
    rc_read_credentials
    rc_live_environment 0
    if ! rc_test "$SIGNIN_TEST"; then
        rc_stage "1 build and sign in" "FAILED"
        rc_fail "Sign-in failed (logs/${SIGNIN_TEST//\//-}.*.log)"
    fi
    rc_live_off
    rc_stage "1 build and sign in" "passed (${(j:, :)RC_ROLES})"

    # Stage 2: unit tests (live checks skip themselves: JTKIT_LIVE isn't set)
    if ! rc_test "$UNIT_TESTS"; then
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
    RC_LIVE_STARTED=1
    rc_live_environment 1
    if [[ "$RC_FAULT" == interrupt-live ]]; then
        rc_interrupt_live "${LIVE_TESTS[1]}"
    fi
    for test in "${LIVE_TESTS[@]}"; do
        rc_log "  live: $test"
        if ! rc_test "$test"; then
            rc_stage "4 live checks" "FAILED: $test"
            rc_fail "Live check failed: $test"
        fi
    done
    rc_stage "4 live checks" "passed"
    return 0
}

# zsh runs an EXIT trap set inside a function when that function returns, so
# the traps are set here, at the script's top level, when it's loaded.
RC_READY=0
trap rc_cleanup EXIT
trap 'RC_FAILED="interrupted"; rc_cleanup; exit 130' INT TERM
