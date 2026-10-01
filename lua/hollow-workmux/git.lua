-- hollow-workmux.git: per-worktree git stats (branch, dirty, rebase, committed/uncommitted diff).

local hollow = _G.hollow

local cfg = require("hollow-workmux.config")
local S = require("hollow-workmux.state")
local run_bash = require("hollow-workmux.process").run_bash
local redraw = require("hollow-workmux.util").redraw

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
	if not cfg.git or S.git_busy then
		return
	end
	local dirs, seen = {}, {}
	for _, agent in ipairs(S.all_agents) do
		local dir = agent.workdir
		if dir and dir ~= "" and not seen[dir] then
			seen[dir] = true
			dirs[#dirs + 1] = dir
		end
	end
	S.last_git = os.time()
	if #dirs == 0 then
		return
	end

	S.git_busy = true
	local args = { tostring(cfg.untracked and cfg.untracked_byte_limit or 0) }
	for _, dir in ipairs(dirs) do
		args[#args + 1] = dir
	end
	run_bash(GIT_SCRIPT, args, function(stdout)
		S.git_busy = false
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
		S.git_cache = fresh
		redraw()
	end)
end

return {
	refresh_git = refresh_git,
}
