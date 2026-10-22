--!strict
-- The refresh token in the macOS login Keychain, through /usr/bin/security (host half: `tern.secrets` is
-- window-only, and in a headless session it lives in memory). One item, service SERVICE, account ACCOUNT.
--
-- * The token never goes on argv (visible in `ps`): it is written as hex, in a command fed to `security -i`
--   on stdin. `-i` tokenizes its input like a shell, which is why hex (`-X`) and not the text.
-- * `security -i` does not report failures reliably, so every write is read back and compared.
-- * Every operation runs through one FIFO queue, so a delete can never overtake the write before it.
-- * A locked Keychain does not fail, it shows a dialog and waits: calls time out, and after a timeout no
--   more `security` runs until `reset` (a new sign-in attempt), so dialogs do not pile up.
-- * Errors are fixed strings plus an exit code: never what `security` printed, which could hold the token.

local M = {}

M.SERVICE = "so.tern-spotify.refresh-token"
M.ACCOUNT = "spotify"

local SECURITY = "/usr/bin/security"
local TIMEOUT_MS = 8000
local NOT_FOUND = 44 -- errSecItemNotFound
local LOCKED = "The macOS Keychain is locked or not answering: unlock it, then sign in again."
local UNAVAILABLE = "The macOS Keychain could not be run."
local NOT_SAVED = "The sign-in could not be saved in the macOS Keychain."

export type Store = {
	keychain: string?, -- a keychain file instead of the default search list (tests and smoke runs only)
	queue: { (done: () -> ()) -> () },
	running: boolean,
	blocked: string?, -- why no `security` runs any more
}

function M.new(keychain: string?): Store
	if keychain ~= nil and string.find(keychain, "^[%w/%._%-]+$") == nil then
		error("keychain path: only letters, digits and / . _ - are supported")
	end
	return { keychain = keychain, queue = {}, running = false, blocked = nil }
end

M.default = M.new(nil)

-- What a refresh token looks like (base64url); anything else is refused rather than put on a command line.
function M.valid(token: any): boolean
	return type(token) == "string" and #token > 0 and #token <= 2048 and string.find(token, "^[%w%-_%.~%+/=]+$") ~= nil
end

function M.hex(text: string): string
	return (string.gsub(text, ".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

-- Command builders (pure). `-U` updates the item when it exists.
function M.write_script(token: string, keychain: string?): string
	local line = `add-generic-password -U -s {M.SERVICE} -a {M.ACCOUNT} -X {M.hex(token)}`
	if keychain then
		line ..= " " .. keychain
	end
	return line .. "\n"
end

function M.read_argv(keychain: string?): { string }
	local argv = { SECURITY, "find-generic-password", "-s", M.SERVICE, "-a", M.ACCOUNT, "-w" }
	if keychain then
		table.insert(argv, keychain)
	end
	return argv
end

function M.delete_argv(keychain: string?): { string }
	local argv = { SECURITY, "delete-generic-password", "-s", M.SERVICE, "-a", M.ACCOUNT }
	if keychain then
		table.insert(argv, keychain)
	end
	return argv
end

-- Queue ----------------------------------------------------------------------------------------

local function pump(s: Store)
	if s.running then
		return
	end
	local job = table.remove(s.queue, 1)
	if not job then
		return
	end
	s.running = true
	job(function()
		s.running = false
		pump(s)
	end)
end

local function enqueue(s: Store, job: (done: () -> ()) -> ())
	table.insert(s.queue, job)
	pump(s)
end

-- A new attempt by the user: `security` may run again after a timeout.
function M.reset(s: Store)
	s.blocked = nil
end

-- The steps below run inside a queued job, never on their own. -----------------------------------

local function run(argv: { string }, stdin: string?, cb: (ProcessResult?) -> ())
	local answered = false
	local ok = pcall(function()
		tern.process.run(argv, { stdin = stdin, timeout_ms = TIMEOUT_MS }, function(r)
			answered = true
			cb(r)
		end)
	end)
	if not ok and not answered then -- the spawn itself failed: never a second answer after a real one
		cb(nil)
	end
end

-- The token held, nil when there is none (second result: why it could not be read).
local function read(s: Store, cb: (string?, string?) -> ())
	if s.blocked then
		cb(nil, s.blocked)
		return
	end
	run(M.read_argv(s.keychain), nil, function(r)
		if not r then
			cb(nil, UNAVAILABLE)
		elseif r.timed_out then
			s.blocked = LOCKED
			cb(nil, LOCKED)
		elseif r.status == 0 then
			local token = string.gsub(r.stdout, "\n$", "")
			cb(if token == "" then nil else token, nil)
		elseif r.status == NOT_FOUND then
			cb(nil, nil)
		else
			cb(nil, `The macOS Keychain could not be read (security exit {r.status}).`)
		end
	end)
end

local function write(s: Store, token: string, cb: (boolean, string?) -> ())
	if not M.valid(token) then
		cb(false, "Spotify sent a token in a form that is not saved.")
		return
	end
	if s.blocked then
		cb(false, s.blocked)
		return
	end
	run({ SECURITY, "-i" }, M.write_script(token, s.keychain), function(r)
		if not r then
			cb(false, UNAVAILABLE)
		elseif r.timed_out then
			s.blocked = LOCKED
			cb(false, LOCKED)
		else
			-- Whatever `security -i` said, the Keychain is the judge.
			read(s, function(now, err)
				if now == token then
					cb(true, nil)
				else
					cb(false, err or NOT_SAVED)
				end
			end)
		end
	end)
end

local function remove(s: Store, cb: (boolean, string?) -> ())
	if s.blocked then
		cb(false, s.blocked)
		return
	end
	run(M.delete_argv(s.keychain), nil, function(r)
		if not r then
			cb(false, UNAVAILABLE)
		elseif r.timed_out then
			s.blocked = LOCKED
			cb(false, LOCKED)
		elseif r.status == 0 or r.status == NOT_FOUND then
			cb(true, nil)
		else
			cb(false, `The sign-in could not be removed from the macOS Keychain (security exit {r.status}).`)
		end
	end)
end

-- Public ---------------------------------------------------------------------------------------

-- Each job frees the queue before it calls back, so a callback that raises cannot wedge it.

-- cb(token, err): no item is (nil, nil); an unreadable Keychain is (nil, why).
function M.get(s: Store, cb: (string?, string?) -> ())
	enqueue(s, function(done)
		read(s, function(token, err)
			done()
			cb(token, err)
		end)
	end)
end

-- Writes `token` and reads it back; cb(ok, why not).
function M.set(s: Store, token: string, cb: (boolean, string?) -> ())
	enqueue(s, function(done)
		write(s, token, function(ok, err)
			done()
			cb(ok, err)
		end)
	end)
end

function M.delete(s: Store, cb: (boolean, string?) -> ())
	enqueue(s, function(done)
		remove(s, function(ok, err)
			done()
			cb(ok, err)
		end)
	end)
end

-- Removes the item only while it still holds `token` (another pane may have stored a newer one meanwhile).
-- cb(removed, what the item holds now, why it could not be read or removed).
function M.delete_if(s: Store, token: string, cb: (boolean, string?, string?) -> ())
	enqueue(s, function(done)
		read(s, function(current, err)
			if current ~= token then
				done()
				cb(false, current, err)
				return
			end
			remove(s, function(ok, rerr)
				done()
				cb(ok, nil, rerr)
			end)
		end)
	end)
end

return M
