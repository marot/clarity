#!/usr/bin/env bash
set -euo pipefail

# worktree-create.sh — WorktreeCreate hook. Creates a Claude Code worktree
# under <main>/.claude/worktrees/<name>, wires .beads redirects, and writes a
# per-worktree .worktree.env whose service ports are offset by
# worktree_index * step so a worktree never squats the main checkout's ports.
#
# Ports-config resolution (.worktree-ports.json), for the port-offset env only:
#   1. The worktree's own tracked copy, when present (the normal case).
#   2. Fallback for rigs that GITIGNORE it (per-machine port assignments —
#      e.g. eval-lab): read the MAIN checkout's copy instead. Without this a
#      gitignored config yields NO .worktree.env, so the worktree silently
#      falls back to base ports and hijacks the main checkout's ports/preview
#      URL (observed live: an eval-lab worktree squatting PHX_PORT 4160).
#
# Chosen order when the fallback finds BOTH <main>/.worktree-ports.json and
# <main>/app/.worktree-ports.json (eval-lab keeps one at each level): the ROOT
# config is PRIMARY — it supplies project_name/step and wins on any service-key
# collision — and the app config's services are UNIONED in, so every declared
# service (e.g. root REPORTS_PORT and app PHX_PORT alike) gets an offset port.
#
# The fallback drives ONLY the .worktree.env port offsets. The .mcp.json,
# post_create, and preview-registration steps stay gated on the worktree-LOCAL
# config, so a fallback (session) worktree registers no preview and touches no
# caddy/registry state — matching prior behavior for those worktrees.
#
# The same root+app fallback resolution is mirrored (offline, no shared file)
# in .runtime/tailnet-ingress/backfill-poisoned-worktree-env.sh in the town
# repo — keep the two in sync.

REPO_MODE="standard"
REPO_ROOT=""
REPO_GIT_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${HANDGEMACHT_WORKSPACE_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

find_rig_repo_root() {
  local start="$1"
  local current
  current="$(realpath "$start")"

  while true; do
    if [ -d "${current}/.repo.git" ] && [ -f "${current}/config.json" ]; then
      local repo_type
      repo_type="$(jq -r '.type // empty' "${current}/config.json" 2>/dev/null || true)"
      if [ "$repo_type" = "rig" ]; then
        echo "$current"
        return 0
      fi
    fi

    local parent
    parent="$(dirname "$current")"
    if [ "$parent" = "$current" ]; then
      return 1
    fi
    current="$parent"
  done
}

setup_repo_context() {
  local cwd="$1"
  local rig_root

  if rig_root="$(find_rig_repo_root "$cwd")"; then
    REPO_MODE="rig"
    REPO_ROOT="$rig_root"
    REPO_GIT_DIR="${rig_root}/.repo.git"
    return
  fi

  REPO_MODE="standard"
  REPO_ROOT="$(git -C "$cwd" rev-parse --show-toplevel)"
  REPO_GIT_DIR=""
}

git_repo() {
  if [ "$REPO_MODE" = "rig" ]; then
    git --git-dir="$REPO_GIT_DIR" --work-tree="$REPO_ROOT" "$@"
    return
  fi

  git -C "$REPO_ROOT" "$@"
}

resolve_main_worktree() {
  local main_path

  main_path="$(
    git_repo worktree list --porcelain | awk '
      $1 == "worktree" { worktree = substr($0, 10) }
      $1 == "branch" && $2 == "refs/heads/main" { print worktree; exit }
    '
  )"

  if [ -z "$main_path" ]; then
    main_path="$(git_repo worktree list --porcelain | awk '$1 == "worktree" { print substr($0, 10); exit }')"
  fi

  if [ -n "$main_path" ]; then
    realpath "$main_path"
  fi
}

resolve_worktree_index() {
  local worktree_path="$1"
  local main_path="$2"
  local index=0
  local found=0

  while IFS= read -r line; do
    local candidate
    candidate="${line#worktree }"
    candidate="$(realpath "$candidate")"

    if [ "$candidate" = "$main_path" ]; then
      if [ "$candidate" = "$worktree_path" ]; then
        found=1
        index=0
        break
      fi
      continue
    fi

    index=$((index + 1))
    if [ "$candidate" = "$worktree_path" ]; then
      found=1
      break
    fi
  done < <(git_repo worktree list --porcelain | grep '^worktree ')

  if [ "$found" -eq 0 ]; then
    echo 0
    return
  fi

  echo "$index"
}

compute_otel_resource_attributes() {
  local raw="$1"
  local project_name="$2"
  local worktree_name="$3"
  declare -A attrs=()

  if [ -n "$raw" ]; then
    local saved_set="$-"
    set -f
    IFS=',' read -ra pairs <<< "$raw"
    [[ "$saved_set" == *f* ]] || set +f
    for pair in "${pairs[@]}"; do
      [ -z "$pair" ] && continue
      local key="${pair%%=*}"
      if [ "$key" = "$pair" ]; then
        continue
      fi
      local value="${pair#*=}"
      attrs["$key"]="$value"
    done
  fi

  attrs["dev.project.name"]="$project_name"
  attrs["dev.worktree.name"]="$worktree_name"
  if [ -z "${attrs[service.instance.id]+set}" ]; then
    attrs["service.instance.id"]="${project_name}-${worktree_name}"
  fi

  local joined=""
  local key
  for key in $(printf '%s\n' "${!attrs[@]}" | sort); do
    if [ -n "$joined" ]; then
      joined="${joined},"
    fi
    joined="${joined}${key}=${attrs[$key]}"
  done

  echo "$joined"
}

write_env_var() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  printf "%s=%q\n" "$key" "$value" >> "$env_file"
}

# Hook API: JSON on stdin, print worktree path to stdout
input=$(cat)
name=$(echo "$input" | jq -r '.name')
cwd=$(echo "$input" | jq -r '.cwd')

setup_repo_context "$cwd"
main_repo="$REPO_ROOT"
worktree_dir="${main_repo}/.claude/worktrees/${name}"

# Create git worktree (replicating Claude Code default)
git_repo worktree add "$worktree_dir" -b "claude/${name}" HEAD >&2

# Rewrite .beads/redirect files: relative -> absolute (main repo)
while IFS= read -r -d '' redirect_file; do
  target=$(grep -v '^#' "$redirect_file" | grep -v '^$' | head -1 | tr -d '[:space:]')
  [ -z "$target" ] && continue
  [[ "$target" == /* ]] && continue

  beads_dir=$(dirname "$redirect_file")
  rig_root=$(dirname "$beads_dir")
  rel_rig=$(realpath --relative-to="$worktree_dir" "$rig_root")
  abs_target="${main_repo}/${rel_rig}/${target}"

  echo "$abs_target" > "$redirect_file"
done < <(find "$worktree_dir" -path '*/.beads/redirect' -print0 2>/dev/null)

# Create .beads/redirect for any .beads/ that has metadata.json but no redirect
# This ensures worktrees share the main repo's beads database
while IFS= read -r -d '' metadata_file; do
  beads_dir=$(dirname "$metadata_file")
  redirect_file="${beads_dir}/redirect"
  [ -f "$redirect_file" ] && continue

  # Compute the relative path from this .beads/ in the worktree to the
  # corresponding .beads/ in the main repo
  rig_root=$(dirname "$beads_dir")
  rel_path=$(realpath --relative-to="$worktree_dir" "$rig_root")
  main_beads="$(realpath "${main_repo}/${rel_path}/.beads")"

  # Only create redirect if the main repo actually has this .beads/
  if [ -d "$main_beads" ] && [ -f "${main_beads}/metadata.json" ]; then
    echo "$main_beads" > "$redirect_file"
    echo "[worktree-create] Created .beads/redirect → $main_beads" >&2
  fi
done < <(find "$worktree_dir" -name metadata.json -path '*/.beads/metadata.json' -print0 2>/dev/null)

main_worktree="$(resolve_main_worktree)"
if [ -z "$main_worktree" ]; then
  main_worktree="$(realpath "$main_repo")"
fi

worktree_realpath="$(realpath "$worktree_dir")"
worktree_index="$(resolve_worktree_index "$worktree_realpath" "$main_worktree")"
worktree_name="$(basename "$worktree_realpath")"

ports_config="${worktree_dir}/.worktree-ports.json"
project_name="$(basename "$main_repo")"
step=10
post_script=""
declare -a allow_skip_worktree=()
declare -a service_pairs=()

# Resolve which .worktree-ports.json file(s) drive the port-offset .worktree.env
# below (see header for the full rationale and the chosen root+app order).
declare -a ports_config_sources=()
if [ -f "$ports_config" ]; then
  ports_config_sources=("$ports_config")
else
  for candidate in \
    "${main_worktree}/.worktree-ports.json" \
    "${main_worktree}/app/.worktree-ports.json"; do
    [ -f "$candidate" ] && ports_config_sources+=("$candidate")
  done
fi

if [ "${#ports_config_sources[@]}" -gt 0 ]; then
  project_name_set=0
  step_set=0
  declare -A seen_service_key=()
  for src in "${ports_config_sources[@]}"; do
    if [ "$project_name_set" -eq 0 ]; then
      cfg_project_name="$(jq -r '.project_name // empty' "$src")"
      if [ -n "$cfg_project_name" ]; then
        project_name="$cfg_project_name"
        project_name_set=1
      fi
    fi

    if [ "$step_set" -eq 0 ]; then
      cfg_step="$(jq -r '.step // empty' "$src")"
      if [[ "$cfg_step" =~ ^[0-9]+$ ]] && [ "$cfg_step" -gt 0 ]; then
        step="$cfg_step"
        step_set=1
      fi
    fi

    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      pair_key="${pair%%$'\t'*}"
      [ -n "${seen_service_key[$pair_key]+set}" ] && continue
      seen_service_key["$pair_key"]=1
      service_pairs+=("$pair")
    done < <(jq -r '.services // {} | to_entries[] | "\(.key)\t\(.value)"' "$src")
  done
fi

# post_create / allow_skip_worktree belong to the mcp/preview surface that the
# fallback deliberately does not activate — read them only from the
# worktree-local config.
if [ -f "$ports_config" ]; then
  post_script="$(jq -r '.post_create.script // empty' "$ports_config")"
  mapfile -t allow_skip_worktree < <(jq -r '.post_create.allow_skip_worktree[]? // empty' "$ports_config")
fi

otel_resource_attributes="$(
  compute_otel_resource_attributes \
    "${OTEL_RESOURCE_ATTRIBUTES:-}" \
    "$project_name" \
    "$worktree_name"
)"

worktree_env="${worktree_dir}/.worktree.env"
: > "$worktree_env"

# Exclude .worktree.env from git (uses common dir so it applies to all worktrees)
wt_common_dir="$(git -C "$worktree_dir" rev-parse --git-common-dir 2>/dev/null)" || true
if [ -n "$wt_common_dir" ]; then
  mkdir -p "$wt_common_dir/info"
  if ! grep -qxF '.worktree.env' "$wt_common_dir/info/exclude" 2>/dev/null; then
    echo '.worktree.env' >> "$wt_common_dir/info/exclude"
  fi
fi
write_env_var "$worktree_env" "PROJECT_NAME" "$project_name"
write_env_var "$worktree_env" "WORKTREE_NAME" "$worktree_name"
write_env_var "$worktree_env" "WORKTREE_PATH" "$worktree_realpath"
write_env_var "$worktree_env" "WORKTREE_MAIN_PATH" "$main_worktree"
write_env_var "$worktree_env" "WORKTREE_INDEX" "$worktree_index"
write_env_var "$worktree_env" "WORKTREE_STEP" "$step"
write_env_var "$worktree_env" "OTEL_RESOURCE_ATTRIBUTES" "$otel_resource_attributes"

for pair in "${service_pairs[@]}"; do
  key="${pair%%$'\t'*}"
  base_value="${pair#*$'\t'}"

  if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "[worktree-create] Ignoring invalid service key: $key" >&2
    continue
  fi
  if [[ ! "$base_value" =~ ^[0-9]+$ ]]; then
    echo "[worktree-create] Ignoring non-numeric service base for $key: $base_value" >&2
    continue
  fi

  port_value=$((base_value + worktree_index * step))
  write_env_var "$worktree_env" "$key" "$port_value"
done

# Generate .mcp.json from mcp config in .worktree-ports.json
if [ -f "$ports_config" ] && jq -e '.mcp // empty' "$ports_config" >/dev/null 2>&1; then
  # Detect Tailscale IP for remote access; fall back to 0.0.0.0
  TS_IP="0.0.0.0"
  if command -v tailscale >/dev/null 2>&1; then
    TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "${TS_IP:-}" ]; then
    TS_IP="0.0.0.0"
  fi

  # Build MCP server entries from config
  mcp_servers="$(jq -r --arg ts_ip "$TS_IP" '
    .mcp as $mcp | .services as $services |
    [
      ($mcp | to_entries[] | {
        key: .key,
        value: {
          type: "http",
          url: ("http://" + $ts_ip + ":" + ($services[.value.port] | tostring) + .value.path)
        }
      }),
      {
        key: "chrome-devtools",
        value: {
          command: "npx",
          args: ["-y", "chrome-devtools-mcp@latest", "--headless", "--chromeArg=--no-sandbox", "--chromeArg=--disable-setuid-sandbox"]
        }
      }
    ] | from_entries
  ' "$ports_config")"

  # Apply worktree port offsets to the URLs
  mcp_json="$(echo "$mcp_servers" | jq --argjson idx "$worktree_index" --argjson step "$step" '
    to_entries | map(
      if .value.type == "http" then
        .value.url |= (
          capture("^(?<prefix>http://[^:]+:)(?<port>[0-9]+)(?<suffix>.*)$") |
          .prefix + ((.port | tonumber) + ($idx * $step) | tostring) + .suffix
        )
      else . end
    ) | from_entries
  ')"

  printf '{\n  "mcpServers": %s\n}\n' "$(echo "$mcp_json" | jq -M '.')" > "${worktree_dir}/.mcp.json"
  echo "[worktree-create] Generated .mcp.json for $project_name" >&2
fi

if [ -n "$post_script" ]; then
  if [[ "$post_script" = /* ]]; then
    post_script_path="$post_script"
  else
    post_script_path="${worktree_dir}/${post_script}"
  fi

  if [ ! -f "$post_script_path" ]; then
    echo "[worktree-create] post_create script not found: $post_script_path" >&2
    exit 1
  fi

  (
    cd "$worktree_dir"
    set -a
    # shellcheck source=/dev/null
    source "$worktree_env"
    set +a
    export WORKTREE_ENV_FILE="$worktree_env"
    export WORKTREE_PORTS_CONFIG="$ports_config"
    bash "$post_script_path"
  )
fi

# Allow direnv for worktree .envrc (created by post_create or copied from main)
if [ -f "${worktree_dir}/.envrc" ] && command -v direnv >/dev/null 2>&1; then
  direnv allow "$worktree_dir" >&2 || true
fi

preview_register_script="${WORKSPACE_ROOT}/.runtime/tailnet-ingress/preview-register.sh"
if [ -x "$preview_register_script" ] && [ -f "$ports_config" ]; then
  if jq -e '.preview // empty | if length > 0 then true else false end' "$ports_config" >/dev/null 2>&1; then
    if ! "$preview_register_script" "$worktree_dir" >&2; then
      echo "[worktree-create] WARNING: preview registration failed for $worktree_dir" >&2
    fi
  fi
fi

# Install lefthook if config exists
if [ -f "${worktree_dir}/lefthook.yml" ]; then
  if command -v lefthook &>/dev/null; then
    (cd "$worktree_dir" && lefthook install) >&2
  else
    echo "[worktree-create] WARNING: lefthook.yml found but lefthook not installed. Run: go install github.com/evilmartians/lefthook@latest" >&2
  fi
fi

for relative_path in "${allow_skip_worktree[@]}"; do
  [ -z "$relative_path" ] && continue
  if [[ "$relative_path" = /* ]] || [[ "$relative_path" == *".."* ]]; then
    echo "[worktree-create] Ignoring unsafe allow_skip_worktree path: $relative_path" >&2
    continue
  fi

  if git -C "$worktree_dir" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1; then
    git -C "$worktree_dir" update-index --skip-worktree -- "$relative_path" >/dev/null 2>&1 || true
  fi
done

tracked_changes="$(
  git -C "$worktree_dir" status --porcelain \
    | awk '$1 != "??" { print }'
)"
if [ -n "$tracked_changes" ]; then
  echo "[worktree-create] Tracked changes detected after worktree setup:" >&2
  echo "$tracked_changes" >&2
  echo "[worktree-create] Add paths to post_create.allow_skip_worktree or stop mutating tracked files." >&2
  exit 1
fi

# Make bare `git push` auto-create upstream tracking on first push
git -C "$worktree_dir" config push.autoSetupRemote true

echo "$worktree_dir"
