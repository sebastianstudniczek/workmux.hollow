-- hollow-workmux.agents
-- Where the sidebar's data comes from: commands run in the workmux domain
-- (WSL), hollow's live mux tree, workmux's agent state files, each agent's
-- status, per-worktree git stats and each branch's pull request.

local hollow = _G.hollow
local unpack = table.unpack or unpack

local core = require("hollow-workmux.core")
local C = core.C
local S = core.S
local SPINNER_FRAMES = core.SPINNER_FRAMES
local cfg = core.cfg
local config_get = core.config_get
local glyph = core.glyph
local pane_num = core.pane_num
local redraw = core.redraw
local warn_once = core.warn_once

-- ── Status & staleness ────────────────────────────────────────────────────────

-- Waiting/done clear once the user has looked at the pane, like the tmux
-- backend's pane-focus-in hook (snapshot.rs suppresses the status then).
local function effective_status(agent)
	local status = agent.status
	if (status == "waiting" or status == "done") and S.acked[agent.pane_id] == agent.status_ts then
		return nil
	end
	return status
end

local function activity_ts(agent)
	return agent.activity_ts or agent.status_ts or (agent.status == nil and agent.updated_ts) or nil
end

-- context.rs is_stale
local function is_stale(agent, now)
	if not cfg.dim_stale then
		return false
	end
	if S.sleeping[agent.pane_id] then
		return true
	end
	local status = effective_status(agent)
	if status == "working" or status == "waiting" then
		return false
	end
	local ts = activity_ts(agent)
	return not ts or (now - ts) > cfg.stale_after
end

local function status_color(status)
	if status == "working" then
		return C.info
	elseif status == "waiting" then
		return C.accent
	elseif status == "done" then
		return C.success
	end
	return C.dimmed
end

local function status_icon(agent, stale)
	if stale then
		return glyph("stale"), C.dimmed
	end
	local status = effective_status(agent)
	if status == "working" then
		return cfg.status_icons.working or SPINNER_FRAMES[S.spinner_frame], C.info
	elseif status == "waiting" or status == "done" then
		return glyph(status), status_color(status)
	end
	-- Nothing to report: blank, matching the tmux sidebar. Set
	-- `status_icons.idle` to keep a marker in the column instead.
	return cfg.status_icons.idle or "  ", C.dimmed
end

-- ── Processes (async, inside the workmux domain) ─────────────────────────────

-- The argv prefix that runs a command inside the configured domain.
local function domain_prefix()
	local name = cfg.domain or config_get("default_domain")
	local domains = config_get("domains") or {}
	local domain = type(name) == "string" and domains[name] or nil
	local distro = domain and domain.wsl_distro
	if not distro and domain and type(domain.shell) == "string" then
		distro = domain.shell:match("wsl%.exe%s+%-d%s+(%S+)") or domain.shell:match("^wsl%s+%-d%s+(%S+)")
	end
	if distro then
		return { "wsl.exe", "-d", distro, "--exec" }
	end
	local platform = hollow.platform or {}
	if platform.is_windows then
		return { "wsl.exe", "--exec" }
	end
	return {}
end

-- Run `bash -c script _ args…` and call on_done(stdout) or on_done(nil).
local function run_bash(script, args, on_done, timeout_ms)
	local argv = domain_prefix()
	argv[#argv + 1] = "bash"
	argv[#argv + 1] = "-c"
	argv[#argv + 1] = script
	argv[#argv + 1] = "hollow-workmux"
	for _, arg in ipairs(args or {}) do
		argv[#argv + 1] = arg
	end

	if not (hollow.process and hollow.process.spawn) then
		-- older hollow: synchronous fallback
		local ok, ran, stdout = pcall(hollow.term.run_domain_process, { "bash", "-c", script, "hollow-workmux", unpack(args or {}) }, cfg.domain)
		on_done(ok and ran and tostring(stdout or "") or nil)
		return
	end

	local ok, err = pcall(hollow.process.spawn, {
		cmd = argv,
		timeout_ms = timeout_ms or cfg.process_timeout_ms,
		on_complete = function(result)
			if result.error then
				hollow.log("[hollow-workmux] process failed: " .. tostring(result.error) .. " " .. tostring(result.stderr))
				on_done(nil)
				return
			end
			on_done(tostring(result.stdout or ""))
		end,
	})
	if not ok then
		hollow.log("[hollow-workmux] spawn failed: " .. tostring(err))
		on_done(nil)
	end
end

-- ── Hollow mux tree ───────────────────────────────────────────────────────────

local function refresh_panes()
	local ok, tree = pcall(hollow.term.mux_tree)
	if not ok or type(tree) ~= "table" then
		return
	end
	local map = {}
	S.focused_pane_id, S.current_tab_id, S.current_ws_index = nil, nil, nil
	for _, ws in ipairs(tree) do
		for _, tab in ipairs(ws.tabs or {}) do
			for _, pane in ipairs(tab.panes or {}) do
				local id = tostring(pane.id)
				map[id] = { pane = pane, tab = tab, workspace = ws }
				if ws.is_active and tab.is_active and pane.is_focused then
					S.focused_pane_id = id
				end
			end
			if ws.is_active and tab.is_active then
				S.current_tab_id = tab.id
			end
		end
		if ws.is_active then
			S.current_ws_index = ws.index
		end
	end
	if not S.focused_pane_id then
		local cur_ok, cur = pcall(hollow.term.current_pane)
		S.focused_pane_id = cur_ok and cur and tostring(cur.id) or nil
	end
	S.panes = map
end

-- Mark the focused pane's waiting/done status as seen.
local function ack_focused()
	if not S.focused_pane_id then
		return
	end
	for _, agent in ipairs(S.all_agents) do
		if agent.pane_id == S.focused_pane_id and (agent.status == "waiting" or agent.status == "done") then
			S.acked[agent.pane_id] = agent.status_ts
		end
	end
end

-- ── Agent list ────────────────────────────────────────────────────────────────

-- One WSL call reads every hollow agent state file, one compact JSON object
-- per line, so one corrupt/half-written file can't break the batch. The
-- trailing marker tells a real empty listing apart from a failed call.
local AGENTS_SCRIPT = [[
command -v jq >/dev/null 2>&1 || { echo __WORKMUX_NO_JQ__; exit 0; }
dir="${XDG_STATE_HOME:-$HOME/.local/state}/workmux/agents"
for f in "$dir"/hollow__*.json; do
  [ -f "$f" ] || continue
  jq -c '{
    pane_id: ((.pane_key.pane_id // "") | tostring),
    instance: (.pane_key.instance // ""),
    workdir: (.workdir // ""),
    status: .status,
    status_ts: .status_ts,
    activity_ts: .activity_ts,
    updated_ts: .updated_ts,
    pane_title: .pane_title,
    window_name: .window_name,
    session_name: .session_name,
    agent_kind: .agent_kind,
    command: .command
  }' "$f" 2>/dev/null
done
echo __WORKMUX_OK__
]]

local function sort_agents(list, now)
	if cfg.sort == "window" then
		table.sort(list, function(a, b)
			local sa, sb = a.session or "", b.session or ""
			if sa ~= sb then
				return sa < sb
			end
			local ta, tb = a.tab_index or math.huge, b.tab_index or math.huge
			if ta ~= tb then
				return ta < tb
			end
			return pane_num(a.pane_id) < pane_num(b.pane_id)
		end)
		return
	end
	-- snapshot.rs: sleeping last, most recent activity first, then pane number
	table.sort(list, function(a, b)
		local za, zb = S.sleeping[a.pane_id] and 1 or 0, S.sleeping[b.pane_id] and 1 or 0
		if za ~= zb then
			return za < zb
		end
		local ta, tb = activity_ts(a), activity_ts(b)
		local da, db = ta and (now - ta) or math.huge, tb and (now - tb) or math.huge
		if da ~= db then
			return da < db
		end
		return pane_num(a.pane_id) < pane_num(b.pane_id)
	end)
end

-- Rebuild the visible list from all_agents: live pane data, filter, sort,
-- per-tab suffixes, and the selection.
local function rebuild()
	local now = os.time()
	local list = {}
	for _, agent in ipairs(S.all_agents) do
		local live = S.panes[agent.pane_id]
		if live then
			agent.live_pane = live.pane
			agent.tab_id = live.tab.id
			agent.tab_index = live.tab.index
			agent.ws_index = live.workspace.index
			agent.session = live.workspace.name or agent.session_name
			if cfg.filter ~= "workspace" or live.workspace.index == S.current_ws_index then
				list[#list + 1] = agent
			end
		end
	end
	sort_agents(list, now)

	-- "(1)", "(2)" … when a tab holds several agents (ui.rs pane_suffix)
	local per_tab, seen = {}, {}
	for _, agent in ipairs(list) do
		per_tab[agent.tab_id] = (per_tab[agent.tab_id] or 0) + 1
	end
	for _, agent in ipairs(list) do
		if per_tab[agent.tab_id] > 1 then
			seen[agent.tab_id] = (seen[agent.tab_id] or 0) + 1
			agent.pane_suffix = "(" .. seen[agent.tab_id] .. ")"
		else
			agent.pane_suffix = ""
		end
	end
	S.agents = list
end

-- The agent in the user's focus: the focused pane, else the first agent in
-- the current tab (app.rs host_agent_idx, with hollow's tab as the window).
local function host_index()
	local first_in_tab
	for i, agent in ipairs(S.agents) do
		if agent.pane_id == S.focused_pane_id then
			return i
		end
		if not first_in_tab and S.current_tab_id and agent.tab_id == S.current_tab_id then
			first_in_tab = i
		end
	end
	return first_in_tab
end

local function selected_index()
	-- the selection follows the focused agent (app.rs FollowHost); jumps
	-- move focus, so there is no separate manual mode to fall back from
	local host = host_index()
	if host then
		S.selected_pane = S.agents[host].pane_id
		return host
	end
	for i, agent in ipairs(S.agents) do
		if agent.pane_id == S.selected_pane then
			return i
		end
	end
	if #S.agents > 0 then
		S.selected_pane = S.agents[1].pane_id
		return 1
	end
	return nil
end

local function apply_agents(stdout)
	if stdout:find("__WORKMUX_NO_JQ__", 1, true) then
		warn_once("jq", "`jq` is not installed in the workmux domain; install it to see agents")
	end
	if not stdout:find("__WORKMUX_OK__", 1, true) then
		return false -- the WSL call itself failed; keep the previous list
	end

	refresh_panes()

	-- A file per (instance, pane); keep one per live pane, preferring this
	-- hollow instance and then the most recently updated file.
	local by_pane = {}
	for line in stdout:gmatch("[^\r\n]+") do
		if line:match("^%s*{") then
			local ok, data = pcall(hollow.json.decode, line)
			if ok and type(data) == "table" and data.pane_id and data.pane_id ~= "" and S.panes[data.pane_id] then
				local prev = by_pane[data.pane_id]
				local mine = S.own_instance and data.instance == S.own_instance
				local prev_mine = prev and S.own_instance and prev.instance == S.own_instance
				if
					not prev
					or (mine and not prev_mine)
					or (mine == prev_mine and (data.updated_ts or 0) > (prev.updated_ts or 0))
				then
					by_pane[data.pane_id] = data
				end
			end
		end
	end

	local list = {}
	for _, agent in pairs(by_pane) do
		list[#list + 1] = agent
	end
	S.all_agents = list
	S.loaded = true
	ack_focused()
	rebuild()
	return true
end

local function load_agents()
	if S.agents_busy then
		S.reload_pending = true
		return
	end
	S.agents_busy = true
	S.last_load = os.time()
	run_bash(AGENTS_SCRIPT, nil, function(stdout)
		S.agents_busy = false
		if stdout and apply_agents(stdout) then
			redraw()
		end
		if S.reload_pending then
			S.reload_pending = false
			load_agents()
		end
	end)
end

-- ── Git stats ─────────────────────────────────────────────────────────────────

-- Every worktree in ONE call, one JSON line each: branch, dirty, rebase,
-- repository name, committed diff vs the base branch (branch.<b>.workmux-base,
-- then origin/HEAD, then main/master) and uncommitted diff vs HEAD including
-- untracked lines (git/status.rs).
local GIT_SCRIPT = [[
limit="$1"; shift
command -v jq >/dev/null 2>&1 || exit 0
for dir in "$@"; do
(
  cd "$dir" 2>/dev/null || exit 0
  status_out=$(git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null) || exit 0
  branch=$(printf '%s\n' "$status_out" | sed -n 's/^# branch\.head //p')
  [ "$branch" = "(detached)" ] && branch=""
  dirty=false
  printf '%s\n' "$status_out" | grep -qv '^#' && dirty=true

  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$common" in
    */.git) project=$(basename "$(dirname "$common")") ;;
    *) project=$(basename "${common%.git}") ;;
  esac

  rebasing=false
  for p in rebase-merge rebase-apply; do
    d=$(git rev-parse --git-path "$p" 2>/dev/null)
    [ -n "$d" ] && [ -d "$d" ] && rebasing=true
  done

  added=0; removed=0
  if [ -n "$branch" ]; then
    base=$(git config --local --get "branch.$branch.workmux-base" 2>/dev/null)
    if [ -z "$base" ]; then
      head_ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
      base=${head_ref#refs/remotes/origin/}
      [ "$base" = "$head_ref" ] && base=""
    fi
    if [ -z "$base" ]; then
      for candidate in main master; do
        if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then base="$candidate"; break; fi
      done
    fi
    [ -z "$base" ] && base="main"
    if [ "$branch" != "$base" ]; then
      read -r added removed <<EOF
$(git diff --no-ext-diff --no-textconv --numstat "$base...HEAD" 2>/dev/null | awk '{a+=$1; r+=$2} END{print a+0, r+0}')
EOF
    fi
  fi

  read -r uadded uremoved <<EOF
$(git diff --no-ext-diff --no-textconv --numstat HEAD 2>/dev/null | awk '{a+=$1; r+=$2} END{print a+0, r+0}')
EOF
  if [ "$limit" -gt 0 ]; then
    untracked=$(git ls-files -z --others --exclude-standard 2>/dev/null | xargs -0 -r cat 2>/dev/null | head -c "$limit" | wc -l)
    uadded=$((uadded + untracked))
  fi

  jq -nc --arg dir "$dir" --arg branch "$branch" --arg project "$project" \
    --argjson dirty "$dirty" --argjson rebasing "$rebasing" \
    --argjson added "${added:-0}" --argjson removed "${removed:-0}" \
    --argjson uadded "${uadded:-0}" --argjson uremoved "${uremoved:-0}" \
    '{dir:$dir, branch:(if $branch == "" then null else $branch end), project:$project,
      dirty:$dirty, rebasing:$rebasing, added:$added, removed:$removed,
      uncommitted_added:$uadded, uncommitted_removed:$uremoved}'
)
done
echo __WORKMUX_OK__
]]

local function refresh_git()
	if not cfg.git or S.git_busy then
		return
	end
	local dirs, seen = {}, {}
	for _, agent in ipairs(S.all_agents) do
		local dir = agent.workdir
		if dir and dir ~= "" and not seen[dir] then
			seen[dir] = true
			dirs[#dirs + 1] = dir
		end
	end
	S.last_git = os.time()
	if #dirs == 0 then
		return
	end

	S.git_busy = true
	local args = { tostring(cfg.untracked and cfg.untracked_byte_limit or 0) }
	for _, dir in ipairs(dirs) do
		args[#args + 1] = dir
	end
	run_bash(GIT_SCRIPT, args, function(stdout)
		S.git_busy = false
		if not stdout or not stdout:find("__WORKMUX_OK__", 1, true) then
			return
		end
		local fresh = {}
		for line in stdout:gmatch("[^\r\n]+") do
			if line:match("^%s*{") then
				local ok, data = pcall(hollow.json.decode, line)
				if ok and type(data) == "table" and data.dir then
					fresh[data.dir] = data
				end
			end
		end
		S.git_cache = fresh
		redraw()
	end)
end

-- ── Pull requests ─────────────────────────────────────────────────────────────

-- The pull request for each worktree's checked-out branch, with its checks
-- summarised the way workmux does (github.rs): one JSON line per directory.
-- Directories whose `gh` call failed print nothing, so the last known answer
-- stays on screen; main/master get an explicit null, since they have no PR.
local PR_SCRIPT = [=[
gh_bin="$1"; timeout_s="$2"; shift 2
command -v jq >/dev/null 2>&1 || exit 0

# `gh` is usually installed by Homebrew, whose bin directory only an interactive
# shell adds to PATH, so look in the usual places when it isn't on PATH.
if [ -z "$gh_bin" ]; then
  gh_bin=$(command -v gh 2>/dev/null)
fi
if [ -z "$gh_bin" ]; then
  for p in /home/linuxbrew/.linuxbrew/bin/gh "$HOME/.linuxbrew/bin/gh" /opt/homebrew/bin/gh /usr/local/bin/gh; do
    if [ -x "$p" ]; then gh_bin=$p; break; fi
  done
fi
if [ -z "$gh_bin" ] || [ ! -x "$gh_bin" ]; then
  echo __WORKMUX_NO_GH__
  exit 0
fi

errf=$(mktemp 2>/dev/null) || errf=""
for dir in "$@"; do
(
  cd "$dir" 2>/dev/null || exit 0
  branch=$(git --no-optional-locks symbolic-ref --quiet --short HEAD 2>/dev/null)
  case "$branch" in
    ""|main|master)
      # nothing to look up; say so explicitly so a stale entry gets cleared
      jq -nc --arg dir "$dir" '{dir:$dir, branch:null, pr:null}'
      exit 0 ;;
  esac

  # A failed lookup (offline, rate limited, not a GitHub repo) prints nothing
  # for this directory, so the previous answer stays on screen.
  out=$(timeout "$timeout_s" "$gh_bin" pr list --head "$branch" --state all --limit 20 \
    --json number,state,isDraft,url,statusCheckRollup 2>"${errf:-/dev/null}") || {
    if [ -n "$errf" ] && grep -qiE 'gh auth login|not logged in|authentication' "$errf" 2>/dev/null; then
      echo __WORKMUX_GH_NOAUTH__
    fi
    exit 0
  }

  # Check aggregation mirrors workmux's github.rs aggregate_checks: a CheckRun
  # reports status/conclusion, a StatusContext reports state; skipped and
  # neutral checks don't count towards the total.
  printf '%s' "$out" | jq -c --arg dir "$dir" --arg branch "$branch" '
    def kind:
      (.status // .state // "") as $s | (.conclusion // "") as $c
      | if $c == "SUCCESS" or $s == "SUCCESS" then "passed"
        elif ($c | IN("FAILURE","CANCELLED","TIMED_OUT","STARTUP_FAILURE","ACTION_REQUIRED"))
             or ($s | IN("FAILURE","ERROR")) then "failed"
        elif ($c | IN("NEUTRAL","SKIPPED")) then "skipped"
        elif ($s | IN("IN_PROGRESS","QUEUED","PENDING","REQUESTED","WAITING")) then "pending"
        else "other" end;
    def rollup:
      ((.statusCheckRollup // []) | map(kind)) as $k
      | ([$k[] | select(. == "passed")] | length) as $p
      | ([$k[] | select(. == "failed")] | length) as $f
      | ([$k[] | select(. == "pending")] | length) as $q
      | ([$k[] | select(. == "skipped")] | length) as $sk
      | ($p + $f + $q) as $t
      | if ($k | length) == 0 then null
        elif $t == 0 then (if $sk > 0 then {state: "success"} else null end)
        elif $f > 0 then {state: "failure", passed: $p, total: $t}
        elif $q > 0 then {state: "pending", passed: $p, total: $t}
        else {state: "success"} end;
    # an open PR beats a closed or merged one; otherwise the newest wins
    (sort_by([(.state != "OPEN"), -.number]) | .[0]) as $pr
    | {dir: $dir, branch: $branch,
       pr: (if $pr == null then null
            else {number: $pr.number, state: $pr.state, draft: $pr.isDraft,
                  url: $pr.url, checks: ($pr | rollup)} end)}'
)
done
if [ -n "$errf" ]; then rm -f "$errf"; fi
echo __WORKMUX_OK__
]=]

local function refresh_prs()
	if not cfg.pr or S.pr_busy then
		return
	end
	local dirs, seen = {}, {}
	for _, agent in ipairs(S.all_agents) do
		local dir = agent.workdir
		if dir and dir ~= "" and not seen[dir] then
			seen[dir] = true
			dirs[#dirs + 1] = dir
		end
	end
	if #dirs == 0 then
		return
	end

	S.last_pr = os.time()
	S.pr_busy = true
	local args = { cfg.gh or "", tostring(cfg.pr_gh_timeout_secs) }
	for _, dir in ipairs(dirs) do
		args[#args + 1] = dir
	end
	run_bash(PR_SCRIPT, args, function(stdout)
		S.pr_busy = false
		if not stdout then
			return
		end
		if stdout:find("__WORKMUX_NO_GH__", 1, true) then
			warn_once("gh", "the GitHub CLI (`gh`) was not found in the workmux domain; set `gh = \"/path/to/gh\"` or `pr = false`")
			return
		end
		if stdout:find("__WORKMUX_GH_NOAUTH__", 1, true) then
			warn_once("gh_auth", "`gh` is not logged in inside the workmux domain; run `gh auth login`")
		end
		if not stdout:find("__WORKMUX_OK__", 1, true) then
			return
		end

		local fresh = {}
		for line in stdout:gmatch("[^\r\n]+") do
			if line:match("^%s*{") then
				local ok, data = pcall(hollow.json.decode, line)
				if ok and type(data) == "table" and data.dir then
					fresh[data.dir] = data
				end
			end
		end
		local merged = {}
		for _, dir in ipairs(dirs) do
			merged[dir] = fresh[dir] or S.pr_cache[dir]
		end
		S.pr_cache = merged
		redraw()
	end, cfg.pr_timeout_ms)
end

return {
	ack_focused = ack_focused,
	effective_status = effective_status,
	host_index = host_index,
	is_stale = is_stale,
	load_agents = load_agents,
	rebuild = rebuild,
	refresh_git = refresh_git,
	refresh_panes = refresh_panes,
	refresh_prs = refresh_prs,
	selected_index = selected_index,
	status_color = status_color,
	status_icon = status_icon,
}
