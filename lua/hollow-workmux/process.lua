-- hollow-workmux.process: running commands inside the workmux domain (WSL) without blocking hollow.

local hollow = _G.hollow
local unpack = table.unpack or unpack

local cfg = require("hollow-workmux.config")
local config_get = require("hollow-workmux.util").config_get

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

return {
	run_bash = run_bash,
}
