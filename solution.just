set quiet  # Recipes are silent by default
set export  # Just variables are exported to the environment

terraform := `which terraform || which tofu || echo ""` # require 'terraform' or 'opentofu'
uv_flags := "--frozen --isolated"

[private]
@default:
  just --list solution

# Deploys into whichever Juju controller is currently active -- `juju switch`
# to the intended one first.
# Init/apply a solution's Terraform module, then run its solution test suite.
[group("test")]
[working-directory("./tests/solution")]
test solution="cos-lite":
  #!/usr/bin/env bash
  set -euo pipefail
  echo "==> Testing solution: {{solution}}"
  juju whoami
  if [ -z "${terraform}" ]; then echo "ERROR: please install terraform or opentofu"; exit 1; fi
  $terraform -chdir="{{solution}}/terraform" init -upgrade
  $terraform -chdir="{{solution}}/terraform" apply -auto-approve
  uv run ${uv_flags} pytest -vv -ra --capture=no "{{solution}}"

# Promote every charm in a solution from /beta to /candidate
[group("promote")]
promote solution="cos-lite" ref="main":
  #!/usr/bin/env bash
  set -euo pipefail
  echo "==> Promoting solution: {{solution}} (ref: {{ref}})"
  charms_tracks=$(just charm-tracks "{{solution}}" "{{ref}}")
  if [ -z "$charms_tracks" ]; then
    echo "ERROR: no pinned charms found for solution '{{solution}}'; refusing to promote nothing."
    exit 1
  fi
  while read -r charm track; do
    echo "--> Promoting $charm from ${track}/beta to ${track}/candidate"
    charmcraft promote --name "$charm" --from-channel "${track}/beta" --to-channel "${track}/candidate" --yes
  done <<< "$charms_tracks"

# List the charm name + track pinned by each charm in a product module
[group("promote")]
charm-tracks module ref='main':
  #!/usr/bin/env bash
  set -euo pipefail
  excluded_charms="self-signed-certificates traefik-k8s s3-integrator"
  upgrades=$(git show "{{ref}}:terraform/{{module}}/upgrades.tf")
  locals=$(git show "{{ref}}:terraform/{{module}}/locals.tf")

  charm_keys=""
  in_block=0
  charm=""
  key=""
  while IFS= read -r line; do
    if [[ "$line" =~ data[[:space:]]*\"juju_charm\"[[:space:]]*\" ]]; then
      in_block=1
      continue
    fi
    if [ "$in_block" -eq 1 ] && [[ "$line" =~ ^\} ]]; then
      in_block=0
      charm=""
      key=""
      continue
    fi
    if [ "$in_block" -eq 1 ] && [[ "$line" =~ charm[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
      charm="${BASH_REMATCH[1]}"
    fi
    if [ "$in_block" -eq 1 ] && [[ "$line" =~ channel[[:space:]]*=[[:space:]]*local\.channels\.([a-zA-Z0-9_]+) ]]; then
      key="${BASH_REMATCH[1]}"
    fi
    if [ "$in_block" -eq 1 ] && [ -n "$charm" ] && [ -n "$key" ]; then
      charm_keys+="$charm $key"$'\n'
      charm=""
      key=""
    fi
  done <<< "$upgrades"

  declare -A tracks
  in_tracks=0
  while IFS= read -r line; do
    if [[ "$line" =~ tracks[[:space:]]*=[[:space:]]*\{ ]]; then
      in_tracks=1
      continue
    fi
    if [ "$in_tracks" -eq 1 ] && [[ "$line" =~ ^\ \ \} ]]; then
      in_tracks=0
      continue
    fi
    if [ "$in_tracks" -eq 1 ] && [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_]+)[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
      tracks["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <<< "$locals"

  while read -r charm key; do
    [ -z "$charm" ] && continue
    case " $excluded_charms " in *" $charm "*) continue ;; esac
    track="${tracks[$key]:-}"
    [ -n "$track" ] && printf '%s %s\n' "$charm" "$track"
  done <<< "$charm_keys"

# Snapshot charm and resource revisions to compare candidate with stable.
[group("promote")]
pin module="cos-lite" ref="main" risk="candidate":
  #!/usr/bin/env bash
  set -euo pipefail
  charms_tracks=$(just solution charm-tracks "{{module}}" "{{ref}}")
  if [ -z "$charms_tracks" ]; then
    echo "ERROR: no pinned charms found for module '{{module}}' at '{{ref}}'" >&2
    exit 1
  fi
  fields="channel-map.channel.name,channel-map.channel.base.name,channel-map.channel.base.channel"
  fields+=",channel-map.channel.base.architecture,channel-map.revision.revision"
  fields+=",default-release.resources.name,default-release.resources.revision"
  while read -r charm track; do
    channel="${track}/{{risk}}"
    # The public API exposes resources for the default (amd64) release only.
    info=$(curl -fsS --get "https://api.charmhub.io/v2/charms/info/${charm}" \
      --data-urlencode "channel=${channel}" --data-urlencode "fields=${fields}")
    jq -c --arg charm "$charm" --arg track "$track" --arg channel "$channel" '{
      charm: $charm,
      track: $track,
      channel: $channel,
      revisions: [.["channel-map"][] | select(.channel.name == $channel) | {
        revision: .revision.revision,
        base: "\(.channel.base.name)@\(.channel.base.channel)",
        architecture: .channel.base.architecture
      }] | unique,
      resources: [.["default-release"].resources[]? | {name, revision}] | sort_by(.name)
    }' <<< "$info"
  done <<< "$charms_tracks" | jq -s '
    [.[] | select(.revisions == []) | .channel + " (" + .charm + ")"] as $empty
    | if $empty != [] then error("nothing released in: " + ($empty | join(", "))) else . end
  '

# Build a release manifest from SolQA's metrics.json; all matching apps must agree.
[group("promote")]
tested module ref metrics_file risk="candidate" arch="amd64":
  #!/usr/bin/env bash
  set -euo pipefail
  charms_tracks=$(just solution charm-tracks "{{module}}" "{{ref}}")
  if [ -z "$charms_tracks" ]; then
    echo "ERROR: no pinned charms found for module '{{module}}' at '{{ref}}'" >&2
    exit 1
  fi
  while read -r charm track; do
    jq --arg charm "$charm" --arg track "$track" \
       --arg channel "${track}/{{risk}}" --arg arch "{{arch}}" '
      [.applications[]? | select(.charm == $charm) | {channel, revision, resources}] | unique
      | if length == 0 then error("\($charm) was not deployed")
        elif any(.channel != $channel) then error("\($charm) was not deployed from \($channel)")
        elif length > 1 then error("the applications using \($charm) run different revisions")
        else .[0] end
      | {
          charm: $charm,
          track: $track,
          channel: $channel,
          revisions: [{revision: .revision, architecture: $arch}],
          resources: (.resources | to_entries | map({name: .key, revision: .value}) | sort_by(.name))
        }
    ' "{{metrics_file}}"
  done <<< "$charms_tracks" | jq -s .

# Release recorded revisions and resources; SolQA tests amd64 only. Dry run by default.
[group("promote")]
release-pinned pin_file to_risk="stable" archs="amd64" dry_run="true":
  #!/usr/bin/env bash
  set -euo pipefail
  if [ "{{dry_run}}" = "false" ]; then
    echo "==> Releasing the pinned revisions to /{{to_risk}}"
  else
    echo "==> Dry run: printing the release commands only (pass dry_run=false to release)"
  fi
  releases=$(jq -r --arg risk "{{to_risk}}" '
    .[] as $charm
    | $charm.revisions[]
    | [$charm.charm, (.revision | tostring), .architecture, "\($charm.track)/\($risk)"]
      + [$charm.resources[] | "\(.name):\(.revision)"]
    | @tsv
  ' "{{pin_file}}")
  if [ -z "$releases" ]; then
    echo "ERROR: '{{pin_file}}' has no revisions; refusing to release nothing." >&2
    exit 1
  fi
  skipped=0
  while IFS=$'\t' read -r -a fields; do
    charm=${fields[0]} revision=${fields[1]}
    arch=${fields[2]} channel=${fields[3]}
    if [[ " {{archs}} " != *" $arch "* ]]; then
      echo "--> Skipping $charm revision $revision ($arch): not tested; release it by hand if intended"
      skipped=$((skipped + 1))
      continue
    fi
    args=(release "$charm" --revision "$revision" --channel "$channel")
    for resource in "${fields[@]:4}"; do args+=(--resource "$resource"); done
    echo "--> charmcraft ${args[*]}"
    if [ "{{dry_run}}" = "false" ]; then charmcraft "${args[@]}"; fi
  done <<< "$releases"
  if [ "$skipped" -gt 0 ]; then echo "==> Skipped $skipped revision(s), listed above"; fi
