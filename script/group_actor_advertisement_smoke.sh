#!/usr/bin/env bash
set -euo pipefail
# Read-only Actor smoke test: never modifies flags, processes or services.
usage() {
  echo "Usage: script/group_actor_advertisement_smoke.sh ACTOR_URL off|on" >&2
  echo "Optional: OUTPUT_DIR=/tmp/group-off BASELINE_JSON=/tmp/group-off/actor.json" >&2
  exit 2
}
[[ $# -eq 2 ]] || usage
actor_url=$1
expected=$2
[[ $actor_url == https://*/users/* ]] || usage
[[ $expected == on || $expected == off ]] || usage
for command in curl jq; do
  command -v "$command" >/dev/null || { echo "ERROR: missing $command" >&2; exit 2; }
done
output_dir=${OUTPUT_DIR:-$(mktemp -d)}
mkdir -p "$output_dir"
headers="$output_dir/headers.txt"
actor="$output_dir/actor.json"
http_code=$(curl --silent --show-error --dump-header "$headers" \
  --output "$actor" --write-out '%{http_code}' \
  --header 'Accept: application/activity+json' "$actor_url")
[[ $http_code == 200 ]] || { echo "FAIL: HTTP $http_code (see $headers)" >&2; exit 1; }
tr -d '\r' < "$headers" | grep -Eiq '^content-type:[[:space:]]*application/activity\+json([;[:space:]]|$)' ||
  { echo 'FAIL: Content-Type must be application/activity+json' >&2; exit 1; }
property='https://fedibird.com/ns/group/v1#protocols'
profile='https://fedibird.com/ns/group/v1#MentionFollowAnnounce'
jq -e --arg expected "$expected" --arg property "$property" --arg profile "$profile" --arg url "$actor_url" '
  def has_protocol_context:
    (."@context") as $c |
    (if ($c|type)=="array" then $c elif ($c|type)=="object" then [$c] else [] end) |
    any(.[]; type=="object" and
      .fedibirdGroupProtocols == {"@id":$property,"@type":"@id","@container":"@set"});
  (.type=="Group") and (.id==$url) and has("publicKey") and
  (has("canPost")|not) and (has("viewerCapabilities")|not) and
  (has("roles")|not) and (has("affiliations")|not) and
  (has("groupProtocols")|not) and
  (if $expected=="on"
    then .fedibirdGroupProtocols==[$profile] and has_protocol_context
    else (has("fedibirdGroupProtocols")|not) and (has_protocol_context|not)
   end)
' "$actor" >/dev/null ||
  { echo "FAIL: mismatched $expected Actor shape; inspect $actor" >&2; exit 1; }

if [[ -n ${BASELINE_JSON:-} ]]; then
  [[ -f $BASELINE_JSON ]] || { echo 'ERROR: missing BASELINE_JSON' >&2; exit 2; }
  filter='del(.fedibirdGroupProtocols) | ."@context" |=
    (if type=="array" then map(if type=="object" then del(.fedibirdGroupProtocols) else . end)
     elif type=="object" then del(.fedibirdGroupProtocols) else . end)'
  jq -S "$filter" "$BASELINE_JSON" > "$output_dir/baseline.normalized.json"
  jq -S "$filter" "$actor" > "$output_dir/current.normalized.json"
  diff -u "$output_dir/baseline.normalized.json" "$output_dir/current.normalized.json" ||
    { echo 'FAIL: extra Actor fields changed' >&2; exit 1; }
fi
echo "PASS: expected $expected; HTTP 200; application/activity+json"
echo "Actor: $actor"
echo "Headers: $headers"
