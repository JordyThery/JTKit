#!/bin/zsh
# Start-of-conversation check for the app in the current folder: its
# resolved JTKit version against JTKit’s latest tag on GitHub (with the
# CHANGELOG entries in between), and, for information, the commits on main
# since the app’s latest GitHub release. Reads only; changes nothing.
#
#   cd ~/Developer/<App> && ../JTKit/Scripts/check-versions.sh
#   (or: curl -fsSL https://raw.githubusercontent.com/JordyThery/JTKit/main/Scripts/check-versions.sh | zsh)
#
# Exit status (the JTKit version only): 0 the latest, 1 behind the latest
# tag, 2 the version couldn’t be checked. The release line never changes it.
setopt pipe_fail

JTKIT_REPO="JordyThery/JTKit"
JTKIT_URL="https://github.com/$JTKIT_REPO.git"
APP="${PWD:t}"
result=0

# The GitHub API: through gh when it’s signed in, otherwise plain curl
# (public repositories only).
github_api() {
    if command -v gh > /dev/null 2>&1 && gh auth status > /dev/null 2>&1; then
        gh api "$1"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
    fi
}

json_field() {
    /usr/bin/python3 -c 'import json, sys
d = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    d = d[key]
print(d)' "$1"
}

# MARK: JTKit

resolved_file=""
for file in *.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved(N); do
    resolved_file="$file"; break
done
resolved=""
if [[ -n "$resolved_file" ]]; then
    resolved="$(/usr/bin/python3 -c 'import json, sys
pins = json.load(open(sys.argv[1])).get("pins", [])
print(next((p["state"].get("version") or "" for p in pins if p.get("identity") == "jtkit"), ""))' "$resolved_file" 2>/dev/null)"
fi

latest="$(git ls-remote --tags --refs "$JTKIT_URL" 2>/dev/null | sed -n 's#.*refs/tags/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' | sort -V | tail -1)"

if [[ -z "$resolved" ]]; then
    print -r -- "$APP: JTKit: no resolved version found (no Package.resolved with JTKit here)."
    result=2
elif [[ -z "$latest" ]]; then
    print -r -- "$APP: JTKit $resolved; couldn’t read JTKit’s tags from GitHub."
    result=2
elif [[ "$resolved" == "$latest" ]]; then
    print -r -- "$APP: JTKit $resolved, the latest."
else
    newest="$(printf '%s\n%s\n' "$resolved" "$latest" | sort -V | tail -1)"
    if [[ "$newest" == "$resolved" ]]; then
        print -r -- "$APP: JTKit $resolved, newer than the latest tag $latest (not released yet)."
    else
        print -r -- "$APP: JTKit $resolved, out of date: the latest is $latest. In between:"
        result=1
        changelog=""
        if [[ -f ../JTKit/CHANGELOG.md ]]; then
            changelog="$(< ../JTKit/CHANGELOG.md)"
        else
            changelog="$(curl -fsSL "https://raw.githubusercontent.com/$JTKIT_REPO/main/CHANGELOG.md" 2>/dev/null)"
        fi
        if [[ -z "$changelog" ]]; then
            print -r -- "  (couldn’t read JTKit’s CHANGELOG)"
        else
            # Every entry newer than the resolved version, up to the latest
            # tag: its heading and its summary line.
            print -r -- "$changelog" | /usr/bin/python3 -c 'import re, sys
def key(v): return tuple(int(x) for x in v.split("."))
old, new = key(sys.argv[1]), key(sys.argv[2])
lines = sys.stdin.read().splitlines()
for i, line in enumerate(lines):
    m = re.match(r"## (\d+\.\d+\.\d+)\b", line)
    if m and old < key(m.group(1)) <= new:
        summary = next((l for l in lines[i + 1:] if l.strip()), "")
        print("  " + line[3:] + (": " + summary if summary and not summary.startswith(("## ", "- ")) else ""))' "$resolved" "$latest"
        fi
    fi
fi

# MARK: The app’s release (information only)

remote="$(git remote get-url origin 2>/dev/null)"
repo="${${remote#*github.com[:/]}%.git}"
if [[ -z "$remote" || "$repo" == "$remote" ]]; then
    print -r -- "$APP: no GitHub remote, so no release to compare with."
else
    release="$(github_api "repos/$repo/releases/latest" 2>/dev/null | json_field tag_name 2>/dev/null)"
    if [[ -z "$release" ]]; then
        print -r -- "$APP: no GitHub release found for $repo."
    else
        ahead="$(github_api "repos/$repo/compare/$release...main" 2>/dev/null | json_field ahead_by 2>/dev/null)"
        if [[ -z "$ahead" ]]; then
            print -r -- "$APP: latest release $release; couldn’t count the commits on main since."
        elif (( ahead == 0 )); then
            print -r -- "$APP: no unreleased commits since $release."
        else
            print -r -- "$APP: $ahead unreleased commit$( (( ahead == 1 )) || print -n s) since $release."
        fi
    fi
fi
exit $result
