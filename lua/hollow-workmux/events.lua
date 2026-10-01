-- hollow-workmux.events: reacting to hollow's focus events and to `hollow-cli emit` / HTP
-- traffic.

local hollow = _G.hollow
local ui = hollow.ui

local S = require("hollow-workmux.state")
-- the public actions (next, prev, jump, toggle_*) live on nav's table
local M = require("hollow-workmux.nav")
local rebuild = require("hollow-workmux.agents").rebuild
local schedule_reload = require("hollow-workmux.scheduler").schedule_reload
local tree = require("hollow-workmux.tree")
local ack_focused, refresh_panes = tree.ack_focused, tree.refresh_panes
local redraw = require("hollow-workmux.util").redraw

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
	on_htp_sidebar = on_htp_sidebar,
	on_htp_status = on_htp_status,
	on_widget_event = on_widget_event,
}
