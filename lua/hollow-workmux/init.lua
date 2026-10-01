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
--   status_icons = { working = nil, waiting = nil, done = nil, idle = nil },
--                              -- a working icon replaces the spinner; idle
--                              -- marks agents with no status (blank like the
--                              -- tmux sidebar unless you set one)
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
--
-- Layout: this file is only the entry point. The work lives in the sibling
-- modules (config, state, palette, glyphs, util, labels, status, process,
-- tree, agents, git, layout, diffstat, render, scheduler, nav, events).

local hollow = _G.hollow
local ui = hollow.ui

local cfg = require("hollow-workmux.config")
local S = require("hollow-workmux.state")
-- nav's table is the plugin's public API; setup() is added to it below
local M = require("hollow-workmux.nav")
local load_agents = require("hollow-workmux.agents").load_agents
local events = require("hollow-workmux.events")
local on_htp_sidebar, on_htp_status, on_widget_event =
	events.on_htp_sidebar, events.on_htp_status, events.on_widget_event
local apply_palette = require("hollow-workmux.palette").apply_palette
local render = require("hollow-workmux.render").render
local tick = require("hollow-workmux.scheduler").tick
local refresh_panes = require("hollow-workmux.tree").refresh_panes

---@param opts? table see the header comment for the recognised keys
function M.setup(opts)
	if type(opts) == "table" then
		for key, value in pairs(opts) do
			cfg[key] = value
		end
	end
	cfg.status_icons = type(cfg.status_icons) == "table" and cfg.status_icons or {}
	apply_palette()

	S.sidebar_widget = ui.sidebar.new({
		side = cfg.side,
		width = cfg.width,
		reserve = true,
		render = render,
		on_event = on_widget_event,
	})
	ui.sidebar.mount(S.sidebar_widget)

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

	if not S.ticking then
		S.ticking = true
		pcall(hollow.defer, tick, 250)
	end
end

return M
