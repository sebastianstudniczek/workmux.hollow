-- hollow-workmux.agents: the agent list: read from workmux's state files, merged with the live mux
-- tree, filtered, sorted and numbered.

local hollow = _G.hollow

local cfg = require("hollow-workmux.config")
local S = require("hollow-workmux.state")
local run_bash = require("hollow-workmux.process").run_bash
local activity_ts = require("hollow-workmux.status").activity_ts
local tree = require("hollow-workmux.tree")
local ack_focused, refresh_panes = tree.ack_focused, tree.refresh_panes
local util = require("hollow-workmux.util")
local pane_num, redraw, warn_once = util.pane_num, util.redraw, util.warn_once

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

return {
	host_index = host_index,
	load_agents = load_agents,
	rebuild = rebuild,
	selected_index = selected_index,
}
