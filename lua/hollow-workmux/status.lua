-- hollow-workmux.status: an agent's effective status, staleness, and the icon/colour that shows it.

local cfg = require("hollow-workmux.config")
local S = require("hollow-workmux.state")
local glyphs = require("hollow-workmux.glyphs")
local SPINNER_FRAMES, glyph = glyphs.SPINNER_FRAMES, glyphs.glyph
local C = require("hollow-workmux.palette").C

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

return {
	activity_ts = activity_ts,
	effective_status = effective_status,
	is_stale = is_stale,
	status_color = status_color,
	status_icon = status_icon,
}
