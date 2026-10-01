-- hollow-workmux.util: small helpers shared by every module: text width and truncation, path
-- splitting, logging, and the sidebar redraw hook.

local hollow = _G.hollow
local ui = hollow.ui

local warned = {}

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
	CHAR_PATTERN = CHAR_PATTERN,
	config_get = config_get,
	dwidth = dwidth,
	pane_num = pane_num,
	path_parts = path_parts,
	redraw = redraw,
	strip_prefix = strip_prefix,
	trim = trim,
	trunc = trunc,
	warn_once = warn_once,
}
