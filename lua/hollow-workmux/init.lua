-- hollow-workmux
-- Hollow sidebar showing workmux agents, a port of the tmux sidebar
-- (`workmux sidebar`, src/command/sidebar in the workmux repo).
--
-- Hollow is a native Windows app while workmux runs inside WSL, so the data
-- this widget needs (agent state files, git stats) lives on the Linux side.
-- Each refresh crosses that boundary ONCE per concern, asynchronously via
-- `hollow.process.spawn` (wsl.exe --exec bash -c …), so the UI thread never
-- blocks on WSL. Live layout data (workspaces, tabs, pane titles, focus)
-- comes straight from hollow's mux tree.
--
-- Tiles layout (default), one card per agent:
--
--   ▌ ⠹⠸ feature-auth                    5:23
--   ▌    workmux              +412 -87 * +12 -3
--   ▌    fix sidebar socket paths on macOS
--   ──────────────────────────────────────────
--
--   line 1: status icon, primary label (+ "(n)" when a tab holds several
--           agents), time since the last status change
--   line 2: secondary label, git diff stats (committed dim, uncommitted bright)
--   line 3: the agent's pane title
--
-- Compact layout: one line per agent (icon, primary label, elapsed).
--
-- Install: add the plugin to your hollow init.lua; hollow calls setup(opts):
--   hollow.plugins.setup({ plugins = {
--     { "/path/to/hollow-workmux", opts = { width = 40 } },
--   } })
--
-- Options (all optional):
--   width = 34, side = "left",
--   domain = nil,              -- hollow domain to run workmux queries in;
--                              -- nil = hollow's default_domain
--   layout = "tiles",          -- "tiles" | "compact"
--   sort = "recency",          -- "recency" | "window"
--   filter = "all",            -- "all" | "workspace" (current workspace only)
--   dim_stale = true,          -- dim agents idle for more than stale_after secs
--   window_prefix = "wm-",
--   nerdfont = false,          -- use Nerd Font glyphs instead of emoji/ASCII
--   status_icons = { working = nil, waiting = nil, done = nil },
--                              -- a working icon replaces the spinner
--   agent_icons = {},          -- reserved; not rendered by the default layout
--   git = true, git_refresh_secs = 5, untracked = true,
--   height = nil,              -- visible sidebar rows; nil = estimate
--   colors = {},               -- palette overrides, see C below
--   keys = true,               -- install the default keybindings below
--
-- Default keybindings (registered with hollow.keymap.default):
--   <C-A-j>/<C-A-k>  jump to next/previous agent
--   <C-A-1>..<C-A-9> jump to the Nth agent
--   <C-A-w>          toggle the sidebar
--   <C-A-v>          toggle tiles/compact layout
--   <C-A-z>          toggle sleeping on the selected agent
--   <C-A-f>          toggle the current-workspace filter
--   <C-A-r>          reload agents and refresh git stats
--
-- HTP channels (`hollow-cli emit <channel> <json>`):
--   workmux:status   {"pane_id":"<id>", ...}   -- sent by workmux on status
--                                              -- changes; triggers a reload
--   workmux:sidebar  {"action":"toggle"|"show"|"hide"|"refresh"|"layout"
--                              |"next"|"prev"}
--                    {"action":"jump","index":N}
--                    {"action":"focus","pane_id":"<id>"}
-- HTP query (`hollow-cli get htp <channel> <json>`):
--   workmux:focus    {"pane_id":"<id>"} → true once the pane is focused

local hollow = _G.hollow
local ui = hollow.ui

local M = {}

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
	end
	return ""
end

-- ── Module state ──────────────────────────────────────────────────────────────

local agents = {} -- sorted, filtered list shown in the sidebar
local all_agents = {} -- every live agent, before the workspace filter
local loaded = false -- first agent listing has arrived
local selected_pane = nil -- pane_id of the selected row
local sleeping = {} -- pane_id → true (toggled with <C-A-z>)
local acked = {} -- pane_id → status_ts of a waiting/done status already seen
local git_cache = {} -- workdir → stats
local panes = {} -- pane_id → { pane, tab, workspace } from hollow's mux tree
local focused_pane_id = nil
local current_tab_id = nil
local current_ws_index = nil
local scroll_offset = 0
local spinner_frame = 1
local last_load = 0
local last_git = 0
local agents_busy = false
local git_busy = false
local reload_pending = false
local ticking = false
local sidebar_widget = nil
local warned = {}
local own_instance = os.getenv("HOLLOW_COMMAND_ADDR")

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

-- ── Formatting (template/context.rs) ─────────────────────────────────────────

-- Time since the last status change: m:ss under an hour, then hours, then days.
local function format_elapsed(ts)
	if not ts or ts == 0 then
		return ""
	end
	local diff = math.max(0, os.time() - math.floor(ts))
	if diff < 3600 then
		return string.format("%d:%02d", math.floor(diff / 60), diff % 60)
	elseif diff < 86400 then
		return math.floor(diff / 3600) .. "h"
	end
	return math.floor(diff / 86400) .. "d"
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

-- agent_display.rs extract_worktree_name
local function worktree_name(session, window, path)
	local stripped = strip_prefix(window, cfg.window_prefix) or strip_prefix(session, cfg.window_prefix)
	if stripped then
		return stripped
	end
	local parts = path_parts(path)
	for i = #parts, 1, -1 do
		local comp = parts[i]
		if (comp:sub(-11) == "__worktrees" or comp == ".worktrees") and parts[i + 1] then
			return parts[i + 1]
		end
	end
	return "main"
end

-- agent_display.rs extract_project_name, minus the `.git` directory probe
-- (the git refresh supplies the real repository name once it has run).
local function project_from_path(path)
	local parts = path_parts(path)
	for i = #parts, 1, -1 do
		local comp = parts[i]
		if comp:sub(-11) == "__worktrees" then
			return comp:sub(1, #comp - 11)
		end
		if comp == ".worktrees" and parts[i - 1] then
			return parts[i - 1]
		end
	end
	return parts[#parts] or ""
end

local GENERIC_WINDOW = {}
for _, name in ipairs({
	"zsh", "bash", "sh", "fish", "dash", "ksh", "csh", "tcsh", "nu", "xonsh",
	"elvish", "pwsh", "powershell", "cmd", "tmux", "default", "",
}) do
	GENERIC_WINDOW[name] = true
end

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function worktree_meaningful(w)
	w = trim(w)
	return w ~= "" and w ~= "main" and w ~= "master"
end

local function window_meaningful(window, cmd)
	if not cmd then
		return false
	end
	window = trim(window)
	if GENERIC_WINDOW[window] then
		return false
	end
	return window ~= trim(cmd)
end

local function session_meaningful(session, project)
	session = trim(session)
	if session == "" or session == trim(project) or session:lower() == "default" then
		return false
	end
	return not session:match("^%d+$")
end

-- agent_display.rs resolve_labels: first meaningful of worktree → window →
-- session → project is primary; secondary gives the missing context.
local function resolve_labels(project, session, worktree, window, window_cmd)
	local candidates = {
		{ "worktree", worktree, worktree_meaningful(worktree) },
		{ "window", window, window_meaningful(window, window_cmd) },
		{ "session", session, session_meaningful(session, project) },
		{ "project", project, project ~= "" },
	}
	local meaningful = {}
	for _, c in ipairs(candidates) do
		if c[3] then
			meaningful[#meaningful + 1] = c
		end
	end
	local primary = meaningful[1] or { "project", project }
	if primary[1] == "worktree" then
		return worktree, (project ~= "" and project ~= worktree) and project or ""
	end
	local base = meaningful[2] and meaningful[2][2] or ""
	local wt = worktree ~= "" and worktree or "main"
	return primary[2], base == "" and wt or (base .. " · " .. wt)
end

local TITLE_JUNK = { ["✳"] = true, ["⠀"] = true, ["●"] = true, ["○"] = true, ["◌"] = true, ["✓"] = true, ["✗"] = true }

-- agent_display.rs sanitize_pane_title
local function sanitize_title(raw, drop)
	local title = trim(raw)
	if title == "" then
		return nil
	end
	-- strip leading braille (U+2800–U+28FF: E2 A0 80 – E2 A3 BF) and status dots
	while true do
		local ch = title:match("^" .. CHAR_PATTERN)
		if not ch then
			break
		end
		local b1, b2 = ch:byte(1, 2)
		local braille = #ch == 3 and b1 == 0xE2 and b2 >= 0xA0 and b2 <= 0xA3
		if not (braille or TITLE_JUNK[ch]) then
			break
		end
		title = title:sub(#ch + 1)
	end
	title = trim(title)
	while true do
		local prefix, rest = title:match("^([^|]*)|(.*)$")
		if not prefix or trim(prefix) ~= "OC" then
			break
		end
		title = trim(rest)
	end
	if title == "" or title:sub(1, 11) == "Claude Code" then
		return nil
	end
	if title == "zsh" or title == "bash" or title == "sh" or title == "fish" then
		return nil
	end
	for _, value in ipairs(drop) do
		if value and value ~= "" and title == value then
			return nil
		end
	end
	return title
end

-- ── Status & staleness ────────────────────────────────────────────────────────

-- Waiting/done clear once the user has looked at the pane, like the tmux
-- backend's pane-focus-in hook (snapshot.rs suppresses the status then).
local function effective_status(agent)
	local status = agent.status
	if (status == "waiting" or status == "done") and acked[agent.pane_id] == agent.status_ts then
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
	if sleeping[agent.pane_id] then
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
		return cfg.status_icons.working or SPINNER_FRAMES[spinner_frame], C.info
	elseif status == "waiting" or status == "done" then
		return glyph(status), status_color(status)
	end
	return "  ", C.dimmed
end

-- ── Processes (async, inside the workmux domain) ─────────────────────────────

-- The argv prefix that runs a command inside the configured domain.
local function domain_prefix()
	local name = cfg.domain or config_get("default_domain")
	local domains = config_get("domains") or {}
	local domain = type(name) == "string" and domains[name] or nil
	local distro = domain and domain.wsl_distro
	if not distro and domain and type(domain.shell) == "string" then
		distro = domain.shell:match("wsl%.exe%s+%-d%s+(%S+)") or domain.shell:match("^wsl%s+%-d%s+(%S+)")
	end
	if distro then
		return { "wsl.exe", "-d", distro, "--exec" }
	end
	local platform = hollow.platform or {}
	if platform.is_windows then
		return { "wsl.exe", "--exec" }
	end
	return {}
end

-- Run `bash -c script _ args…` and call on_done(stdout) or on_done(nil).
local function run_bash(script, args, on_done)
	local argv = domain_prefix()
	argv[#argv + 1] = "bash"
	argv[#argv + 1] = "-c"
	argv[#argv + 1] = script
	argv[#argv + 1] = "hollow-workmux"
	for _, arg in ipairs(args or {}) do
		argv[#argv + 1] = arg
	end

	if not (hollow.process and hollow.process.spawn) then
		-- older hollow: synchronous fallback
		local ok, ran, stdout = pcall(hollow.term.run_domain_process, { "bash", "-c", script, "hollow-workmux", unpack(args or {}) }, cfg.domain)
		on_done(ok and ran and tostring(stdout or "") or nil)
		return
	end

	local ok, err = pcall(hollow.process.spawn, {
		cmd = argv,
		timeout_ms = cfg.process_timeout_ms,
		on_complete = function(result)
			if result.error then
				hollow.log("[hollow-workmux] process failed: " .. tostring(result.error) .. " " .. tostring(result.stderr))
				on_done(nil)
				return
			end
			on_done(tostring(result.stdout or ""))
		end,
	})
	if not ok then
		hollow.log("[hollow-workmux] spawn failed: " .. tostring(err))
		on_done(nil)
	end
end

-- ── Hollow mux tree ───────────────────────────────────────────────────────────

local function refresh_panes()
	local ok, tree = pcall(hollow.term.mux_tree)
	if not ok or type(tree) ~= "table" then
		return
	end
	local map = {}
	focused_pane_id, current_tab_id, current_ws_index = nil, nil, nil
	for _, ws in ipairs(tree) do
		for _, tab in ipairs(ws.tabs or {}) do
			for _, pane in ipairs(tab.panes or {}) do
				local id = tostring(pane.id)
				map[id] = { pane = pane, tab = tab, workspace = ws }
				if ws.is_active and tab.is_active and pane.is_focused then
					focused_pane_id = id
				end
			end
			if ws.is_active and tab.is_active then
				current_tab_id = tab.id
			end
		end
		if ws.is_active then
			current_ws_index = ws.index
		end
	end
	if not focused_pane_id then
		local cur_ok, cur = pcall(hollow.term.current_pane)
		focused_pane_id = cur_ok and cur and tostring(cur.id) or nil
	end
	panes = map
end

-- Mark the focused pane's waiting/done status as seen.
local function ack_focused()
	if not focused_pane_id then
		return
	end
	for _, agent in ipairs(all_agents) do
		if agent.pane_id == focused_pane_id and (agent.status == "waiting" or agent.status == "done") then
			acked[agent.pane_id] = agent.status_ts
		end
	end
end

-- ── Agent list ────────────────────────────────────────────────────────────────

-- One WSL call reads every hollow agent state file, one compact JSON object
-- per line, so one corrupt/half-written file can't break the batch. The
-- trailing marker tells a real empty listing apart from a failed call.
local AGENTS_SCRIPT = [[
command -v jq >/dev/null 2>&1 || { echo __WORKMUX_NO_JQ__; exit 0; }
dir="${XDG_STATE_HOME:-$HOME/.local/state}/workmux/agents"
for f in "$dir"/hollow__*.json; do
  [ -f "$f" ] || continue
  jq -c '{
    pane_id: ((.pane_key.pane_id // "") | tostring),
    instance: (.pane_key.instance // ""),
    workdir: (.workdir // ""),
    status: .status,
    status_ts: .status_ts,
    activity_ts: .activity_ts,
    updated_ts: .updated_ts,
    pane_title: .pane_title,
    window_name: .window_name,
    session_name: .session_name,
    agent_kind: .agent_kind,
    command: .command
  }' "$f" 2>/dev/null
done
echo __WORKMUX_OK__
]]

local function sort_agents(list, now)
	if cfg.sort == "window" then
		table.sort(list, function(a, b)
			local sa, sb = a.session or "", b.session or ""
			if sa ~= sb then
				return sa < sb
			end
			local ta, tb = a.tab_index or math.huge, b.tab_index or math.huge
			if ta ~= tb then
				return ta < tb
			end
			return pane_num(a.pane_id) < pane_num(b.pane_id)
		end)
		return
	end
	-- snapshot.rs: sleeping last, most recent activity first, then pane number
	table.sort(list, function(a, b)
		local za, zb = sleeping[a.pane_id] and 1 or 0, sleeping[b.pane_id] and 1 or 0
		if za ~= zb then
			return za < zb
		end
		local ta, tb = activity_ts(a), activity_ts(b)
		local da, db = ta and (now - ta) or math.huge, tb and (now - tb) or math.huge
		if da ~= db then
			return da < db
		end
		return pane_num(a.pane_id) < pane_num(b.pane_id)
	end)
end

-- Rebuild the visible list from all_agents: live pane data, filter, sort,
-- per-tab suffixes, and the selection.
local function rebuild()
	local now = os.time()
	local list = {}
	for _, agent in ipairs(all_agents) do
		local live = panes[agent.pane_id]
		if live then
			agent.live_pane = live.pane
			agent.tab_id = live.tab.id
			agent.tab_index = live.tab.index
			agent.ws_index = live.workspace.index
			agent.session = live.workspace.name or agent.session_name
			if cfg.filter ~= "workspace" or live.workspace.index == current_ws_index then
				list[#list + 1] = agent
			end
		end
	end
	sort_agents(list, now)

	-- "(1)", "(2)" … when a tab holds several agents (ui.rs pane_suffix)
	local per_tab, seen = {}, {}
	for _, agent in ipairs(list) do
		per_tab[agent.tab_id] = (per_tab[agent.tab_id] or 0) + 1
	end
	for _, agent in ipairs(list) do
		if per_tab[agent.tab_id] > 1 then
			seen[agent.tab_id] = (seen[agent.tab_id] or 0) + 1
			agent.pane_suffix = "(" .. seen[agent.tab_id] .. ")"
		else
			agent.pane_suffix = ""
		end
	end
	agents = list
end

-- The agent in the user's focus: the focused pane, else the first agent in
-- the current tab (app.rs host_agent_idx, with hollow's tab as the window).
local function host_index()
	local first_in_tab
	for i, agent in ipairs(agents) do
		if agent.pane_id == focused_pane_id then
			return i
		end
		if not first_in_tab and current_tab_id and agent.tab_id == current_tab_id then
			first_in_tab = i
		end
	end
	return first_in_tab
end

local function selected_index()
	-- the selection follows the focused agent (app.rs FollowHost); jumps
	-- move focus, so there is no separate manual mode to fall back from
	local host = host_index()
	if host then
		selected_pane = agents[host].pane_id
		return host
	end
	for i, agent in ipairs(agents) do
		if agent.pane_id == selected_pane then
			return i
		end
	end
	if #agents > 0 then
		selected_pane = agents[1].pane_id
		return 1
	end
	return nil
end

local function apply_agents(stdout)
	if stdout:find("__WORKMUX_NO_JQ__", 1, true) then
		warn_once("jq", "`jq` is not installed in the workmux domain; install it to see agents")
	end
	if not stdout:find("__WORKMUX_OK__", 1, true) then
		return false -- the WSL call itself failed; keep the previous list
	end

	refresh_panes()

	-- A file per (instance, pane); keep one per live pane, preferring this
	-- hollow instance and then the most recently updated file.
	local by_pane = {}
	for line in stdout:gmatch("[^\r\n]+") do
		if line:match("^%s*{") then
			local ok, data = pcall(hollow.json.decode, line)
			if ok and type(data) == "table" and data.pane_id and data.pane_id ~= "" and panes[data.pane_id] then
				local prev = by_pane[data.pane_id]
				local mine = own_instance and data.instance == own_instance
				local prev_mine = prev and own_instance and prev.instance == own_instance
				if
					not prev
					or (mine and not prev_mine)
					or (mine == prev_mine and (data.updated_ts or 0) > (prev.updated_ts or 0))
				then
					by_pane[data.pane_id] = data
				end
			end
		end
	end

	local list = {}
	for _, agent in pairs(by_pane) do
		list[#list + 1] = agent
	end
	all_agents = list
	loaded = true
	ack_focused()
	rebuild()
	return true
end

local redraw -- forward declaration

local function load_agents()
	if agents_busy then
		reload_pending = true
		return
	end
	agents_busy = true
	last_load = os.time()
	run_bash(AGENTS_SCRIPT, nil, function(stdout)
		agents_busy = false
		if stdout and apply_agents(stdout) then
			redraw()
		end
		if reload_pending then
			reload_pending = false
			load_agents()
		end
	end)
end

-- ── Git stats ─────────────────────────────────────────────────────────────────

-- Every worktree in ONE call, one JSON line each: branch, dirty, rebase,
-- repository name, committed diff vs the base branch (branch.<b>.workmux-base,
-- then origin/HEAD, then main/master) and uncommitted diff vs HEAD including
-- untracked lines (git/status.rs).
local GIT_SCRIPT = [[
limit="$1"; shift
command -v jq >/dev/null 2>&1 || exit 0
for dir in "$@"; do
(
  cd "$dir" 2>/dev/null || exit 0
  status_out=$(git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null) || exit 0
  branch=$(printf '%s\n' "$status_out" | sed -n 's/^# branch\.head //p')
  [ "$branch" = "(detached)" ] && branch=""
  dirty=false
  printf '%s\n' "$status_out" | grep -qv '^#' && dirty=true

  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$common" in
    */.git) project=$(basename "$(dirname "$common")") ;;
    *) project=$(basename "${common%.git}") ;;
  esac

  rebasing=false
  for p in rebase-merge rebase-apply; do
    d=$(git rev-parse --git-path "$p" 2>/dev/null)
    [ -n "$d" ] && [ -d "$d" ] && rebasing=true
  done

  added=0; removed=0
  if [ -n "$branch" ]; then
    base=$(git config --local --get "branch.$branch.workmux-base" 2>/dev/null)
    if [ -z "$base" ]; then
      head_ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
      base=${head_ref#refs/remotes/origin/}
      [ "$base" = "$head_ref" ] && base=""
    fi
    if [ -z "$base" ]; then
      for candidate in main master; do
        if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then base="$candidate"; break; fi
      done
    fi
    [ -z "$base" ] && base="main"
    if [ "$branch" != "$base" ]; then
      read -r added removed <<EOF
$(git diff --no-ext-diff --no-textconv --numstat "$base...HEAD" 2>/dev/null | awk '{a+=$1; r+=$2} END{print a+0, r+0}')
EOF
    fi
  fi

  read -r uadded uremoved <<EOF
$(git diff --no-ext-diff --no-textconv --numstat HEAD 2>/dev/null | awk '{a+=$1; r+=$2} END{print a+0, r+0}')
EOF
  if [ "$limit" -gt 0 ]; then
    untracked=$(git ls-files -z --others --exclude-standard 2>/dev/null | xargs -0 -r cat 2>/dev/null | head -c "$limit" | wc -l)
    uadded=$((uadded + untracked))
  fi

  jq -nc --arg dir "$dir" --arg branch "$branch" --arg project "$project" \
    --argjson dirty "$dirty" --argjson rebasing "$rebasing" \
    --argjson added "${added:-0}" --argjson removed "${removed:-0}" \
    --argjson uadded "${uadded:-0}" --argjson uremoved "${uremoved:-0}" \
    '{dir:$dir, branch:(if $branch == "" then null else $branch end), project:$project,
      dirty:$dirty, rebasing:$rebasing, added:$added, removed:$removed,
      uncommitted_added:$uadded, uncommitted_removed:$uremoved}'
)
done
echo __WORKMUX_OK__
]]

local function refresh_git()
	if not cfg.git or git_busy then
		return
	end
	local dirs, seen = {}, {}
	for _, agent in ipairs(all_agents) do
		local dir = agent.workdir
		if dir and dir ~= "" and not seen[dir] then
			seen[dir] = true
			dirs[#dirs + 1] = dir
		end
	end
	last_git = os.time()
	if #dirs == 0 then
		return
	end

	git_busy = true
	local args = { tostring(cfg.untracked and cfg.untracked_byte_limit or 0) }
	for _, dir in ipairs(dirs) do
		args[#args + 1] = dir
	end
	run_bash(GIT_SCRIPT, args, function(stdout)
		git_busy = false
		if not stdout or not stdout:find("__WORKMUX_OK__", 1, true) then
			return
		end
		local fresh = {}
		for line in stdout:gmatch("[^\r\n]+") do
			if line:match("^%s*{") then
				local ok, data = pcall(hollow.json.decode, line)
				if ok and type(data) == "table" and data.dir then
					fresh[data.dir] = data
				end
			end
		end
		git_cache = fresh
		redraw()
	end)
end

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

local function to_row(frags, bg)
	local spans = {}
	for _, f in ipairs(frags) do
		if f[1] ~= "" then
			spans[#spans + 1] = ui.span(f[1], { fg = f[2] or C.text, bg = f.bg or bg, bold = f.bold })
		end
	end
	return ui.row(spans)
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

-- ── Rendering ─────────────────────────────────────────────────────────────────

-- Everything a row needs, computed once per render.
local function row_data(agent, index, now, host)
	local stale = is_stale(agent, now)
	local live = agent.live_pane or {}
	local stats = cfg.git and git_cache[agent.workdir] or nil

	local session = agent.session or agent.session_name or ""
	-- Hollow tabs track their active pane's title unless renamed (workmux
	-- renames the ones it creates), so only a renamed tab counts as a window.
	local tab = panes[agent.pane_id] and panes[agent.pane_id].tab
	local window = tab and tab.title or agent.window_name or ""
	local window_cmd = live.foreground_process or agent.command
	if window == (live.title or "") then
		window_cmd = nil
	end

	local worktree = worktree_name(session, window, agent.workdir)
	local project = (stats and stats.project and stats.project ~= "") and stats.project
		or project_from_path(agent.workdir)
	-- names carrying the window prefix already surfaced as the worktree
	local label_session = strip_prefix(session, cfg.window_prefix) and "" or session
	local label_window = strip_prefix(window, cfg.window_prefix) and "" or window
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

	if not loaded then
		return centered(LOADING_FRAMES[(spinner_frame - 1) % #LOADING_FRAMES + 1] .. " Loading", C.dimmed, width, height)
	end
	if #agents == 0 then
		return centered("No agents running", C.dimmed, width, height)
	end

	local host = host_index()
	local sel = selected_index()
	local data = {}
	local icon_width = 0
	for i, agent in ipairs(agents) do
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
	scroll_offset = math.max(0, math.min(scroll_offset, #data - 1))
	if sel and sel <= scroll_offset then
		scroll_offset = sel - 1
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
	while sel and fits_from(scroll_offset) < sel and scroll_offset < sel - 1 do
		scroll_offset = scroll_offset + 1
	end
	local last = fits_from(scroll_offset)

	local rows = {}
	for i = scroll_offset + 1, last do
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

-- ── Scheduling ────────────────────────────────────────────────────────────────

redraw = function()
	pcall(ui.sidebar.invalidate)
end

local function needs_fast_tick()
	if not loaded then
		return true
	end
	if cfg.status_icons.working then
		return false
	end
	for _, agent in ipairs(agents) do
		if effective_status(agent) == "working" then
			return true
		end
	end
	return false
end

local tick
-- 250 ms while something animates, 1 s otherwise (elapsed times still move).
tick = function()
	if not ticking then
		return
	end
	local now = os.time()
	local fast = needs_fast_tick()
	spinner_frame = spinner_frame % #SPINNER_FRAMES + 1

	if now - last_load >= cfg.reload_secs then
		load_agents()
	end
	if cfg.git and now - last_git >= cfg.git_refresh_secs then
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

-- ── Navigation ────────────────────────────────────────────────────────────────

local function jump_to(agent)
	if not agent then
		return
	end
	selected_pane = agent.pane_id
	local id = tonumber(agent.pane_id)
	if id then
		pcall(hollow.term.focus_pane_by_id, id)
	end
	schedule_reload(50)
end

local function current_index()
	for i, agent in ipairs(agents) do
		if agent.pane_id == focused_pane_id then
			return i
		end
	end
	return selected_index()
end

function M.next()
	if #agents == 0 then
		return
	end
	local i = current_index() or #agents
	jump_to(agents[i % #agents + 1])
end

function M.prev()
	if #agents == 0 then
		return
	end
	local i = current_index() or 1
	jump_to(agents[(i - 2) % #agents + 1])
end

function M.jump(n)
	jump_to(agents[n])
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
	local agent = i and agents[i]
	if not agent then
		return
	end
	sleeping[agent.pane_id] = not sleeping[agent.pane_id] or nil
	rebuild()
	redraw()
end

--- Reload agent state and refresh git stats now.
function M.refresh()
	load_agents()
	last_git = 0
	refresh_git()
	redraw()
end

-- ── Events ────────────────────────────────────────────────────────────────────

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
	local previous_focus = focused_pane_id
	refresh_panes()
	if focused_pane_id ~= previous_focus then
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
		if sidebar_widget then
			ui.sidebar.mount(sidebar_widget)
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

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param opts? table see the header comment for the recognised keys
function M.setup(opts)
	if type(opts) == "table" then
		for key, value in pairs(opts) do
			cfg[key] = value
		end
	end
	cfg.status_icons = type(cfg.status_icons) == "table" and cfg.status_icons or {}
	apply_palette()

	sidebar_widget = ui.sidebar.new({
		side = cfg.side,
		width = cfg.width,
		reserve = true,
		render = render,
		on_event = on_widget_event,
	})
	ui.sidebar.mount(sidebar_widget)

	hollow.htp.on_emit("workmux:status", on_htp_status)
	hollow.htp.on_emit("workmux:sidebar", on_htp_sidebar)
	-- `hollow-cli get htp workmux:focus '{"pane_id":"<id>"}'` prints `true`
	-- once focused; workmux's hollow backend uses it for select_pane, since
	-- hollow-cli has no focus-by-id verb
	hollow.htp.on_query("workmux:focus", function(ctx)
		return M.focus_pane(ctx.params and ctx.params.pane_id)
	end)

	if cfg.keys then
		local map = hollow.keymap.default
		map("<C-A-j>", M.next, { desc = "workmux: next agent" })
		map("<C-A-k>", M.prev, { desc = "workmux: previous agent" })
		for n = 1, 9 do
			map("<C-A-" .. n .. ">", function()
				M.jump(n)
			end, { desc = "workmux: jump to agent " .. n })
		end
		map("<C-A-w>", function()
			ui.sidebar.toggle()
		end, { desc = "workmux: toggle sidebar" })
		map("<C-A-v>", M.toggle_layout, { desc = "workmux: toggle sidebar layout" })
		map("<C-A-z>", M.toggle_sleep, { desc = "workmux: toggle agent sleeping" })
		map("<C-A-f>", M.toggle_filter, { desc = "workmux: toggle workspace filter" })
		map("<C-A-r>", M.refresh, { desc = "workmux: refresh sidebar" })
	end

	refresh_panes()
	load_agents()

	if not ticking then
		ticking = true
		pcall(hollow.defer, tick, 250)
	end
end

return M
