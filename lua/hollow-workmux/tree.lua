-- hollow-workmux.tree: hollow's live layout: which pane lives in which tab/workspace, and focus.

local hollow = _G.hollow

local S = require("hollow-workmux.state")

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

return {
	ack_focused = ack_focused,
	refresh_panes = refresh_panes,
}
