--!strict
-- Spotify Web API client: Authorization Code + PKCE sign-in, token refresh, and the
-- player/search calls the block uses. Host half only (needs tern.fetch/process/kv). The refresh token lives
-- in the macOS Keychain (secret.luau); kv keeps only what is not secret.

local pkce = require("./pkce")
local secret = require("./secret")

local M = {}

local AUTH_URL = "https://accounts.spotify.com/authorize"
local TOKEN_URL = "https://accounts.spotify.com/api/token"
local API = "https://api.spotify.com/v1"

-- Two ways to sign in, each with its own loopback redirect (Spotify only accepts http for loopback IP
-- literals, not "localhost"; the URI must match what is registered for the client id):
--   own       an app the user registered (the redirect goes in that app's settings)
--   keymaster the client id of Spotify's desktop app, which librespot (and so spotifyd) presents itself
--             as. Unofficial: see the README before offering it. 8000/login is the redirect that flow uses.
export type AuthMode = "own" | "keymaster"
M.KEYMASTER_CLIENT_ID = "65b708073fc0480ea92a077233ca87bd"
local REDIRECTS: { [string]: { port: number, path: string } } = {
	own = { port = 43821, path = "/callback" },
	keymaster = { port = 8000, path = "/login" },
}
M.SCOPES = "user-read-playback-state user-modify-playback-state"

function M.port(mode: AuthMode): number
	return REDIRECTS[mode].port
end

function M.redirect_uri(mode: AuthMode): string
	local r = REDIRECTS[mode]
	return `http://127.0.0.1:{r.port}{r.path}`
end

export type Reply = {
	ok: boolean,
	status: number, -- HTTP status; 0 when no response arrived
	json: any?,
	err: string?,
	reason: string?, -- Spotify's error.reason, e.g. NO_ACTIVE_DEVICE, PREMIUM_REQUIRED, QUOTA_EXCEEDED
	retry_after: number?, -- seconds, from a 429
	auth: boolean?, -- the refresh token is missing or was rejected: sign in again
}

export type Client = {
	client_id: string,
	mode: AuthMode,
	token: string?,
	expires: number, -- tern.now() deadline for `token`
	waiting: { (err: string?, auth: boolean?) -> () }?, -- callers parked on an in-flight refresh
	retry_until: number, -- tern.now() before which Spotify asked us not to call (a 429's Retry-After)
	retry_reason: string?, -- the reason that 429 gave (QUOTA_EXCEEDED reads differently)
	epoch: number, -- bumped when the sign-in ends here: answers to older requests are dropped, not stored
	mem: string?, -- the refresh token last seen, used only while the Keychain cannot be read or has never held it
	mem_gen: number, -- the sign-out count when `mem` was taken: a token from before a sign-out is not used
	loading: { (has: boolean, warn: string?) -> () }?, -- callers parked on the first read of the token
	warn: string?, -- why the sign-in is not (or not safely) saved, for the block to show
	unsaved: boolean, -- the token in `mem` is not in the Keychain yet: saving is tried again on each refresh
}

export type Login = { url: string, verifier: string, state: string }
export type Callback = { code: string?, state: string?, error: string? }

export type Track = {
	uri: string,
	name: string,
	artists: string,
	album: string,
	duration_ms: number,
	art_url: string?,
	link: string?,
	playable: boolean?, -- is_playable: only present when the request carried a market
	restriction: string?, -- restrictions.reason of an unplayable track ("market", "product", "explicit")
	linked_uri: string?, -- linked_from.uri: the track was relinked, this is the uri that was asked for
	album_uri: string?, -- the album it is on: playing it by context works where a bare `uris` doesn't
}

export type Device = {
	id: string?,
	name: string,
	kind: string,
	active: boolean,
	volume: number?,
	volume_ok: boolean,
	restricted: boolean,
}

export type Playback = {
	track: Track?,
	playing: boolean,
	progress_ms: number,
	at: number, -- tern.now() when progress_ms was read
	shuffle: boolean,
	repeat_mode: string, -- off | context | track
	device: Device?,
}

-- Encoding -------------------------------------------------------------------------------------

function M.encode(s: string): string
	return (string.gsub(s, "[^%w%-._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function decode(s: string): string
	local plus = string.gsub(s, "%+", " ")
	return (string.gsub(plus, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- `k=v&k=v` from an ordered list of pairs.
function M.query(pairs: { { string } }): string
	local out = {}
	for _, kv in pairs do
		table.insert(out, M.encode(kv[1]) .. "=" .. M.encode(kv[2]))
	end
	return table.concat(out, "&")
end

-- Replies --------------------------------------------------------------------------------------

local function normalize(r: FetchResult): Reply
	if r.error then
		return { ok = false, status = 0, err = "Network error: " .. r.error }
	end
	local json: any = nil
	if r.body ~= "" then
		local ok, decoded = pcall(tern.json.decode, r.body)
		if ok then
			json = decoded
		end
	end
	if r.status >= 200 and r.status < 300 then
		return { ok = true, status = r.status, json = json }
	end
	-- Web API: {"error": {"status", "message", "reason"?}}; accounts API: {"error": "invalid_grant", "error_description"}.
	local message: string? = nil
	local reason: string? = nil
	if type(json) == "table" then
		local e = json.error
		if type(e) == "table" then
			message, reason = e.message, e.reason
		elseif type(e) == "string" then
			message, reason = json.error_description or e, e
		end
	end
	return {
		ok = false,
		status = r.status,
		err = message or `HTTP {r.status}`,
		reason = reason,
		retry_after = tonumber(r.headers["retry-after"]),
	}
end

-- Tokens ---------------------------------------------------------------------------------------

-- Bumped by every sign-out (any pane): a refresh that began before it must not store its rotated token.
local signed_out = 0

function M.new(client_id: string, mode: AuthMode): Client
	return {
		client_id = client_id,
		mode = mode,
		token = nil,
		expires = 0,
		waiting = nil,
		retry_until = 0,
		retry_reason = nil,
		epoch = 0,
		mem = nil,
		mem_gen = 0,
		loading = nil,
		warn = nil,
		unsaved = false,
	}
end

-- Milliseconds still to wait because of a 429 (0: none).
function M.retry_in(c: Client): number
	return math.max(0, c.retry_until - tern.now())
end

-- The refresh token an earlier version left in kv.json (nil when there is none).
local function legacy_token(): string?
	local rt = tern.kv.get("refresh_token")
	if type(rt) == "string" and rt ~= "" then
		return rt
	end
	return nil
end

-- Removes that old copy (only if it is `token`, when one is given).
local function drop_legacy(token: string?)
	local rt = legacy_token()
	if rt and (token == nil or rt == token) then
		tern.kv.set("refresh_token", nil)
	end
end

-- Finds the saved sign-in: the Keychain's token, else the one an earlier version kept in kv.json, which is
-- moved to the Keychain (and removed from kv.json only once it reads back). cb(has, warning): a warning
-- means the sign-in works but is not safely saved. Callers that arrive meanwhile share the answer.
function M.load(c: Client, cb: (boolean, string?) -> ())
	if c.loading then
		table.insert(c.loading, cb)
		return
	end
	c.loading = { cb }
	local epoch = c.epoch
	local gen0 = signed_out -- a sign-out while the Keychain is being read makes what it returned stale
	local function done(has: boolean, warn: string?)
		local parked: { (boolean, string?) -> () } = c.loading or {}
		c.loading = nil
		for _, waiter in parked do
			waiter(has, warn)
		end
	end
	secret.get(secret.default, function(token, err)
		if c.epoch ~= epoch then
			done(false, nil)
			return
		end
		if token then
			c.mem, c.mem_gen, c.unsaved, c.warn = token, gen0, false, nil
			drop_legacy(nil) -- the Keychain is the truth: an old plaintext copy has no reason to stay
			done(true, nil)
			return
		end
		local old = legacy_token()
		if not old then
			c.warn = err
			done(false, err)
			return
		end
		c.mem, c.mem_gen = old, gen0
		c.unsaved = true -- saved again by the next refresh, once the Keychain answers
		if err then
			c.warn = err .. " The sign-in saved by an earlier version is used meanwhile."
			done(true, c.warn)
			return
		end
		secret.set(secret.default, old, function(ok, serr)
			if c.epoch ~= epoch then
				done(false, nil)
			elseif ok then
				drop_legacy(old)
				c.unsaved, c.warn = false, nil
				done(true, nil)
			else
				c.warn = serr
				done(true, serr)
			end
		end)
	end)
end

-- Scopes Spotify actually granted (its token replies list them). Empty until the first token reply.
function M.has_scope(name: string): boolean
	local granted = tern.kv.get("scope")
	return type(granted) == "string" and string.find(" " .. granted .. " ", " " .. name .. " ", 1, true) ~= nil
end

-- Forgets the saved sign-in: the Keychain item and any copy an earlier version left in kv.json. cb hears
-- whether the Keychain item is gone. Refreshes that started earlier, in any pane, no longer save their token.
function M.forget(cb: ((boolean, string?) -> ())?)
	signed_out += 1
	tern.kv.set("refresh_token", nil)
	tern.kv.set("scope", nil)
	secret.delete(secret.default, function(ok, err)
		if cb then
			cb(ok, err)
		end
	end)
end

-- This client no longer holds a sign-in (a replacement is taking over, or the user signed out).
function M.retire(c: Client)
	c.epoch += 1
	c.token, c.expires, c.mem, c.unsaved, c.warn = nil, 0, nil, false, nil
end

function M.sign_out(c: Client, cb: ((boolean, string?) -> ())?)
	M.retire(c)
	M.forget(cb)
end

local function token_request(form: { { string } }, cb: (Reply) -> ())
	tern.fetch(TOKEN_URL, {
		method = "POST",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = M.query(form),
		timeout_ms = 15000,
	}, function(r)
		cb(normalize(r))
	end)
end

-- The access token stays in memory only, with the scopes Spotify granted.
local function store_access(c: Client, json: any): boolean
	if type(json) ~= "table" or type(json.access_token) ~= "string" then
		return false
	end
	c.token = json.access_token
	-- Renew a minute early so a request never leaves with a token about to lapse.
	c.expires = tern.now() + (tonumber(json.expires_in) or 3600) * 1000 - 60000
	if type(json.scope) == "string" then
		tern.kv.set("scope", json.scope)
	end
	return true
end

-- The refresh token is the one secret that persists, in the Keychain. A failure keeps it in memory (the
-- session works) and says so in `c.warn`; it is never written to kv.json. `epoch` is the client's when
-- the request that brought the token started; callers have just checked it, and the answer from the
-- Keychain is dropped if the sign-in ended meanwhile.
local function persist(c: Client, epoch: number, token: string, cb: (() -> ())?)
	c.mem, c.mem_gen = token, signed_out
	secret.set(secret.default, token, function(ok, err)
		if c.epoch == epoch then
			c.unsaved = not ok
			c.warn = if ok then nil else err
			if ok then
				drop_legacy(nil)
			end
		end
		if cb then
			cb()
		end
	end)
end

local function store(c: Client, json: any, epoch: number)
	if c.epoch ~= epoch or not store_access(c, json) then
		return
	end
	if type(json.refresh_token) == "string" and json.refresh_token ~= "" then
		persist(c, epoch, json.refresh_token, nil)
	elseif c.unsaved and c.mem then
		persist(c, epoch, c.mem, nil) -- a refresh that brought no new token still retries the save
	end
end

local function refresh(c: Client, cb: (string?, boolean?) -> ())
	if c.waiting then
		table.insert(c.waiting, cb)
		return
	end
	c.waiting = { cb }
	local epoch = c.epoch
	local gen = signed_out -- another pane's sign-out after this point must not be undone by this refresh
	local function finish(err: string?, auth: boolean?)
		local parked: { (string?, boolean?) -> () } = c.waiting or {}
		c.waiting = nil
		for _, waiter in parked do
			waiter(err, auth)
		end
	end
	local function request(rt: string, retried: boolean)
		token_request({ { "grant_type", "refresh_token" }, { "refresh_token", rt }, { "client_id", c.client_id } }, function(reply)
			if c.epoch ~= epoch then
				finish("Not signed in", true)
				return
			end
			if reply.ok then
				if signed_out ~= gen then -- another pane signed out while this was on the wire: nothing is kept
					c.mem, c.unsaved = nil, false
					finish("Not signed in", true)
					return
				end
				c.mem, c.mem_gen = rt, gen
				store(c, reply.json, epoch)
				finish(nil, nil)
				return
			end
			local err = reply.err or "Token refresh failed"
			-- 400/401 means the refresh token (or client id) is no good; a network error or 5xx doesn't.
			if reply.status ~= 400 and reply.status ~= 401 then
				finish(err, nil)
				return
			end
			-- Another pane may have stored a newer token since: try that one once. Otherwise forget this one,
			-- and only if it is still what is saved.
			secret.get(secret.default, function(current)
				if c.epoch ~= epoch then
					finish("Not signed in", true)
				elseif current and current ~= rt and not retried then
					request(current, true)
				else
					secret.delete_if(secret.default, rt, function() end)
					drop_legacy(rt)
					c.mem = nil
					finish(err, true)
				end
			end)
		end)
	end
	secret.get(secret.default, function(token, gerr)
		if c.epoch ~= epoch then
			finish("Not signed in", true)
			return
		end
		-- Memory stands in when the Keychain cannot be read, or when the token was never saved there; if the
		-- Keychain answers "nothing" for a token it did hold, the sign-in was removed (from another pane, say)
		-- and this one is signed out too. A token from before a sign-out (in any pane) is not used.
		local mem = if c.mem and c.mem_gen == signed_out then c.mem else nil
		local stale = c.mem ~= nil and mem == nil -- the only candidate predates a sign-out: signed out, not an error to retry
		local rt = token or (if gerr or c.unsaved then mem else nil) or legacy_token()
		if rt then
			request(rt, false)
		elseif stale then
			c.mem = nil
			finish("Not signed in", true)
		else
			finish(gerr or "Not signed in", if gerr then nil else true)
		end
	end)
end

local function ensure_token(c: Client, cb: (string?, boolean?) -> ())
	if c.token and tern.now() < c.expires then
		cb(nil, nil)
	else
		refresh(c, cb)
	end
end

-- Calls the Web API. `body` is JSON-encoded; write calls without one still send an empty body
-- so they carry Content-Length. A 401 with a token we thought valid refreshes once and retries.
-- After a 429 nothing is sent until its Retry-After has passed: the caller gets a 429 of its own, with the
-- time that is left, one timer tick later (never inside the call: callers touch their state right after it).
function M.request(c: Client, method: string, path: string, query: { { string } }?, body: any?, cb: (Reply) -> ())
	local wait = M.retry_in(c)
	if wait > 0 then
		tern.timer(0, function()
			cb({ ok = false, status = 429, err = "HTTP 429", reason = c.retry_reason, retry_after = math.ceil(wait / 1000) })
		end)
		return
	end
	local function attempt(retry: boolean)
		ensure_token(c, function(err, auth)
			if err then
				cb({ ok = false, status = 0, err = err, auth = auth })
				return
			end
			local url = API .. path
			if query and #query > 0 then
				url ..= "?" .. M.query(query)
			end
			local headers: { [string]: string } = { Authorization = "Bearer " .. (c.token or "") }
			local payload: string? = nil
			if body ~= nil then
				headers["Content-Type"] = "application/json"
				payload = tern.json.encode(body)
			elseif method ~= "GET" then
				payload = ""
			end
			tern.fetch(url, { method = method, headers = headers, body = payload, timeout_ms = 10000 }, function(r)
				local reply = normalize(r)
				if reply.status == 401 and retry then
					c.token = nil
					attempt(false)
				else
					if reply.status == 429 then
						local until_ms = tern.now() + (reply.retry_after or 30) * 1000
						if until_ms > c.retry_until then
							c.retry_until, c.retry_reason = until_ms, reply.reason
						end
					end
					if not reply.ok then
						-- Path only: the query can hold what the user searched for, never the token.
						tern.log.warn("spotify", method, path, reply.status, reply.reason or "", reply.err or "")
					end
					cb(reply)
				end
			end)
		end)
	end
	attempt(true)
end

-- Sign-in --------------------------------------------------------------------------------------

-- 81 random bytes -> 108 base64url characters: an 86-char code verifier and a 22-char state.
local RANDOM = "head -c 81 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\\n'"

function M.begin_login(c: Client, cb: (Login?, string?) -> ())
	local ok, spawn_err = pcall(function()
		tern.process.run({ "sh", "-c", RANDOM }, { timeout_ms = 5000 }, function(r)
			if r.status ~= 0 or #r.stdout ~= 108 then
				cb(nil, "Could not read random bytes: " .. (if r.stderr ~= "" then r.stderr else `status {r.status}`))
				return
			end
			local verifier, state = string.sub(r.stdout, 1, 86), string.sub(r.stdout, 87, 108)
			local url = AUTH_URL
				.. "?"
				.. M.query({
					{ "client_id", c.client_id },
					{ "response_type", "code" },
					{ "redirect_uri", M.redirect_uri(c.mode) },
					{ "code_challenge_method", "S256" },
					{ "code_challenge", pkce.challenge(verifier) },
					{ "scope", M.SCOPES },
					{ "state", state },
				})
			cb({ url = url, verifier = verifier, state = state }, nil)
		end)
	end)
	if not ok then
		cb(nil, tostring(spawn_err))
	end
end

-- Reads `code`, `state` and `error` from a callback: a full URL, a request target, a bare query,
-- or an HTTP request line. Nil when it carries neither a code nor an error.
function M.parse_callback(text: string): Callback?
	local q = "&" .. (string.match(text, "%?(.*)") or text)
	local function param(name: string): string?
		local v = string.match(q, "&" .. name .. "=([^&%s#]*)")
		return if v and v ~= "" then decode(v) else nil
	end
	local code, state, err = param("code"), param("state"), param("error")
	if not code and not err then
		return nil
	end
	return { code = code, state = state, error = err }
end

local PAGE = "<!doctype html><meta charset=utf-8><title>Tern Spotify</title>"
	.. "<body style=\"font:16px system-ui;margin:3em\"><h2>Back to Tern</h2>"
	.. "<p>You can close this tab.</p></body>"
local RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: "
	.. #PAGE
	.. "\r\n\r\n"
	.. PAGE

-- Serves one HTTP request on the loopback redirect port with `nc` and hands back its target
-- ("/callback?code=..."), or "" when it carried none. `err` is set when nothing was served
-- (port busy, no nc, timeout), so the caller can fall back to pasting the redirect URL.
function M.listen(mode: AuthMode, timeout_ms: number, cb: (target: string?, err: string?) -> ())
	local ok, spawn_err = pcall(function()
		tern.process.run(
			{ "nc", "-l", "127.0.0.1", tostring(M.port(mode)) },
			{ stdin = RESPONSE, timeout_ms = math.max(1000, timeout_ms) },
			function(r)
				if r.timed_out then
					cb(nil, "timeout")
				elseif r.status ~= 0 then
					cb(nil, if r.stderr ~= "" then (string.gsub(r.stderr, "%s+$", "")) else `nc exited {r.status}`)
				else
					cb(string.match(r.stdout, "^%u+ (%S+)") or "", nil)
				end
			end
		)
	end)
	if not ok then
		cb(nil, tostring(spawn_err))
	end
end

-- Connects to our own listener so a pending `nc` finishes and frees the port.
function M.release_listener(mode: AuthMode)
	tern.fetch(`http://127.0.0.1:{M.port(mode)}/`, { timeout_ms = 2000 }, function() end)
end

function M.exchange(c: Client, code: string, verifier: string, cb: (Reply) -> ())
	local epoch = c.epoch
	token_request({
		{ "grant_type", "authorization_code" },
		{ "code", code },
		{ "redirect_uri", M.redirect_uri(c.mode) },
		{ "client_id", c.client_id },
		{ "code_verifier", verifier },
	}, function(reply)
		if c.epoch ~= epoch then
			cb({ ok = false, status = 0, err = "Not signed in" })
			return
		end
		if not reply.ok then
			cb(reply)
			return
		end
		local rt = if type(reply.json) == "table" then reply.json.refresh_token else nil
		if type(rt) ~= "string" or rt == "" or not store_access(c, reply.json) then
			cb({ ok = false, status = reply.status, err = "Spotify returned no refresh token" })
			return
		end
		-- The sign-in works once the token is in memory; whether it is also saved is `c.warn`'s to say.
		persist(c, epoch, rt, function()
			cb(reply)
		end)
	end)
end

-- Models ---------------------------------------------------------------------------------------

-- The smallest image that is at least 300px wide, else the largest one.
local function pick_art(images: any): string?
	if type(images) ~= "table" then
		return nil
	end
	local best: string? = nil
	local best_w = 0
	for _, img in images do
		if type(img.url) == "string" then
			local w = tonumber(img.width) or 0
			local better: boolean
			if best == nil then
				better = true
			elseif w >= 300 and best_w >= 300 then
				better = w < best_w
			elseif w >= 300 then
				better = true
			elseif best_w >= 300 then
				better = false
			else
				better = w > best_w
			end
			if better then
				best, best_w = img.url, w
			end
		end
	end
	return best
end

function M.parse_track(item: any): Track?
	if type(item) ~= "table" or type(item.uri) ~= "string" then
		return nil
	end
	local artists = {}
	local album = ""
	local images: any = nil
	if type(item.artists) == "table" then
		for _, a in item.artists do
			table.insert(artists, tostring(a.name))
		end
	end
	if type(item.album) == "table" then
		album, images = tostring(item.album.name or ""), item.album.images
	elseif type(item.show) == "table" then -- a podcast episode
		album, images = tostring(item.show.name or ""), item.images or item.show.images
	end
	local link: string? = nil
	if type(item.external_urls) == "table" and type(item.external_urls.spotify) == "string" then
		link = item.external_urls.spotify
	end
	return {
		uri = item.uri,
		name = tostring(item.name or "?"),
		artists = table.concat(artists, ", "),
		album = album,
		duration_ms = tonumber(item.duration_ms) or 0,
		art_url = pick_art(images),
		link = link,
		playable = if type(item.is_playable) == "boolean" then item.is_playable else nil,
		restriction = if type(item.restrictions) == "table" and type(item.restrictions.reason) == "string" then item.restrictions.reason else nil,
		linked_uri = if type(item.linked_from) == "table" and type(item.linked_from.uri) == "string" then item.linked_from.uri else nil,
		album_uri = if type(item.album) == "table" and type(item.album.uri) == "string" then item.album.uri else nil,
	}
end

-- What to send to start `t`. Spotify's own apps play a track inside its album; asking the desktop app for
-- a bare `uris` list is accepted (204) and leaves it with nothing loaded, so use the album as the context.
function M.play_body(t: Track): any
	if t.album_uri then
		return { context_uri = t.album_uri, offset = { uri = t.uri } }
	end
	return { uris = { t.uri } }
end

function M.parse_device(d: any): Device?
	if type(d) ~= "table" then
		return nil
	end
	return {
		id = if type(d.id) == "string" then d.id else nil,
		name = tostring(d.name or "?"),
		kind = tostring(d.type or ""),
		active = d.is_active == true,
		volume = tonumber(d.volume_percent),
		volume_ok = d.supports_volume ~= false,
		restricted = d.is_restricted == true,
	}
end

-- Nil when nothing is active (HTTP 204).
function M.parse_playback(json: any): Playback?
	if type(json) ~= "table" then
		return nil
	end
	return {
		track = M.parse_track(json.item),
		playing = json.is_playing == true,
		progress_ms = tonumber(json.progress_ms) or 0,
		at = tern.now(),
		shuffle = json.shuffle_state == true,
		repeat_mode = if type(json.repeat_state) == "string" then json.repeat_state else "off",
		device = M.parse_device(json.device),
	}
end

function M.parse_devices(json: any): { Device }
	local out: { Device } = {}
	if type(json) == "table" and type(json.devices) == "table" then
		for _, d in json.devices do
			local device = M.parse_device(d)
			if device then
				table.insert(out, device)
			end
		end
	end
	return out
end

function M.parse_tracks(json: any): { Track }
	local out: { Track } = {}
	if type(json) == "table" and type(json.tracks) == "table" and type(json.tracks.items) == "table" then
		for _, item in json.tracks.items do
			local track = M.parse_track(item)
			if track then
				table.insert(out, track)
			end
		end
	end
	return out
end

return M
