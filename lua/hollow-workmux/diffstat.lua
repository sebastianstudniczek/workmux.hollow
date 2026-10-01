-- hollow-workmux.diffstat: the diff-stat ladder shown on a tile's second line (ui.rs).

local glyph = require("hollow-workmux.glyphs").glyph
local palette = require("hollow-workmux.palette")
local C, D = palette.C, palette.D
local dwidth = require("hollow-workmux.util").dwidth

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

return {
	git_stats_frags = git_stats_frags,
}
