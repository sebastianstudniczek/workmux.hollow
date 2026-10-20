-- hollow-workmux.actions
-- Keeping the sidebar current and reacting to input: the refresh loop,
-- moving between agents, the toggles, and hollow/HTP events. The `M` table
-- here is the plugin's public API; init.lua adds setup() to it.

local hollow = _G.hollow
local ui = hollow.ui

local agents = require("hollow-workmux.agents")
local ack_focused = agents.ack_focused
local effective_status = agents.effective_status
local load_agents = agents.load_agents
local rebuild = agents.rebuild
local refresh_git = agents.refresh_git
local refresh_panes = agents.refresh_panes
local refresh_prs = agents.refresh_prs
local selected_index = agents.selected_index
local core = require("hollow-workmux.core")
local S, SPINNER_FRAMES, cfg, redraw = core.S, core.SPINNER_FRAMES, core.cfg, core.redraw

local M = {}

-- ── Scheduling ────────────────────────────────────────────────────────────────

local function needs_fast_tick()
	if not S.loaded then
		return true
	end
	-- a pending check run shows a spinner too
	if cfg.pr then
		for _, entry in pairs(S.pr_cache) do
			local pr = entry.pr
			if pr and pr.checks and pr.checks.state == "pending" then
				return true
			end
		end
	end
	if cfg.status_icons.working then
		return false
	end
	for _, agent in ipairs(S.agents) do
		if effective_status(agent) == "working" then
			return true
		end
	end
	return false
end

local tick

-- 250 ms while something animates, 1 s otherwise (elapsed times still move).
tick = function()
	if not S.ticking then
		return
	end
	local now = os.time()
	local fast = needs_fast_tick()
	S.spinner_frame = S.spinner_frame % #SPINNER_FRAMES + 1

	if now - S.last_load >= cfg.reload_secs then
		load_agents()
	end
	if cfg.git and now - S.last_git >= cfg.git_refresh_secs then
		refresh_git()
	end
	if cfg.pr and now - S.last_pr >= cfg.pr_refresh_secs then
		refresh_prs()
	end
	redraw()
	pcall(hollow.defer, tick, fast and 250 or 1000)
end

-- Coalesce bursts of refresh requests (a status change writes the state file
-- and emits within a few ms).
local reload_scheduled = false

local function schedule_reload(delay_ms)
	if reload_scheduled then
		return
	end
	reload_scheduled = true
	pcall(hollow.defer, function()
		reload_scheduled = false
		load_agents()
	end, delay_ms or 100)
end

-- ── Navigation ────────────────────────────────────────────────────────────────

local function jump_to(agent)
	if not agent then
		return
	end
	S.selected_pane = agent.pane_id
	local id = tonumber(agent.pane_id)
	if id then
		pcall(hollow.term.focus_pane_by_id, id)
	end
	schedule_reload(50)
end

local function current_index()
	for i, agent in ipairs(S.agents) do
		if agent.pane_id == S.focused_pane_id then
			return i
		end
	end
	return selected_index()
end

function M.next()
	if #S.agents == 0 then
		return
	end
	local i = current_index() or #S.agents
	jump_to(S.agents[i % #S.agents + 1])
end

function M.prev()
	if #S.agents == 0 then
		return
	end
	local i = current_index() or 1
	jump_to(S.agents[(i - 2) % #S.agents + 1])
end

function M.jump(n)
	jump_to(S.agents[n])
end

---@return boolean focused
function M.focus_pane(pane_id)
	local id = tonumber(pane_id)
	return id ~= nil and (pcall(hollow.term.focus_pane_by_id, id))
end

function M.toggle_layout()
	cfg.layout = cfg.layout == "compact" and "tiles" or "compact"
	redraw()
end

function M.toggle_filter()
	cfg.filter = cfg.filter == "workspace" and "all" or "workspace"
	rebuild()
	redraw()
end

function M.toggle_sleep()
	local i = selected_index()
	local agent = i and S.agents[i]
	if not agent then
		return
	end
	S.sleeping[agent.pane_id] = not S.sleeping[agent.pane_id] or nil
	rebuild()
	redraw()
end

--- Reload agent state and refresh git stats and pull requests now.
function M.refresh()
	load_agents()
	S.last_git = 0
	refresh_git()
	S.last_pr = 0
	refresh_prs()
	redraw()
end

-- ── Events ────────────────────────────────────────────────────────────────────

local FOCUS_EVENTS = {
	["workspace:changed"] = true,
	["workspace:new"] = true,
	["workspace:closed"] = true,
	["term:pane_focused"] = true,
	["term:tab_activated"] = true,
	["term:tab_closed"] = true,
	["term:title_changed"] = true,
	["term:pane_layout_changed"] = true,
}

local function on_widget_event(name)
	if not FOCUS_EVENTS[name] then
		return
	end
	local previous_focus = S.focused_pane_id
	refresh_panes()
	if S.focused_pane_id ~= previous_focus then
		ack_focused()
	end
	rebuild()
	redraw()
end

local function on_htp_status()
	schedule_reload(100)
end

local function on_htp_sidebar(ctx)
	local p = type(ctx.payload) == "table" and ctx.payload or {}
	local action = p.action
	if action == "toggle" then
		ui.sidebar.toggle()
	elseif action == "show" then
		if S.sidebar_widget then
			ui.sidebar.mount(S.sidebar_widget)
		end
	elseif action == "hide" then
		ui.sidebar.unmount()
	elseif action == "refresh" then
		schedule_reload(50)
	elseif action == "layout" then
		M.toggle_layout()
	elseif action == "next" then
		M.next()
	elseif action == "prev" then
		M.prev()
	elseif action == "jump" then
		M.jump(tonumber(p.index) or 0)
	elseif action == "focus" then
		M.focus_pane(p.pane_id)
	end
	redraw()
end

return {
	M = M,
	on_htp_sidebar = on_htp_sidebar,
	on_htp_status = on_htp_status,
	on_widget_event = on_widget_event,
	tick = tick,
}
