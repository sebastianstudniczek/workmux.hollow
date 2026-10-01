-- hollow-workmux.config: default options. Mutated in place by setup(); every module shares this table.

local cfg = {
	width = 34,
	side = "left",
	domain = nil,
	layout = "tiles",
	sort = "recency",
	filter = "all",
	dim_stale = true,
	stale_after = 3600, -- hard-coded in workmux too
	window_prefix = "wm-",
	nerdfont = false,
	status_icons = {},
	git = true,
	git_refresh_secs = 5,
	untracked = true,
	untracked_byte_limit = 1024 * 1024,
	reload_secs = 2,
	height = nil,
	chrome_rows = 3, -- rows of the window not available to the sidebar
	colors = {},
	keys = true,
	process_timeout_ms = 15000,
}

return cfg
