-- hollow-workmux.nav: moving between agents and toggling sidebar modes. This module's table is
-- the plugin's public API; init.lua adds setup() to it.

local hollow = _G.hollow

local cfg = require("hollow-workmux.config")
local S = require("hollow-workmux.state")
local agents = require("hollow-workmux.agents")
local load_agents, rebuild, selected_index =
	agents.load_agents, agents.rebuild, agents.selected_index
local refresh_git = require("hollow-workmux.git").refresh_git
local schedule_reload = require("hollow-workmux.scheduler").schedule_reload
local redraw = require("hollow-workmux.util").redraw

local M = {}

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

--- Reload agent state and refresh git stats now.
function M.refresh()
	load_agents()
	S.last_git = 0
	refresh_git()
	redraw()
end

return M
