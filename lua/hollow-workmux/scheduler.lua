-- hollow-workmux.scheduler: the refresh loop and coalesced reloads.

local hollow = _G.hollow

local cfg = require("hollow-workmux.config")
local S = require("hollow-workmux.state")
local load_agents = require("hollow-workmux.agents").load_agents
local refresh_git = require("hollow-workmux.git").refresh_git
local SPINNER_FRAMES = require("hollow-workmux.glyphs").SPINNER_FRAMES
local effective_status = require("hollow-workmux.status").effective_status
local redraw = require("hollow-workmux.util").redraw

local function needs_fast_tick()
	if not S.loaded then
		return true
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

return {
	schedule_reload = schedule_reload,
	tick = tick,
}
