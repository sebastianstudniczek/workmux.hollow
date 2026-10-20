-- hollow-workmux.core
-- The shared foundation: options, state shared between modules, colours,
-- glyphs and the small helpers everything else leans on.

local hollow = _G.hollow
local ui = hollow.ui

local warned = {}

-- ── Config ────────────────────────────────────────────────────────────────────

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
	pr = true, -- show the branch's pull request number and check status
	gh = nil, -- path to the GitHub CLI inside the domain; nil = look it up
	pr_refresh_secs = 60, -- GitHub is rate limited, so this polls slowly
	pr_gh_timeout_secs = 15, -- per `gh` call
	pr_timeout_ms = 90000, -- for the whole lookup across every worktree
}

-- ── Module state ──────────────────────────────────────────────────────────────
-- Shared by every module and reassigned freely, so it lives on one table: a
-- file-local can't be reassigned from another file.
local S = {
	agents = {}, -- sorted, filtered list shown in the sidebar
	all_agents = {}, -- every live agent, before the workspace filter
	loaded = false, -- first agent listing has arrived
	selected_pane = nil, -- pane_id of the selected row
	sleeping = {}, -- pane_id → true (toggled with <C-A-z>)
	acked = {}, -- pane_id → status_ts of a waiting/done status already seen
	git_cache = {}, -- workdir → stats
	pr_cache = {}, -- workdir → { branch, pr = { number, state, draft, url, checks } }
	panes = {}, -- pane_id → { pane, tab, workspace } from hollow's mux tree
	focused_pane_id = nil,
	current_tab_id = nil,
	current_ws_index = nil,
	scroll_offset = 0,
	spinner_frame = 1,
	last_load = 0,
	last_git = 0,
	last_pr = 0,
	agents_busy = false,
	git_busy = false,
	pr_busy = false,
	reload_pending = false,
	ticking = false,
	sidebar_widget = nil,
	own_instance = os.getenv("HOLLOW_COMMAND_ADDR"),
}

-- ── Palette (workmux "Default" dark scheme, ui/theme.rs) ─────────────────────

local PANEL_BG = { 22, 27, 34 } -- hollow draws the sidebar panel in this color

local C = {
	highlight_row_bg = "#28303e",
	current_worktree_fg = "#f4f8ff",
	dimmed = "#6c7086",
	text = "#cdd6f4",
	border = "#3a4a5e",
	info = "#78e1d5",
	success = "#a6da95",
	warning = "#f9e2af",
	danger = "#ed8796",
	accent = "#cba6f7",
}

-- Hollow's sidebar segments carry fg/bg/bold only, so the DIM attribute the
-- tmux sidebar uses is emulated by blending towards the panel background.
local function blend(hex, amount)
	local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then
		return hex
	end
	local function mix(c, bg)
		return math.floor(tonumber(c, 16) * (1 - amount) + bg * amount + 0.5)
	end
	return string.format("#%02x%02x%02x", mix(r, PANEL_BG[1]), mix(g, PANEL_BG[2]), mix(b, PANEL_BG[3]))
end

local D = {} -- dimmed variants, rebuilt by apply_palette()

local function apply_palette()
	for key, value in pairs(cfg.colors or {}) do
		C[key] = value
	end
	for key, value in pairs(C) do
		D[key] = blend(value, 0.45)
	end
end

-- ── Glyphs ────────────────────────────────────────────────────────────────────

local function cp(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
	elseif code < 0x10000 then
		return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
	end
	return string.char(
		0xF0 + math.floor(code / 0x40000),
		0x80 + math.floor(code / 0x1000) % 0x40,
		0x80 + math.floor(code / 0x40) % 0x40,
		0x80 + code % 0x40
	)
end

-- Two-cell braille frames, the same animation the tmux sidebar uses.
local SPINNER_FRAMES = { "⠋⠙", "⠙⠹", "⠹⠸", "⠸⠼", "⠼⠴", "⠴⠦", "⠦⠧", "⠧⠇", "⠇⠏", "⠏⠋" }

local LOADING_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function glyph(name)
	local nerd = cfg.nerdfont
	if name == "diff" then
		return nerd and cp(0xf03eb) or "*"
	elseif name == "rebase" then
		return nerd and cp(0xf47f) or "R"
	elseif name == "stale" then
		return nerd and cp(0xf04b2) or "💤"
	elseif name == "waiting" then
		return cfg.status_icons.waiting or (nerd and cp(0xf075)) or "💬"
	elseif name == "done" then
		return cfg.status_icons.done or (nerd and cp(0xf0134)) or "✅"
	elseif name == "check_success" then
		return nerd and cp(0xf0134) or "✓"
	elseif name == "check_failure" then
		return nerd and cp(0xf0159) or "×"
	end
	return ""
end

-- ── Small utilities ───────────────────────────────────────────────────────────

local CHAR_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"

-- Display width in code points. Hollow's sidebar renderer advances one cell
-- per code point, so this is exact for everything it draws.
local function dwidth(s)
	local n = 0
	for _ in tostring(s or ""):gmatch(CHAR_PATTERN) do
		n = n + 1
	end
	return n
end

-- workmux's truncation (template/layout.rs): keep characters while one more
-- still leaves room for the ellipsis, trim trailing whitespace, append "…".
local function trunc(s, max)
	s = tostring(s or "")
	if max <= 0 then
		return ""
	end
	if dwidth(s) <= max then
		return s
	end
	if max == 1 then
		return "…"
	end
	local out, n = {}, 0
	for ch in s:gmatch(CHAR_PATTERN) do
		if n + 2 > max then
			break
		end
		out[#out + 1] = ch
		n = n + 1
	end
	return (table.concat(out):gsub("%s+$", "")) .. "…"
end

local function warn_once(key, message)
	if warned[key] then
		return
	end
	warned[key] = true
	hollow.log("[hollow-workmux] " .. message)
	pcall(ui.notify.show, "workmux sidebar: " .. message, { level = "warn" })
end

local function config_get(key)
	local ok, value = pcall(hollow.config.get, key)
	return ok and value or nil
end

local function quote(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function pane_num(id)
	return tonumber(id) or math.huge
end

local function path_parts(p)
	local parts = {}
	for part in tostring(p or ""):gmatch("[^/]+") do
		parts[#parts + 1] = part
	end
	return parts
end

local function strip_prefix(s, prefix)
	if s and prefix ~= "" and s:sub(1, #prefix) == prefix then
		return s:sub(#prefix + 1)
	end
	return nil
end

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Ask hollow to repaint the sidebar.
local function redraw()
	pcall(ui.sidebar.invalidate)
end

return {
	C = C,
	CHAR_PATTERN = CHAR_PATTERN,
	D = D,
	LOADING_FRAMES = LOADING_FRAMES,
	S = S,
	SPINNER_FRAMES = SPINNER_FRAMES,
	apply_palette = apply_palette,
	cfg = cfg,
	config_get = config_get,
	dwidth = dwidth,
	glyph = glyph,
	pane_num = pane_num,
	path_parts = path_parts,
	redraw = redraw,
	strip_prefix = strip_prefix,
	trim = trim,
	trunc = trunc,
	warn_once = warn_once,
}
