-- hollow-workmux.state: mutable state shared between modules. Fields are reassigned freely, so they live
-- on one table rather than as per-file locals.

local S = {
	agents = {}, -- sorted, filtered list shown in the sidebar
	all_agents = {}, -- every live agent, before the workspace filter
	loaded = false, -- first agent listing has arrived
	selected_pane = nil, -- pane_id of the selected row
	sleeping = {}, -- pane_id → true (toggled with <C-A-z>)
	acked = {}, -- pane_id → status_ts of a waiting/done status already seen
	git_cache = {}, -- workdir → stats
	panes = {}, -- pane_id → { pane, tab, workspace } from hollow's mux tree
	focused_pane_id = nil,
	current_tab_id = nil,
	current_ws_index = nil,
	scroll_offset = 0,
	spinner_frame = 1,
	last_load = 0,
	last_git = 0,
	agents_busy = false,
	git_busy = false,
	reload_pending = false,
	ticking = false,
	sidebar_widget = nil,
	own_instance = os.getenv("HOLLOW_COMMAND_ADDR"),
}

return S
