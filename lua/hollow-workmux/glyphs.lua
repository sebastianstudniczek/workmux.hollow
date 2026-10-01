-- hollow-workmux.glyphs: spinner frames and status glyphs.

local cfg = require("hollow-workmux.config")

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

return {
	LOADING_FRAMES = LOADING_FRAMES,
	SPINNER_FRAMES = SPINNER_FRAMES,
	glyph = glyph,
}
