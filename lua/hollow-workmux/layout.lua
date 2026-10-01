-- hollow-workmux.layout: fitting a row of fragments into a fixed width (template/layout.rs).

local hollow = _G.hollow
local ui = hollow.ui
local unpack = table.unpack or unpack

local C = require("hollow-workmux.palette").C
local util = require("hollow-workmux.util")
local dwidth, trunc = util.dwidth, util.trunc

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

return {
	layout = layout,
	to_row = to_row,
}
