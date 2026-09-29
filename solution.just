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

# Print, as JSON, the exact revisions and resource revisions that every charm
# pinned by a product module has in <track>/<risk> right now. The stable gate
# uses it to skip testing when /stable already holds the /candidate revisions.
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
  pins=$(while read -r charm track; do
    channel="${track}/{{risk}}"
    # The `channel` parameter narrows the channel map down to that channel. The
    # default release (and so its resources) is the amd64 one: the public API
    # doesn't show resources for other architectures.
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
  done <<< "$charms_tracks")
  jq -s '
    [.[] | select(.revisions == []) | .channel + " (" + .charm + ")"] as $empty
    | if $empty != [] then error("nothing released in: " + ($empty | join(", "))) else . end
  ' <<< "$pins"

# Print, in the same format as `pin`, the revisions and resource revisions that
# a SolQA run deployed, and so tested, for every charm the product module pins.
# The stable gate releases exactly these. The metrics file is the metrics.json
# that `sqa_tests` writes and SolQA uploads as a run artifact. Fails if a charm
# wasn't deployed from <track>/<risk>, or if its applications run different
# revisions. SolQA's lab only has amd64 machines, hence the `arch` default.
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
    jq -n --arg charm "$charm" --arg track "$track" --arg channel "${track}/{{risk}}" \
      '{charm: $charm, track: $track, channel: $channel}'
  done <<< "$charms_tracks" | jq -s --slurpfile metrics "{{metrics_file}}" --arg arch "{{arch}}" '
    [$metrics[0].applications // {} | .[]] as $apps
    | map(. as $c
      | [$apps[] | select(.charm == $c.charm)] as $deployed
      | ([$deployed[].channel] | unique) as $channels
      | if $deployed == [] then error("\($c.charm) was not deployed")
        elif $channels != [$c.channel] then
          error("\($c.charm) was deployed from \($channels | join(", ")), not \($c.channel)")
        elif ([$deployed[] | [.revision, .resources]] | unique | length) > 1 then
          error("the applications using \($c.charm) run different revisions")
        else $c + {
          revisions: [{revision: $deployed[0].revision, architecture: $arch}],
          resources: [$deployed[0].resources | to_entries[] | {name: .key, revision: .value}]
            | sort_by(.name)
        } end)
  '

# Release exactly the revisions and resources recorded by `pin` or `tested` to
# <track>/<to_risk>, one `charmcraft release` per revision. Only the
# architectures in `archs` are released: SolQA's lab only tests amd64, and the
# pin only knows amd64 resources, so other revisions are listed for a person
# to handle. Only prints the commands unless dry_run is "false".
[group("promote")]
release-pinned pin_file to_risk="stable" archs="amd64" dry_run="true":
  #!/usr/bin/env bash
  set -euo pipefail
  if [ "{{dry_run}}" = "false" ]; then
    echo "==> Releasing the pinned revisions to /{{to_risk}}"
  else
    echo "==> Dry run: printing the release commands only (pass dry_run=false to release)"
  fi
  releases=$(jq -r --arg risk "{{to_risk}}" --arg archs "{{archs}}" '
    ($archs | split(" ")) as $allowed
    | .[] as $c
    | $c.revisions[]
    | [(if .architecture | IN($allowed[]) then "release" else "skip" end),
       $c.charm, (.revision | tostring), .architecture, "\($c.track)/\($risk)"]
      + [$c.resources[] | "\(.name):\(.revision)"]
    | @tsv
  ' "{{pin_file}}")
  if [ -z "$releases" ]; then
    echo "ERROR: '{{pin_file}}' has no revisions; refusing to release nothing." >&2
    exit 1
  fi
  skipped=0
  while IFS=$'\t' read -r -a fields; do
    action=${fields[0]} charm=${fields[1]} revision=${fields[2]} arch=${fields[3]} channel=${fields[4]}
    if [ "$action" = "skip" ]; then
      echo "--> Skipping $charm revision $revision ($arch): not tested; release it by hand if intended"
      skipped=$((skipped + 1))
      continue
    fi
    args=(release "$charm" --revision "$revision" --channel "$channel")
    for resource in "${fields[@]:5}"; do args+=(--resource "$resource"); done
    echo "--> charmcraft ${args[*]}"
    if [ "{{dry_run}}" = "false" ]; then charmcraft "${args[@]}"; fi
  done <<< "$releases"
  if [ "$skipped" -gt 0 ]; then echo "==> Skipped $skipped revision(s), listed above"; fi
