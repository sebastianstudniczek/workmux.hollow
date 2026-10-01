-- hollow-workmux.labels: display names for an agent row, ported from workmux's agent_display.rs and
-- template/context.rs: worktree and project names, primary/secondary labels,
-- pane title cleanup and elapsed time.

local cfg = require("hollow-workmux.config")
local util = require("hollow-workmux.util")
local CHAR_PATTERN, path_parts, strip_prefix, trim =
	util.CHAR_PATTERN, util.path_parts, util.strip_prefix, util.trim

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

-- Hollow workspaces are commonly named after a directory (the workspace
-- switcher fills them from zoxide), so a label can arrive as a full path
-- like "/home/me/repos/project/worktree" and swallow the whole row. Reduce
-- those to the shape tmux sessions already use: "<project>/<worktree>", or
-- the trailing component when the project name isn't part of the path.
local function shorten_path_label(label, project)
	label = trim(label)
	if label == "" or label:sub(1, 1) ~= "/" then
		return label
	end
	local parts = path_parts(label)
	if #parts == 0 then
		return label
	end
	project = trim(project)
	if project ~= "" then
		for i = #parts, 1, -1 do
			if parts[i] == project then
				return table.concat(parts, "/", i)
			end
		end
	end
	return parts[#parts]
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

return {
	format_elapsed = format_elapsed,
	project_from_path = project_from_path,
	resolve_labels = resolve_labels,
	sanitize_title = sanitize_title,
	shorten_path_label = shorten_path_label,
	worktree_name = worktree_name,
}
