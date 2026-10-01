-- hollow-workmux.palette: colours: the workmux "Default" dark scheme (ui/theme.rs) plus dimmed variants.

local cfg = require("hollow-workmux.config")

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

return {
	C = C,
	D = D,
	apply_palette = apply_palette,
}
