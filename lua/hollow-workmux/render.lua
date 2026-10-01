-- hollow-workmux.render: turning the agent list into sidebar rows: tiles, compact rows, viewport.

local hollow = _G.hollow
local ui = hollow.ui

local cfg = require("hollow-workmux.config")
local S = require("hollow-workmux.state")
local agents = require("hollow-workmux.agents")
local host_index, selected_index = agents.host_index, agents.selected_index
local git_stats_frags = require("hollow-workmux.diffstat").git_stats_frags
local LOADING_FRAMES = require("hollow-workmux.glyphs").LOADING_FRAMES
local labels = require("hollow-workmux.labels")
local format_elapsed, project_from_path, resolve_labels, sanitize_title, shorten_path_label, worktree_name =
	labels.format_elapsed, labels.project_from_path, labels.resolve_labels, labels.sanitize_title, labels.shorten_path_label, labels.worktree_name
local layout_mod = require("hollow-workmux.layout")
local layout, to_row = layout_mod.layout, layout_mod.to_row
local palette = require("hollow-workmux.palette")
local C, D = palette.C, palette.D
local status = require("hollow-workmux.status")
local effective_status, is_stale, status_color, status_icon =
	status.effective_status, status.is_stale, status.status_color, status.status_icon
local util = require("hollow-workmux.util")
local dwidth, strip_prefix, trunc = util.dwidth, util.strip_prefix, util.trunc

-- Everything a row needs, computed once per render.
local function row_data(agent, index, now, host)
	local stale = is_stale(agent, now)
	local live = agent.live_pane or {}
	local stats = cfg.git and S.git_cache[agent.workdir] or nil

	local session = agent.session or agent.session_name or ""
	-- Hollow tabs track their active pane's title unless renamed (workmux
	-- renames the ones it creates), so only a renamed tab counts as a window.
	local tab = S.panes[agent.pane_id] and S.panes[agent.pane_id].tab
	local window = tab and tab.title or agent.window_name or ""
	local window_cmd = live.foreground_process or agent.command
	if window == (live.title or "") then
		window_cmd = nil
	end

	local worktree = worktree_name(session, window, agent.workdir)
	local project = (stats and stats.project and stats.project ~= "") and stats.project
		or project_from_path(agent.workdir)
	-- names carrying the window prefix already surfaced as the worktree
	local label_session = strip_prefix(session, cfg.window_prefix) and ""
		or shorten_path_label(session, project)
	local label_window = strip_prefix(window, cfg.window_prefix) and ""
		or shorten_path_label(window, project)
	local primary, secondary = resolve_labels(project, label_session, worktree, label_window, window_cmd)

	local title = sanitize_title(live.title ~= "" and live.title or agent.pane_title, {
		worktree,
		project,
		primary,
		secondary,
		os.getenv("HOSTNAME"),
	})

	local icon, icon_color = status_icon(agent, stale)
	return {
		agent = agent,
		stale = stale,
		selected = false,
		active = index == host,
		icon = icon,
		icon_color = icon_color,
		stripe = stale and C.dimmed or status_color(effective_status(agent)),
		primary = primary,
		secondary = secondary,
		title = title or "",
		suffix = agent.pane_suffix or "",
		elapsed = format_elapsed(agent.status_ts),
		stats = stats,
	}
end

local function primary_frag(d)
	if d.stale then
		return { d.primary, C.dimmed, flex = true }
	end
	if d.active then
		return { d.primary, C.current_worktree_fg, bold = true, flex = true }
	end
	return { d.primary, C.text, flex = true }
end

local function line1_frags(d, with_icon, icon_width)
	local left = {}
	if with_icon then
		local pad = math.max(0, icon_width - dwidth(d.icon))
		left[#left + 1] = { d.icon .. string.rep(" ", pad) .. " ", d.icon_color }
	end
	left[#left + 1] = primary_frag(d)
	if d.suffix ~= "" then
		left[#left + 1] = { " " .. d.suffix, C.dimmed }
	end
	local right = {}
	if d.elapsed ~= "" then
		right[1] = { " " .. d.elapsed, d.stale and C.dimmed or D.text }
	end
	return left, right
end

-- ▌ stripe + 2-column icon + gap, then the body, then a 1-column margin.
local function tile_rows(d, width)
	local bg = d.selected and C.highlight_row_bg or nil
	local body = math.max(1, width - 6)
	local rows = {}

	local function chrome(icon_text, icon_color, frags)
		local out = { { "▌ ", d.stripe } }
		out[#out + 1] = { icon_text, icon_color }
		out[#out + 1] = { " " }
		for _, f in ipairs(frags) do
			out[#out + 1] = f
		end
		out[#out + 1] = { " " }
		return to_row(out, bg)
	end

	local left, right = line1_frags(d, false)
	local icon = d.icon .. string.rep(" ", math.max(0, 2 - dwidth(d.icon)))
	rows[#rows + 1] = chrome(icon, d.icon_color, layout(left, right, body))

	local secondary = { { d.secondary, d.stale and C.dimmed or D.text, flex = true } }
	local stats = git_stats_frags(d.stats, d.stale, math.max(0, body - 1))
	if #stats > 0 then
		table.insert(stats, 1, { " " })
	end
	rows[#rows + 1] = chrome("  ", nil, layout(secondary, stats, body))

	rows[#rows + 1] = chrome("  ", nil, layout({ { d.title, C.dimmed, flex = true } }, {}, body))
	return rows
end

local function compact_row(d, width, icon_width)
	local bg = d.selected and C.highlight_row_bg or nil
	local left, right = line1_frags(d, true, icon_width)
	local frags = layout(left, right, math.max(1, width - 2))
	table.insert(frags, 1, { " " })
	frags[#frags + 1] = { " " }
	return to_row(frags, bg)
end

local function separator(width)
	return ui.row({ ui.span(string.rep("─", width), { fg = C.border }) })
end

-- Rows the sidebar can show: window height over the pane cell height.
local function visible_rows(ctx)
	if cfg.height then
		return cfg.height
	end
	local ok, pane = pcall(hollow.term.current_pane)
	local size = ok and pane and pane.size
	local win_h = ctx and ctx.size and ctx.size.height or 0
	if not size or not size.rows or size.rows <= 0 or not size.height or win_h <= 0 then
		return math.huge
	end
	local cell_h = size.height / size.rows
	return math.max(4, math.floor(win_h / cell_h) - cfg.chrome_rows)
end

local function centered(text, color, width, height)
	local rows = {}
	local pad_top = height ~= math.huge and math.max(0, math.floor((height - 1) / 2)) or 0
	for _ = 1, pad_top do
		rows[#rows + 1] = ui.row({ ui.span(" ") })
	end
	local pad = math.max(0, math.floor((width - dwidth(text)) / 2))
	rows[#rows + 1] = ui.row({ ui.span(string.rep(" ", pad) .. trunc(text, width), { fg = color }) })
	return ui.column(rows)
end

local function render(ctx)
	local width = cfg.width
	local height = visible_rows(ctx)
	local now = os.time()

	if not S.loaded then
		return centered(LOADING_FRAMES[(S.spinner_frame - 1) % #LOADING_FRAMES + 1] .. " Loading", C.dimmed, width, height)
	end
	if #S.agents == 0 then
		return centered("No agents running", C.dimmed, width, height)
	end

	local host = host_index()
	local sel = selected_index()
	local data = {}
	local icon_width = 0
	for i, agent in ipairs(S.agents) do
		local d = row_data(agent, i, now, host)
		d.selected = i == sel
		data[i] = d
		icon_width = math.max(icon_width, dwidth(d.icon))
	end

	-- block heights: a tile is 3 lines + its top separator (+ the closing one)
	local tiles = cfg.layout ~= "compact"
	local function block_height(i)
		if not tiles then
			return 1
		end
		return 3 + (i > 1 and 1 or 0) + (i == #data and 1 or 0)
	end

	-- viewport (ui.rs tile_viewport): keep the selection fully visible,
	-- fill downward, reserve a row for "↓ N more" when tiles remain below
	S.scroll_offset = math.max(0, math.min(S.scroll_offset, #data - 1))
	if sel and sel <= S.scroll_offset then
		S.scroll_offset = sel - 1
	end
	local function fits_from(offset)
		local used, last = 0, offset
		for i = offset + 1, #data do
			local h = block_height(i)
			local footer = i < #data and 1 or 0
			if used + h + footer > height and i > offset + 1 then
				break
			end
			used = used + h
			last = i
		end
		return last
	end
	while sel and fits_from(S.scroll_offset) < sel and S.scroll_offset < sel - 1 do
		S.scroll_offset = S.scroll_offset + 1
	end
	local last = fits_from(S.scroll_offset)

	local rows = {}
	for i = S.scroll_offset + 1, last do
		local d = data[i]
		if tiles then
			if i > 1 then
				rows[#rows + 1] = separator(width)
			end
			for _, row in ipairs(tile_rows(d, width)) do
				rows[#rows + 1] = row
			end
			if i == #data then
				rows[#rows + 1] = separator(width)
			end
		else
			rows[#rows + 1] = compact_row(d, width, icon_width)
		end
	end
	if last < #data then
		rows[#rows + 1] = ui.row({ ui.span(" ↓ " .. (#data - last) .. " more", { fg = C.dimmed }) })
	end
	return ui.column(rows)
end

return {
	render = render,
}
