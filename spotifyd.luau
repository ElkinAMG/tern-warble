--!strict
-- Local player: runs Homebrew's `spotifyd` as a per-user LaunchAgent, so this Mac shows up in Spotify
-- Connect as the device "Tern" and plays audio with no Spotify app. The plugin installs and supervises
-- it; it ships no spotifyd code or binary (spotifyd is GPL-3.0, see NOTICE).
--
-- Why Homebrew and not the GitHub release: the v0.4.2 macOS builds link Homebrew's libs at
-- /opt/homebrew/opt/... (the default one failed to start without libdbus; the slim one links
-- libportaudio, per `otool -L`).
--
-- All state lives on disk (the LaunchAgent plist, the credentials) or in launchd; nothing here is
-- remembered between calls, so every status is a fresh question to the system.
--
-- A new login (pairing or browser) is written to a STAGING directory and only moved over the working
-- one once it has worked, so a failed or cancelled attempt never costs you the login you had.

local M = {}

M.DEVICE_NAME = "Tern"
M.LABEL = "so.tern-spotify.spotifyd"
-- spotifyd's own default for `authenticate`. The redirect URI it sends belongs to Spotify's desktop client;
-- Spotify accepted this port in a real run (spotifyd printed "Login successful"). The Keymaster sign-in uses
-- it too, so the two must never listen at once.
M.OAUTH_PORT = 8000
M.INSTALL_TIMEOUT_MS = 600000
M.PAIR_TIMEOUT_MS = 180000
M.OAUTH_TIMEOUT_MS = 180000
local RUN_TIMEOUT_MS = 15000 -- launchctl, id, pkill and the login swap take well under a second
local UNLOAD_POLLS = 25 -- x 200 ms: how long to wait for launchd to finish removing a job

local BINARIES = { "/opt/homebrew/opt/spotifyd/bin/spotifyd", "/usr/local/opt/spotifyd/bin/spotifyd" }
local BREWS = { "/opt/homebrew/bin/brew", "/usr/local/bin/brew" }

export type Paths = {
	home: string,
	cache: string, -- the login spotifyd runs with
	staging: string, -- where a new login is made before it replaces `cache`
	log: string,
	oauth_log: string,
	plist_dir: string,
	plist: string,
}

export type Status = {
	bin: string?, -- the spotifyd binary, if installed
	version: string?,
	enabled: boolean, -- the LaunchAgent plist exists: it starts at every login
	loaded: boolean, -- launchd knows the job
	running: boolean, -- launchd says it has a process right now
	pid: number?,
}

type Result = { status: number, stdout: string, stderr: string, timed_out: boolean }

local uid_cache: string? = nil

function M.supported(): boolean
	return tern.runtime.os == "macos"
end

function M.paths(): Paths?
	local home = tern.getenv("HOME")
	if not home or home == "" then
		return nil
	end
	local data = tern.plugin.data
	return {
		home = home,
		cache = data .. "/spotifyd-cache",
		staging = data .. "/spotifyd-cache.new",
		log = data .. "/spotifyd.log",
		oauth_log = data .. "/spotifyd-oauth.log",
		plist_dir = home .. "/Library/LaunchAgents",
		plist = `{home}/Library/LaunchAgents/{M.LABEL}.plist`,
	}
end

local function xml(s: string): string
	return (string.gsub(s, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

-- The command line of spotifyd. `discovery` is the zeroconf window of the pairing run; the supervised
-- agent never has it. `cache` is where credentials live: the working one, or the staging one while a new
-- login is made. Everything is a flag (verified against `spotifyd --help`), so no config file.
function M.args(bin: string, cache: string, discovery: boolean): { string }
	return {
		bin,
		"--no-daemon",
		"--device-name",
		M.DEVICE_NAME,
		"--device-type",
		"computer",
		"--cache-path",
		cache,
		"--bitrate",
		"160",
		"--no-audio-cache=true",
		"--disable-discovery=" .. (if discovery then "false" else "true"),
	}
end

-- Restarted only when it dies (not after a clean exit), at most every 30 s: with no valid login it
-- can't loop on the CPU.
function M.plist(bin: string, p: Paths): string
	local items = {}
	for _, a in M.args(bin, p.cache, false) do
		table.insert(items, `\t\t<string>{xml(a)}</string>`)
	end
	return table.concat({
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
		'<plist version="1.0">',
		"<dict>",
		"\t<key>Label</key>",
		`\t<string>{M.LABEL}</string>`,
		"\t<key>ProgramArguments</key>",
		"\t<array>",
		table.concat(items, "\n"),
		"\t</array>",
		"\t<key>RunAtLoad</key>",
		"\t<true/>",
		"\t<key>KeepAlive</key>",
		"\t<dict>",
		"\t\t<key>SuccessfulExit</key>",
		"\t\t<false/>",
		"\t</dict>",
		"\t<key>ThrottleInterval</key>",
		"\t<integer>30</integer>",
		"\t<key>LimitLoadToSessionType</key>",
		"\t<string>Aqua</string>",
		"\t<key>StandardOutPath</key>",
		`\t<string>{xml(p.log)}</string>`,
		"\t<key>StandardErrorPath</key>",
		`\t<string>{xml(p.log)}</string>`,
		"</dict>",
		"</plist>",
		"",
	}, "\n")
end

-- tern.process.run raises when the program can't be spawned: hand that back as a failed result. Calls that
-- don't set their own limit get RUN_TIMEOUT_MS, so a stuck helper can't leave the screen waiting forever.
local function run(argv: { string }, opts: ProcessOptions, cb: (Result) -> ())
	if opts.timeout_ms == nil then
		local limited: ProcessOptions = table.clone(opts)
		limited.timeout_ms = RUN_TIMEOUT_MS
		opts = limited
	end
	local ok, err = pcall(function()
		tern.process.run(argv, opts, cb)
	end)
	if not ok then
		cb({ status = -1, stdout = "", stderr = tostring(err), timed_out = false })
	end
end

local function first_existing(paths: { string }): string?
	for _, path in paths do
		local ok, found = pcall(tern.fs.exists, path)
		if ok and found then
			return path
		end
	end
	return nil
end

function M.find_binary(): string?
	return first_existing(BINARIES)
end

function M.find_brew(): string?
	return first_existing(BREWS)
end

-- The last `lines` non-empty lines of `text`.
local function tail(text: string, lines: number): string
	local out = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		table.insert(out, line)
		if #out > lines then
			table.remove(out, 1)
		end
	end
	return table.concat(out, "\n")
end
M.tail = tail

-- The last `lines` lines of a log file, or "" when there is none.
function M.log_tail(path: string, lines: number): string
	local ok, text = pcall(tern.fs.read, path, 65536)
	if not ok then
		return ""
	end
	return tail(text, lines)
end

-- Where spotifyd keeps a login inside its cache folder: `spotifyd authenticate` writes
-- `oauth/credentials.json` (docs.spotifyd.rs/configuration/auth.html), a pairing from the phone writes
-- `zeroconf/credentials.json`. A folder that only holds other files (`volume`) or an empty `oauth/`
-- (made when authenticate starts) has no login.
local CREDENTIAL_FILES = { "oauth/credentials.json", "zeroconf/credentials.json", "credentials.json" }

local function has_credentials(dir: string): boolean
	for _, rel in CREDENTIAL_FILES do
		local ok, found = pcall(tern.fs.exists, dir .. "/" .. rel)
		if ok and found then
			return true
		end
	end
	return false
end

-- Whether the working login (what the agent runs with) has credentials.
function M.has_login(): boolean
	local p = M.paths()
	return p ~= nil and has_credentials(p.cache)
end

-- Whether a new login has written its credentials yet. For a pairing this means "someone paired", not yet
-- "this account".
function M.staging_has_login(): boolean
	local p = M.paths()
	return p ~= nil and has_credentials(p.staging)
end

function M.is_enabled(): boolean
	local p = M.paths()
	if not p then
		return false
	end
	local ok, found = pcall(tern.fs.exists, p.plist)
	return ok and found
end

local function uid(cb: (string?) -> ())
	if uid_cache then
		cb(uid_cache)
		return
	end
	run({ "id", "-u" }, {}, function(r)
		local id = string.match(r.stdout, "^(%d+)")
		uid_cache = id
		cb(id)
	end)
end

local function launchctl(args: { string }, cb: (Result) -> ())
	uid(function(id)
		if not id then
			cb({ status = -1, stdout = "", stderr = "Could not read your user id.", timed_out = false })
			return
		end
		local argv = { "launchctl" }
		for _, a in args do
			table.insert(argv, (string.gsub(a, "{uid}", id)))
		end
		run(argv, {}, cb)
	end)
end

-- The launchctl service target; `{uid}` is filled in by `launchctl` above.
local function target(): string
	return "gui/{uid}/" .. M.LABEL
end

-- Fresh status: the plist on disk, what launchd says, and the installed version.
function M.status(cb: (Status) -> ())
	local bin = M.find_binary()
	local st: Status = { bin = bin, version = nil, enabled = M.is_enabled(), loaded = false, running = false, pid = nil }
	launchctl({ "print", target() }, function(r)
		if r.status == 0 then
			st.loaded = true
			st.running = string.find(r.stdout, "state = running", 1, true) ~= nil
			if st.running then
				st.pid = tonumber(string.match(r.stdout, "\n%s*pid = (%d+)"))
			end
		end
		if not bin then
			cb(st)
			return
		end
		run({ bin, "--version" }, { timeout_ms = 10000 }, function(v)
			st.version = string.match(v.stdout, "(%d+%.%d+%.%d+)")
			cb(st)
		end)
	end)
end

-- `brew install spotifyd`, with Homebrew's own checksum on the bottle.
function M.install(cb: (boolean, string?) -> ())
	if M.find_binary() then
		cb(true, nil)
		return
	end
	local brew = M.find_brew()
	if not brew then
		cb(false, "Homebrew isn't installed (https://brew.sh). Install it, then try again.")
		return
	end
	run({ brew, "install", "spotifyd" }, { timeout_ms = M.INSTALL_TIMEOUT_MS, env = { HOMEBREW_NO_AUTO_UPDATE = "1", HOMEBREW_NO_ANALYTICS = "1", HOMEBREW_NO_ENV_HINTS = "1" } }, function(r)
		if r.status == 0 and M.find_binary() then
			cb(true, nil)
		elseif r.timed_out then
			cb(false, "brew install spotifyd timed out.")
		else
			cb(false, tail(r.stderr ~= "" and r.stderr or r.stdout, 4))
		end
	end)
end

-- launchctl's answer for a job it doesn't know (checked by hand: `launchctl print` of an unloaded job).
local NOT_LOADED = 113

-- After a bootout: asks launchd every 200 ms (at most `tries` times) until it no longer knows the job. A
-- print that fails any other way (timeout, no uid) proves nothing, so it doesn't end the wait.
local function wait_unloaded(tries: number, cb: () -> ())
	launchctl({ "print", target() }, function(r)
		if r.status == NOT_LOADED or tries <= 1 then
			cb()
		else
			tern.timer(200, function()
				wait_unloaded(tries - 1, cb)
			end)
		end
	end)
end

-- Writes the LaunchAgent and (re)loads it: the player starts now and at every login.
function M.enable(cb: (boolean, string?) -> ())
	local p, bin = M.paths(), M.find_binary()
	if not p or not bin then
		cb(false, if p then "spotifyd isn't installed." else "HOME isn't set.")
		return
	end
	local ok, err = pcall(function()
		tern.fs.mkdir(p.cache)
		tern.fs.mkdir(p.plist_dir)
		tern.fs.write(p.log, "") -- starts the log afresh; launchd's own restarts append to it until the next start
		tern.fs.write(p.plist, M.plist(bin, p))
	end)
	if not ok then
		cb(false, tostring(err))
		return
	end
	-- bootstrap fails (error 5) on a job that is already loaded: unload it first, ignoring "not loaded".
	-- bootout returns before launchd has finished removing the job, and a bootstrap sent in that window is
	-- lost (seen in the system log: bootstrap and "removing service" in the same millisecond, nothing left
	-- loaded). So wait until launchd says the job is gone, then load it, then check it really is loaded.
	launchctl({ "bootout", target() }, function()
		wait_unloaded(UNLOAD_POLLS, function()
			launchctl({ "bootstrap", "gui/{uid}", p.plist }, function(r)
				if r.status ~= 0 then
					cb(false, tail(r.stderr ~= "" and r.stderr or r.stdout, 3))
					return
				end
				launchctl({ "print", target() }, function(seen)
					if seen.status == NOT_LOADED then
						cb(false, "launchd did not keep the local player loaded. Try start (s) again.")
					else
						cb(true, nil) -- loaded, or launchctl couldn't say: the wait for the device decides
					end
				end)
			end)
		end)
	end)
end

-- Unloads the job and removes the plist: it no longer starts at login. Credentials stay.
function M.disable(cb: (boolean, string?) -> ())
	local p = M.paths()
	launchctl({ "bootout", target() }, function()
		if p then
			local ok, err = pcall(function()
				if tern.fs.exists(p.plist) then
					tern.fs.remove(p.plist)
				end
			end)
			if not ok then
				cb(false, tostring(err))
				return
			end
		end
		cb(true, nil)
	end)
end

local function remove_paths(paths: { string }): (boolean, string?)
	local ok, err = pcall(function()
		for _, path in paths do
			if tern.fs.exists(path) then
				tern.fs.remove(path)
			end
		end
	end)
	return ok, if ok then nil else tostring(err)
end

-- Disable, and delete the credentials and logs this plugin wrote. Homebrew's spotifyd stays installed.
function M.remove(cb: (boolean, string?) -> ())
	M.disable(function(ok, err)
		local p = M.paths()
		if ok and p then
			ok, err = remove_paths({ p.cache, p.cache .. ".old", p.staging, p.log, p.oauth_log })
		end
		cb(ok, err)
	end)
end

-- Drops a login that was never committed.
function M.wipe_staging()
	local p = M.paths()
	if p then
		remove_paths({ p.staging })
	end
end

-- The new login worked: it replaces the old one. The old one is moved aside first and only deleted once the
-- new one is in place; if that move fails the old one is put back, so this never leaves you with none.
-- A leftover `.old` from a crash is discarded only while a working login exists.
function M.commit(cb: (boolean, string?) -> ())
	local p = M.paths()
	if not p then
		cb(false, "HOME isn't set.")
		return
	end
	local script = 'if [ -d "$1" ]; then rm -rf "$1.old"; mv "$1" "$1.old" || exit 1; fi\nif mv "$2" "$1"; then rm -rf "$1.old"; else if [ -d "$1.old" ]; then mv "$1.old" "$1"; fi; exit 1; fi'
	run({ "sh", "-c", script, "sh", p.cache, p.staging }, {}, function(r)
		cb(r.status == 0, if r.status == 0 then nil else tail(r.stderr ~= "" and r.stderr or "the new login could not be moved into place", 2))
	end)
end

-- What identifies OUR spotifyd runs in `pkill -f`: the staging path is in their command line and nothing
-- else uses it. Escaped, as pkill takes a regular expression.
local function staging_pattern(p: Paths): string
	return (string.gsub(p.staging, ".", function(c)
		if string.find("\\^$.[]()*+?{}|", c, 1, true) then
			return "\\" .. c
		end
		return c
	end))
end

-- Stops a pairing or browser sign-in run (both write to staging). Exit 1 means no process matched: it
-- had already ended.
function M.cancel_pairing(cb: () -> ())
	local p = M.paths()
	if not p then
		cb()
		return
	end
	run({ "pkill", "-f", "--", staging_pattern(p) }, {}, function()
		cb()
	end)
end

-- Pairing from the phone: a bounded spotifyd with discovery on, writing to the staging directory, so
-- "Tern" shows in Spotify Connect. It ends by itself after PAIR_TIMEOUT_MS, or by `cancel_pairing`.
-- Never run it next to the agent: two devices would carry the same name. `done` gets the process's
-- result when it ends.
function M.pair(done: (Result) -> ()): boolean
	local p, bin = M.paths(), M.find_binary()
	if not p or not bin then
		return false
	end
	remove_paths({ p.staging })
	local ok = pcall(tern.fs.mkdir, p.staging)
	if not ok then
		return false
	end
	run(M.args(bin, p.staging, true), { timeout_ms = M.PAIR_TIMEOUT_MS }, done)
	return true
end

-- Browser sign-in: `spotifyd authenticate` prints a URL, waits for the redirect on 127.0.0.1:PORT and
-- stores the credentials in the staging directory. It writes to a log so the URL can be read while it
-- runs (a process result only arrives at exit). Paths go in as arguments, not into the script, so spaces
-- are safe.
function M.authenticate(done: (Result) -> ()): boolean
	local p, bin = M.paths(), M.find_binary()
	if not p or not bin then
		return false
	end
	remove_paths({ p.staging })
	local ok = pcall(function()
		tern.fs.mkdir(p.staging)
		tern.fs.write(p.oauth_log, "")
	end)
	if not ok then
		return false
	end
	run({ "sh", "-c", 'exec "$1" authenticate --oauth-port "$2" --cache-path "$3" >"$4" 2>&1 </dev/null', "sh", bin, tostring(M.OAUTH_PORT), p.staging, p.oauth_log }, { timeout_ms = M.OAUTH_TIMEOUT_MS }, done)
	return true
end

-- The sign-in address, once spotifyd has printed it.
function M.oauth_url(): string?
	local p = M.paths()
	if not p then
		return nil
	end
	local ok, text = pcall(tern.fs.read, p.oauth_log, 65536)
	if not ok then
		return nil
	end
	return string.match(text, "Browse to:%s*(https://%S+)")
end

return M
