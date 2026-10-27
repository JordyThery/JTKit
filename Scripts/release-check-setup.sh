#!/bin/zsh
# Saves one credential for the release check in the login Keychain
# (service be.jordythery.release-check, account <role>/<item>), for a tenant
# on the allow-list that no app has a saved connection for.
#
#   Scripts/release-check-setup.sh jamf-test-b jamfpro-password
#
# Run it yourself in Terminal: `security` asks for the value with hidden
# input (-w is the last option), so it never appears in a command line, the
# shell history or a log. Only /usr/bin/security can read it back without a prompt.
set -e
role="$1"; item="$2"
if [[ -z "$role" || -z "$item" ]]; then
    print -u2 "Usage: $0 <role> <item>   e.g. $0 jamf-test-b client-secret"
    exit 2
fi
allowlist="${JTKIT_ALLOWLIST:-$HOME/Library/Application Support/JTKit Release Check/allowlist.json}"
if ! /usr/bin/python3 -c 'import json,sys; sys.exit(0 if any(t["role"]==sys.argv[2] for t in json.load(open(sys.argv[1]))["tenants"]) else 1)' "$allowlist" "$role"; then
    print -u2 "$role isn't on the allow-list ($allowlist); add it there first."
    exit 1
fi
print "Saving $item for $role in the login Keychain. Type or paste it when asked (it isn't shown)."
security add-generic-password -U -s be.jordythery.release-check -a "$role/$item" \
    -l "JTKit release check: $role $item" -j "Read by the release check only" -w
print "Saved."
