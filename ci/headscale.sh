#!/usr/bin/env bash
# Give a CI run its own Headscale user and remove it afterwards, through the Headscale v0.29 REST API.
#   setup <user>      create the user, mint its key and the RKE2 token, print them encrypted with CI_PASSPHRASE
#   cleanup <user>    expire the user's keys, delete its nodes, delete the user. A missing user is success.
#   janitor <hours>   run cleanup on every ci-<run>-<attempt> user older than <hours>
# Reads HEADSCALE_URL and HEADSCALE_API_KEY. Every secret is masked before anything can print it, and curl's errors
# never include the URL.
set -euo pipefail
url=${HEADSCALE_URL:?}
url=${url%/}
: "${HEADSCALE_API_KEY:?}"
host=${url#*://}
echo "::add-mask::$url" >&2
echo "::add-mask::${host%%[/:]*}" >&2

# api <method> <path> [curl args]
api() {
  curl --fail --silent --show-error --request "$1" --header "Authorization: Bearer $HEADSCALE_API_KEY" \
    --header 'Content-Type: application/json' "${@:3}" "$url/api/v1/$2"
}

setup() {
  local user=$1 id expiration key token
  : "${CI_PASSPHRASE:?}"
  id=$(api POST user --data "$(jq --null-input --arg name "$user" '{name: $name}')" |
    jq --exit-status --raw-output .user.id)
  expiration=$(date --utc --date '+2 hours' +%FT%TZ)
  key=$(api POST preauthkey --data "$(jq --null-input --arg user "$id" --arg expiration "$expiration" \
    '{user: $user, reusable: true, ephemeral: true, expiration: $expiration}')" |
    jq --exit-status --raw-output .preAuthKey.key)
  echo "::add-mask::$key" >&2
  token=$(openssl rand -hex 32)
  echo "::add-mask::$token" >&2
  printf 'HEADSCALE_URL=%s\nTS_AUTHKEY=%s\nRKE2_TOKEN=%s\n' "$url" "$key" "$token" |
    openssl enc -aes-256-cbc -pbkdf2 -a -A -pass env:CI_PASSPHRASE
  echo
}

# Keys first, so no new node can join, then nodes, because Headscale refuses to delete a user that has nodes.
# Deleting the user deletes its keys.
cleanup() {
  local user=$1 id keys key nodes node
  id=$(api GET user | jq --raw-output --arg user "$user" '.users[]? | select(.name == $user) | .id')
  if [[ -z $id ]]; then
    echo "no user $user"
    return
  fi
  # Lists go through a variable because a failing command inside a for list does not stop the script.
  keys=$(api GET preauthkey | jq --raw-output --arg user "$user" '.preAuthKeys[]? | select(.user.name == $user) | .id')
  for key in $keys; do
    api POST preauthkey/expire --data "$(jq --null-input --arg id "$key" '{id: $id}')" >/dev/null
  done
  # An ephemeral node can vanish between the list and the delete. A node that is really left makes the user delete fail.
  nodes=$(api GET "node?user=$user" | jq --raw-output --arg user "$user" '.nodes[]? | select(.user.name == $user) | .id')
  for node in $nodes; do
    api DELETE "node/$node" >/dev/null || echo "node $node already gone"
  done
  api DELETE "user/$id" >/dev/null
  echo "removed user $user"
}

# A user that fails, for example because another cleanup deleted it midway, does not stop the rest. Each cleanup runs
# as its own process, because set -e does not apply inside a function called from the left of ||.
janitor() {
  local users user failed=0
  users=$(api GET user | jq --raw-output --argjson hours "$1" '.users[]?
    | select((.name | test("^ci-[0-9]+-[0-9]+$")) and (.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) < now - $hours * 3600)
    | .name')
  for user in $users; do
    "$0" cleanup "$user" || failed=1
  done
  return "$failed"
}

case ${1:-} in
  setup | cleanup | janitor) "$1" "${2:?usage: $0 setup|cleanup <user> | janitor <hours>}" ;;
  *) echo "usage: $0 setup|cleanup <user> | janitor <hours>" >&2; exit 2 ;;
esac
