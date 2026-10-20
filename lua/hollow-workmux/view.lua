-- hollow-workmux.view
-- Turning the agent list into sidebar rows: fitting a line to a width, the
-- diff-stat ladder, pull request status, tiles, compact rows and the
-- scrolling viewport.

local hollow = _G.hollow
local ui = hollow.ui
local unpack = table.unpack or unpack

local agents = require("hollow-workmux.agents")
local effective_status = agents.effective_status
local host_index = agents.host_index
local is_stale = agents.is_stale
local selected_index = agents.selected_index
local status_color = agents.status_color
local status_icon = agents.status_icon
local core = require("hollow-workmux.core")
local C = core.C
local D = core.D
local LOADING_FRAMES = core.LOADING_FRAMES
local S = core.S
local cfg = core.cfg
local dwidth = core.dwidth
local glyph = core.glyph
local strip_prefix = core.strip_prefix
local trunc = core.trunc
local labels = require("hollow-workmux.labels")
local format_elapsed = labels.format_elapsed
local project_from_path = labels.project_from_path
local resolve_labels = labels.resolve_labels
local sanitize_title = labels.sanitize_title
local shorten_path_label = labels.shorten_path_label
local worktree_name = labels.worktree_name

-- ── Line layout (template/layout.rs) ─────────────────────────────────────────

-- A fragment is { text, fg, bold?, flex? }. The first flex fragment on the
-- left absorbs the leftover width (truncated with "…" when too long); right
-- fragments are dropped from the end when they don't fit; the gap is filled
-- with spaces so the right side sits flush and the row background is solid.
local function layout(left, right, width)
	local function widths(frags)
		local total = 0
		for _, f in ipairs(frags) do
			total = total + dwidth(f[1])
		end
		return total
	end

	local fixed_left = 0
	for _, f in ipairs(left) do
		if not f.flex then
			fixed_left = fixed_left + dwidth(f[1])
		end
	end
	right = { unpack(right) }
	while #right > 0 and widths(right) + fixed_left > width do
		table.remove(right)
	end

	local avail = width - widths(right) - fixed_left
	local out, used = {}, 0
	local flexed = false
	for _, f in ipairs(left) do
		local text = f[1]
		if f.flex and not flexed then
			flexed = true
			text = trunc(text, avail)
		elseif f.flex then
			text = trunc(text, math.max(0, width - widths(right) - used))
		end
		if used + dwidth(text) > width then
			text = trunc(text, width - used)
		end
		out[#out + 1] = { text, f[2], bold = f.bold }
		used = used + dwidth(text)
	end
	local gap = width - used - widths(right)
	if gap > 0 then
		out[#out + 1] = { string.rep(" ", gap) }
	end
	for _, f in ipairs(right) do
		out[#out + 1] = f
	end
	return out
end

-- `fill_bg` paints the row background at full cell height, so a selection
-- spanning several rows reads as one block. Hollow only honours it in the
-- sidebar from the build that reads it back (older ones ignore the field),
-- so the per-span bg stays as the fallback: on those builds it still
-- highlights, just with the 1px seam between rows, and where both apply the
-- span colour matches fill_bg and composes invisibly on top.
local function to_row(frags, bg)
	local spans = {}
	for _, f in ipairs(frags) do
		if f[1] ~= "" then
			spans[#spans + 1] = ui.span(f[1], { fg = f[2] or C.text, bg = f.bg or bg, bold = f.bold })
		end
	end
	return ui.row(spans, bg and { fill_bg = bg } or nil)
end

-- ── Diff-stat ladder (ui.rs) ──────────────────────────────────────────────────

local function git_stats_frags(stats, stale, avail)
	if not stats then
		return {}
	end
	local added, removed = stats.added or 0, stats.removed or 0
	local uadded, uremoved = stats.uncommitted_added or 0, stats.uncommitted_removed or 0
	local has_committed = added > 0 or removed > 0
	local has_uncommitted = uadded > 0 or uremoved > 0 or stats.dirty
	-- when every change is still uncommitted, the dim half would repeat it
	local all_uncommitted = has_uncommitted and uadded == added and uremoved == removed

	local function color(bright, dim)
		if stale then
			return C.dimmed
		end
		return dim and D[bright] or C[bright]
	end

	local rebase, committed, uncommitted = {}, {}, {}
	if stats.rebasing then
		rebase[1] = { glyph("rebase"), color("warning") }
	end
	if has_committed and not all_uncommitted then
		if added > 0 then
			committed[#committed + 1] = { "+" .. added, color("success", true) }
		end
		if removed > 0 then
			committed[#committed + 1] = { "-" .. removed, color("danger", true) }
		end
	end
	if has_uncommitted then
		uncommitted[#uncommitted + 1] = { glyph("diff"), color("accent") }
		if uadded > 0 then
			uncommitted[#uncommitted + 1] = { "+" .. uadded, color("success") }
		end
		if uremoved > 0 then
			uncommitted[#uncommitted + 1] = { "-" .. uremoved, color("danger") }
		end
	end

	local function join(...)
		local out = {}
		for _, group in ipairs({ ... }) do
			for _, frag in ipairs(group) do
				if #out > 0 then
					out[#out + 1] = { " " }
				end
				out[#out + 1] = frag
			end
		end
		return out
	end

	for _, variant in ipairs({ join(rebase, committed, uncommitted), join(rebase, uncommitted), join(rebase) }) do
		local w = 0
		for _, frag in ipairs(variant) do
			w = w + dwidth(frag[1])
		end
		if w <= avail then
			return variant
		end
	end
	return {}
end

-- ── Pull request ──────────────────────────────────────────────────────────────

-- The PR belongs to a branch, so don't show it once the worktree has moved to
-- another one and the lookup hasn't caught up yet.
local function pr_for(agent, stats)
	if not cfg.pr then
		return nil
	end
	local entry = S.pr_cache[agent.workdir]
	if not entry or not entry.pr then
		return nil
	end
	if stats and stats.branch and entry.branch and stats.branch ~= entry.branch then
		return nil
	end
	return entry.pr
end

local PR_STATE_COLOR = { OPEN = "success", MERGED = "accent", CLOSED = "danger" }

-- `#123` coloured by the PR's state, then its checks: an icon, plus
-- passed/total while they're pending or failing (workmux's {pr_number} and
-- {pr_checks} tokens). layout() drops fragments from the end when the line is
-- narrow, so the counts go first, then the icon, then the number.
local function pr_frags(pr, stale)
	if not pr then
		return {}
	end
	local function color(name)
		return stale and C.dimmed or C[name]
	end

	local frags = { { "#" .. pr.number, color(pr.draft and "dimmed" or PR_STATE_COLOR[pr.state] or "dimmed") } }
	local checks = pr.checks
	if checks then
		local icon, name
		if checks.state == "success" then
			icon, name = glyph("check_success"), "success"
		elseif checks.state == "failure" then
			icon, name = glyph("check_failure"), "danger"
		else
			icon, name = LOADING_FRAMES[(S.spinner_frame - 1) % #LOADING_FRAMES + 1], "accent"
		end
		frags[#frags + 1] = { " " }
		frags[#frags + 1] = { icon, color(name) }
		if checks.state ~= "success" and checks.total then
			frags[#frags + 1] = { " " .. checks.passed .. "/" .. checks.total, color(name) }
		end
	end
	return frags
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

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
		pr = pr_for(agent, stats),
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

	local pr = pr_frags(d.pr, d.stale)
	if #pr > 0 then
		table.insert(pr, 1, { " " })
	end
	rows[#rows + 1] = chrome("  ", nil, layout({ { d.title, C.dimmed, flex = true } }, pr, body))
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
