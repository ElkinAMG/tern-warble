--!strict
-- Spotify Web API client: Authorization Code + PKCE sign-in, token refresh, and the
-- player/search calls the block uses. Host half only (needs tern.fetch/process/kv).

local pkce = require("./pkce")

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

function M.new(client_id: string, mode: AuthMode): Client
	return { client_id = client_id, mode = mode, token = nil, expires = 0, waiting = nil, retry_until = 0, retry_reason = nil }
end

-- Milliseconds still to wait because of a 429 (0: none).
function M.retry_in(c: Client): number
	return math.max(0, c.retry_until - tern.now())
end

function M.has_refresh_token(): boolean
	local rt = tern.kv.get("refresh_token")
	return type(rt) == "string" and rt ~= ""
end

-- Scopes Spotify actually granted (its token replies list them). Empty until the first token reply.
function M.has_scope(name: string): boolean
	local granted = tern.kv.get("scope")
	return type(granted) == "string" and string.find(" " .. granted .. " ", " " .. name .. " ", 1, true) ~= nil
end

function M.sign_out(c: Client)
	c.token = nil
	c.expires = 0
	tern.kv.set("refresh_token", nil)
	tern.kv.set("scope", nil)
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

-- Keeps the access token in memory only; the refresh token is the one secret that persists.
local function store(c: Client, json: any)
	if type(json) ~= "table" or type(json.access_token) ~= "string" then
		return
	end
	c.token = json.access_token
	-- Renew a minute early so a request never leaves with a token about to lapse.
	c.expires = tern.now() + (tonumber(json.expires_in) or 3600) * 1000 - 60000
	if type(json.refresh_token) == "string" and json.refresh_token ~= "" then
		tern.kv.set("refresh_token", json.refresh_token)
	end
	if type(json.scope) == "string" then
		tern.kv.set("scope", json.scope)
	end
end

local function refresh(c: Client, cb: (string?, boolean?) -> ())
	if c.waiting then
		table.insert(c.waiting, cb)
		return
	end
	local rt = tern.kv.get("refresh_token")
	if type(rt) ~= "string" or rt == "" then
		cb("Not signed in", true)
		return
	end
	c.waiting = { cb }
	token_request({ { "grant_type", "refresh_token" }, { "refresh_token", rt }, { "client_id", c.client_id } }, function(reply)
		local parked: { (string?, boolean?) -> () } = c.waiting or {}
		c.waiting = nil
		local err: string? = nil
		local auth: boolean? = nil
		if reply.ok then
			store(c, reply.json)
		else
			-- 400/401 means the refresh token (or client id) is no good; a network error or 5xx doesn't.
			auth = reply.status == 400 or reply.status == 401
			if auth then
				tern.kv.set("refresh_token", nil)
			end
			err = reply.err or "Token refresh failed"
		end
		for _, waiter in parked do
			waiter(err, auth)
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
	token_request({
		{ "grant_type", "authorization_code" },
		{ "code", code },
		{ "redirect_uri", M.redirect_uri(c.mode) },
		{ "client_id", c.client_id },
		{ "code_verifier", verifier },
	}, function(reply)
		if reply.ok then
			store(c, reply.json)
			if not M.has_refresh_token() then
				reply = { ok = false, status = reply.status, err = "Spotify returned no refresh token" }
			end
		end
		cb(reply)
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
