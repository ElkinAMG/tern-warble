--!strict
-- Block `spotify-api.web-player`: a Spotify Web API remote control with cover art, transport, volume,
-- device picker and track search. State lives in the block; the sign-in's refresh token in the macOS Keychain
-- (secret.luau), the rest of the credentials in tern.kv (see spotify.luau).

local ui = tern.ui
local spotify = require("./spotify")
local secret = require("./secret")
local field = require("./field")
local bridge = require("./bridge")
local viz = require("./viz")
local spotifyd = require("./spotifyd")
local core = require("./ui/core")
local layout = require("./ui/panel")
local keycaps = require("./ui/keycaps")
local keyed_list = require("./ui/list").keyed
local with, click, hint = core.with, core.click, core.hint
local panel, header = layout.panel, layout.header
local node_path = core.node_path
-- The keys of the panels that hold an input or a list: they are part of those nodes' ids (core.node_path).
local BOX = { search = "search_box", devices = "devices_box", setup = "setup_box" }

type Mode = "player" | "search" | "devices" | "localplayer" | "help"
type Phase = "setup" | "login" | "loading" | "ready"

type Step = "menu" | "installing" | "pairing" | "oauth" | "saving" | "starting" | "removing" -- "menu": idle

-- The local player screen (see spotifyd.luau): what it is doing, and what it last found out.
type SD = {
	step: Step,
	status: spotifyd.Status?,
	visible: boolean?, -- "Tern" was in /me/player/devices at the last check (nil: not checked yet)
	url: string?, -- the browser sign-in address while one is waiting
	err: string?,
	gen: number, -- bumped to orphan a pairing / sign-in / start that was cancelled
	tried: boolean, -- a play was just redirected to the local player: don't loop if it fails again
	was_enabled: boolean, -- the agent was installed when a new sign-in began: put it back if that fails
	restoring: boolean, -- the agent that ran before a failed sign-in is being loaded again: don't start anything else meanwhile
}

type State = {
	phase: Phase,
	mode: Mode,
	client: spotify.Client?,
	client_id: string,
	auth: spotify.AuthMode, -- how this block signs in: the user's own Client ID, or Keymaster
	setup: "choose" | "own" | "keymaster", -- which setup screen is up while phase is "setup"
	id_field: field.Field,
	login: spotify.Login?,
	waiting: boolean, -- a sign-in listener is running
	gen: number, -- bumped to orphan a sign-in attempt
	playback: spotify.Playback?,
	art: { url: string, blob: string? }?,
	art_pending: string?,
	query: field.Field,
	focus: "input" | "list",
	results: { spotify.Track },
	searched: boolean,
	searching: boolean,
	sel: number,
	devices: { spotify.Device },
	dsel: number,
	err: string?,
	warn: string?, -- why the sign-in is not safely saved (the Keychain): shown until it is
	inflight: boolean, -- a /me/player poll is in flight
	ticking: boolean, -- the once-a-second tick has a timer waiting
	timer: TimerHandle?,
	ended_for: string?,
	expect: { track: spotify.Track, prev: spotify.Playback?, until_ms: number }?, -- a track we just asked Spotify to play, until it reports it
	cmd_err: string?, -- the `err` a command produced: polls must not wipe it
	pending: spotify.Track?, -- a track Spotify refused to play for lack of a device: the picker starts it
	market: boolean, -- send market=from_token (is_playable/restrictions/linked_from need a market); off once Spotify refuses it
	premute: number?,
	blobs: { [string]: string }, -- SVG blob ids by content key: a blob is sent once, then reused every render
	poll_fails: number, -- polls in a row that failed on the network or with a 5xx: each one waits longer
	debounce: { [string]: TimerHandle }, -- commands waiting to be sent once their key repeat stops, by name
	sent_at: { [string]: number }, -- when each debounced command last went out: older poll replies are stale for it
	sd: SD,
	shape: bridge.Shape, -- how the pane is shown (see bridge.shape): docked, glass card with focus, or the read-only glass card
}

local SIGNIN_TIMEOUT_MS = 180000
local POLL_PLAYING_MS = 5000
local POLL_IDLE_MS = 10000
local SETTLE_MS = 700 -- Spotify applies commands asynchronously; re-read this long after one
local EXPECT_MS = 6000 -- how long a requested track may take to show up in /me/player
local EXPECT_RETRY_MS = 1000
local COMMAND_DEBOUNCE_MS = 250 -- a held volume or seek key sends its last value once, not one request per repeat
local BACKOFF_FIRST_MS = 2000 -- after a failed poll (network, 5xx): retry in 2 s, then double up to the cap
local BACKOFF_MAX_MS = 60000

-- Keys that change the pane's layout, so the window half does them (see bridge.luau). Keyed by the
-- typed character, so shift+f (dock) differs from f (float). Each names a target state, not a toggle.
local WINDOW_KEYS: { [string]: string } = { z = "park", f = "float", F = "dock" }

-- Helpers --------------------------------------------------------------------------------------

-- Whether pane `pane` still runs; a finished block disappears from the list.
local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

-- Runs `fn` once, COMMAND_DEBOUNCE_MS after the last call that used `name`.
local function debounced(state: State, name: string, fn: () -> ())
	local waiting = state.debounce[name]
	if waiting then
		waiting:cancel()
	end
	state.debounce[name] = tern.timer(COMMAND_DEBOUNCE_MS, function()
		state.debounce[name] = nil
		state.sent_at[name] = tern.now()
		fn()
	end)
end

-- Drops the command `name` if it is still waiting for its key repeat to stop.
local function drop_debounced(state: State, name: string)
	local waiting: TimerHandle? = state.debounce[name]
	if waiting then
		waiting:cancel()
		state.debounce[name] = nil
	end
end

-- Drops every command still waiting for its key repeat to stop (the session they belong to is gone).
local function cancel_debounced(state: State)
	for name, waiting in state.debounce do
		waiting:cancel()
		state.debounce[name] = nil
	end
end

-- A press is newer than a poll reply if it still waits to go out, or went out after that poll was sent
-- (`started`): the reply then predates it and would put the old value back.
local function newer_than(state: State, name: string, started: number): boolean
	local waiting: TimerHandle? = state.debounce[name]
	return waiting ~= nil or (state.sent_at[name] or -1) >= started
end

-- Keeps on screen what the user pressed when the reply `pb` to a poll sent at `started` is older than that.
local function keep_pending(state: State, pb: spotify.Playback?, started: number)
	local shown = state.playback
	if not pb or not shown then
		return
	end
	if newer_than(state, "volume", started) and pb.device and shown.device and pb.device.id == shown.device.id then
		pb.device.volume = shown.device.volume
	end
	if newer_than(state, "seek", started) and pb.track and shown.track and pb.track.uri == shown.track.uri then
		pb.progress_ms, pb.at = shown.progress_ms, shown.at
	end
end

-- How long to wait after the `fails`-th failed poll in a row: 2 s, 4 s, 8 s ... up to a minute.
local function backoff_ms(fails: number): number
	return math.min(BACKOFF_FIRST_MS * 2 ^ (fails - 1), BACKOFF_MAX_MS)
end

-- Whether the player card is what the pane draws: the player screen, or the shortcuts screen in a pane that
-- can't take input (parked, or floating without focus), which keeps showing the song instead.
local function shows_player(state: State): boolean
	return state.mode == "player" or (state.mode == "help" and state.shape == "compact")
end

local function fmt_time(ms: number): string
	local total = math.max(0, math.floor(ms / 1000))
	return string.format("%d:%02d", total // 60, total % 60)
end

local function position(pb: spotify.Playback): number
	local ms = pb.progress_ms
	if pb.playing then
		ms += tern.now() - pb.at
	end
	local duration = if pb.track then pb.track.duration_ms else 0
	if duration > 0 and ms > duration then
		ms = duration
	end
	return math.max(0, ms)
end

local function describe(reply: spotify.Reply): string
	if reply.reason == "PREMIUM_REQUIRED" then
		return "Spotify Premium is required to control playback."
	elseif reply.status == 429 then
		if reply.reason == "QUOTA_EXCEEDED" then
			return "Spotify developer-mode quota exceeded; try again later."
		end
		return `Rate limited by Spotify; retrying in {reply.retry_after or 30}s.`
	end
	return reply.err or "Request failed"
end

-- Records a failed call. Returns false when the session is gone and nothing should be retried.
local function fail(state: State, reply: spotify.Reply): boolean
	if reply.auth then
		cancel_debounced(state)
		state.poll_fails = 0
		state.phase = "login"
		state.mode = "player"
		state.playback = nil
		state.err = "Signed out: " .. (reply.err or "session expired")
		return false
	end
	state.err = describe(reply)
	return true
end

local function focus_op(cx: BlockCx, id: string?)
	-- After the render that mounts (or drops) the field.
	tern.timer(30, function()
		local target: any = id or tern.json.null
		cx:frame({ { "focus", target } })
	end)
end

-- Polling --------------------------------------------------------------------------------------

local poll: (State, BlockCx) -> ()

local function schedule(state: State, cx: BlockCx, ms: number)
	if state.timer then
		state.timer:cancel()
	end
	state.timer = tern.timer(ms, function()
		state.timer = nil
		poll(state, cx)
	end)
end

local function load_art(state: State, cx: BlockCx, url: string)
	state.art_pending = url
	tern.fetch(url, { timeout_ms = 10000 }, function(r)
		if state.art_pending ~= url then
			return
		end
		state.art_pending = nil
		if not alive(cx.pane) then
			return
		end
		-- A failed download is remembered (blob = nil) so the next poll doesn't retry it forever.
		local blob: string? = nil
		if not r.error and r.status == 200 and #r.body > 0 then
			local mime = string.match(r.headers["content-type"] or "", "^[^;]+") or "image/jpeg"
			blob = cx:blob(r.body, mime)
		end
		state.art = { url = url, blob = blob }
		cx:render()
	end)
end

local tick: (State, BlockCx) -> ()

-- Starts the once-a-second tick unless one is already waiting. It runs only while a track plays, and
-- `apply` and `toggle` are the only places where that can begin.
local function start_tick(state: State, cx: BlockCx)
	if not state.ticking then
		state.ticking = true
		tern.timer(1000, function()
			tick(state, cx)
		end)
	end
end

local function apply(state: State, cx: BlockCx, pb: spotify.Playback?)
	state.playback = pb
	local track = if pb then pb.track else nil
	local url = if track then track.art_url else nil
	if url and (not state.art or state.art.url ~= url) and state.art_pending ~= url then
		load_art(state, cx, url)
	end
	if pb and pb.playing then
		start_tick(state, cx)
	end
end

-- market=from_token needs the user's country, i.e. the user-read-private scope. Spotify lists the scopes
-- it granted in every token reply, so ask only when we hold it (until a 400 says otherwise); without a
-- market, results still carry is_playable but no restrictions or linked_from.
local function sends_market(state: State): boolean
	return state.market and spotify.has_scope("user-read-private")
end

local function market_query(state: State, query: { { string } }): { { string } }
	local out = table.clone(query)
	if sends_market(state) then
		table.insert(out, { "market", "from_token" })
	end
	return out
end

-- Spotify's answer to a market it won't take.
local function market_refused(reply: spotify.Reply, sent: boolean): boolean
	return sent and not reply.ok and reply.status == 400
end

poll = function(state: State, cx: BlockCx)
	local client = state.client
	if not alive(cx.pane) or not client or (state.phase ~= "ready" and state.phase ~= "loading") then
		return
	end
	local wait = spotify.retry_in(client)
	if wait > 0 then
		schedule(state, cx, wait)
		return
	end
	if state.inflight then
		schedule(state, cx, 300)
		return
	end
	state.inflight = true
	local sent_market = sends_market(state)
	local started = tern.now()
	spotify.request(client, "GET", "/me/player", market_query(state, { { "additional_types", "track,episode" } }), nil, function(reply)
		state.inflight = false
		if not alive(cx.pane) then
			return
		end
		if state.client ~= client or (state.phase ~= "ready" and state.phase ~= "loading") then
			return -- the user went to the choice of sign-in method (or picked another) while this was in flight
		end
		if market_refused(reply, sent_market) then
			-- from_token isn't available to this token: poll without it.
			state.market = false
			tern.log.warn("spotify-api: market=from_token refused on /me/player, polling without:", reply.err or "")
			schedule(state, cx, 300)
			return
		end
		local keep_going = true
		local hold = false
		if reply.ok then
			if state.err ~= state.cmd_err then
				state.err = nil -- a command's error stays until the next command, so it can be read
			end
			state.phase = "ready"
			state.warn = client.warn
			local pb = spotify.parse_playback(reply.json)
			keep_pending(state, pb, started)
			local e = state.expect
			if e then
				local arrived = pb ~= nil and pb.track ~= nil and (pb.track.uri == e.track.uri or pb.track.linked_uri == e.track.uri)
				local expired = tern.now() >= e.until_ms
				if arrived or expired then
					state.expect = nil
				else
					-- Spotify is still switching tracks: a 204 or the previous track is not its answer yet.
					hold = true
					pb = state.playback
				end
			end
			apply(state, cx, pb)
		else
			keep_going = fail(state, reply)
		end
		cx:render()
		if keep_going then
			local playing = state.playback ~= nil and state.playback.playing
			local delay = if hold then EXPECT_RETRY_MS elseif playing then POLL_PLAYING_MS else POLL_IDLE_MS
			if not reply.ok and (reply.status == 0 or reply.status >= 500) then
				state.poll_fails += 1
				delay = backoff_ms(state.poll_fails)
			elseif reply.status ~= 429 then
				state.poll_fails = 0 -- a 429 is Spotify's own wait (honoured by spotify.request), not a sign the server is back
			end
			schedule(state, cx, delay)
		end
	end)
end

-- Once a second while a track plays: move the progress bar, and re-read right when the track should have ended.
tick = function(state: State, cx: BlockCx)
	state.ticking = false
	if not alive(cx.pane) then
		return
	end
	local pb = state.playback
	if state.phase == "ready" and pb and pb.playing and pb.track then
		local duration = pb.track.duration_ms
		if duration > 0 and position(pb) >= duration then
			local key = pb.track.uri .. ":" .. tostring(pb.at)
			if state.ended_for ~= key then
				state.ended_for = key
				schedule(state, cx, SETTLE_MS)
			end
		end
		if shows_player(state) then
			cx:render()
		end
		start_tick(state, cx)
	end
end

-- Commands -------------------------------------------------------------------------------------

-- Puts a device list into the picker, with the active device selected.
local function set_devices(state: State, devices: { spotify.Device })
	state.devices, state.dsel = devices, 1
	for i, d in devices do
		if d.active then
			state.dsel = i
		end
	end
end

local function open_devices(state: State, cx: BlockCx)
	local client = state.client
	if not client then
		return
	end
	state.mode = "devices"
	spotify.request(client, "GET", "/me/player/devices", nil, nil, function(reply)
		if not alive(cx.pane) then
			return
		end
		if reply.ok then
			set_devices(state, spotify.parse_devices(reply.json))
		else
			fail(state, reply)
		end
		cx:render()
	end)
end

-- Set below: a play or resume found no active device; if the local player is registered in the
-- account, start on it instead of asking. False when it did nothing and the caller should ask.
local recover_no_device: (State, BlockCx) -> boolean

-- Sends a player command, then re-reads the playback state once Spotify has applied it.
local function send(state: State, cx: BlockCx, method: string, path: string, query: { { string } }?, body: any?)
	local client = state.client
	if not client then
		return
	end
	spotify.request(client, method, path, query, body, function(reply)
		if not alive(cx.pane) then
			return
		end
		if reply.ok then
			state.err, state.cmd_err, state.sd.tried = nil, nil, false
		else
			local e = state.expect
			state.expect = nil
			if e then
				-- The chosen track never started: don't leave it on screen as playing.
				apply(state, cx, e.prev)
				if reply.reason == "NO_ACTIVE_DEVICE" then
					state.pending = e.track
				end
			end
			fail(state, reply)
			if reply.reason == "NO_ACTIVE_DEVICE" then
				if path == "/me/player/play" and recover_no_device(state, cx) then
					state.err = nil
				else
					state.err = "No active device: pick one to play on."
					state.sd.tried = false
					open_devices(state, cx)
				end
			end
			state.cmd_err = state.err
		end
		cx:render()
		if state.phase == "ready" then
			schedule(state, cx, SETTLE_MS)
		end
	end)
end

local function toggle(state: State, cx: BlockCx)
	local pb = state.playback
	state.expect = nil -- the user took over: don't second-guess them
	if pb and pb.playing then
		pb.progress_ms, pb.at, pb.playing = position(pb), tern.now(), false
		send(state, cx, "PUT", "/me/player/pause")
	else
		if pb then
			pb.at, pb.playing = tern.now(), true
			start_tick(state, cx)
		end
		send(state, cx, "PUT", "/me/player/play")
	end
end

local function seek(state: State, cx: BlockCx, delta_ms: number)
	local pb = state.playback
	if not pb or not pb.track then
		return
	end
	local target = math.floor(math.clamp(position(pb) + delta_ms, 0, math.max(pb.track.duration_ms, 0)))
	pb.progress_ms, pb.at = target, tern.now()
	-- Only the last of a burst of presses is sent; the bar already shows each one.
	debounced(state, "seek", function()
		if alive(cx.pane) then
			send(state, cx, "PUT", "/me/player/seek", { { "position_ms", tostring(target) } })
		end
	end)
end

local function set_volume(state: State, cx: BlockCx, volume: number)
	local device = if state.playback then state.playback.device else nil
	if not device then
		state.err = "No active device."
		return
	end
	if not device.volume_ok then
		state.err = `{device.name} doesn't support volume control.`
		return
	end
	local v = math.clamp(math.floor(volume + 0.5), 0, 100)
	device.volume = v
	debounced(state, "volume", function()
		if alive(cx.pane) then
			send(state, cx, "PUT", "/me/player/volume", { { "volume_percent", tostring(v) } })
		end
	end)
end

local function change_volume(state: State, cx: BlockCx, delta: number)
	local device = if state.playback then state.playback.device else nil
	set_volume(state, cx, ((device and device.volume) or 0) + delta)
end

local function mute(state: State, cx: BlockCx)
	local device = if state.playback then state.playback.device else nil
	local current = (device and device.volume) or 0
	if current > 0 then
		state.premute = current
		set_volume(state, cx, 0)
	else
		set_volume(state, cx, state.premute or 50)
	end
end

local function skip(state: State, cx: BlockCx, direction: "next" | "previous")
	drop_debounced(state, "seek") -- a position meant for this track would land on the next one
	send(state, cx, "POST", "/me/player/" .. direction)
end

local function toggle_shuffle(state: State, cx: BlockCx)
	local pb = state.playback
	if not pb then
		return
	end
	pb.shuffle = not pb.shuffle
	send(state, cx, "PUT", "/me/player/shuffle", { { "state", tostring(pb.shuffle) } })
end

local REPEAT_NEXT = { off = "context", context = "track", track = "off" }

local function cycle_repeat(state: State, cx: BlockCx)
	local pb = state.playback
	if not pb then
		return
	end
	pb.repeat_mode = REPEAT_NEXT[pb.repeat_mode] or "off"
	send(state, cx, "PUT", "/me/player/repeat", { { "state", pb.repeat_mode } })
end

local function play_track(state: State, cx: BlockCx, track: spotify.Track, device_id: string?)
	drop_debounced(state, "seek")
	if track.playable == false then
		-- Spotify accepts the command (204) and then sits on it with every action disallowed.
		state.err = `{track.name} can't be played ({track.restriction or "restricted"}).`
		state.cmd_err = state.err
		tern.log.warn("spotify-api play refused locally: result is not playable", track.uri, track.restriction or "")
		return
	end
	state.mode = "player"
	state.pending = nil
	focus_op(cx, nil)
	-- Spotify applies this asynchronously and answers /me/player with 204 or the old track meanwhile, so
	-- show the chosen track as playing until it reports it (poll) or the grace period ends.
	local old = state.playback
	state.expect = { track = track, prev = old, until_ms = tern.now() + EXPECT_MS }
	apply(state, cx, {
		track = track,
		playing = true,
		progress_ms = 0,
		at = tern.now(),
		shuffle = old ~= nil and old.shuffle,
		repeat_mode = if old then old.repeat_mode else "off",
		device = if old then old.device else nil,
	})
	local query = if device_id then { { "device_id", device_id } } else nil
	send(state, cx, "PUT", "/me/player/play", query, spotify.play_body(track))
end

local function transfer(state: State, cx: BlockCx, device: spotify.Device)
	drop_debounced(state, "volume") -- that level was meant for the device being left
	if not device.id then
		state.err = `{device.name} can't be controlled from the Web API.`
		return
	end
	local pending = state.pending
	if pending then
		-- The picker was opened because the chosen track had no device: start that track here.
		play_track(state, cx, pending, device.id)
		return
	end
	state.mode = "player"
	send(state, cx, "PUT", "/me/player", nil, {
		device_ids = { device.id },
		play = state.playback ~= nil and state.playback.playing,
	})
end

-- Local player ---------------------------------------------------------------------------------

local function has_local_device(devices: { spotify.Device }): boolean
	for _, d in devices do
		if d.name == spotifyd.DEVICE_NAME then
			return true
		end
	end
	return false
end

-- The one device named like the local player, with an id we can address; nil if none or several.
local function local_device(devices: { spotify.Device }): spotify.Device?
	local found: spotify.Device? = nil
	for _, d in devices do
		if d.name == spotifyd.DEVICE_NAME then
			if found then
				return nil
			end
			found = d
		end
	end
	return if found and found.id then found else nil
end

recover_no_device = function(state, cx)
	local client = state.client
	if state.sd.tried or not client or not spotifyd.supported() then
		return false
	end
	state.sd.tried = true
	local track = state.pending
	spotify.request(client, "GET", "/me/player/devices", nil, nil, function(reply)
		if not alive(cx.pane) then
			return
		end
		local devices = if reply.ok then spotify.parse_devices(reply.json) else nil
		local device = if devices then local_device(devices) else nil
		if device and device.id then
			state.err, state.cmd_err = nil, nil
			if track then
				play_track(state, cx, track, device.id)
			else
				send(state, cx, "PUT", "/me/player", nil, { device_ids = { device.id }, play = true })
			end
		else
			state.sd.tried = false
			state.err = "No active device: pick one to play on."
			state.cmd_err = state.err
			if devices then
				state.mode = "devices" -- the list is already here: no second request
				set_devices(state, devices)
			else
				open_devices(state, cx)
			end
		end
		cx:render()
	end)
	return true
end

local function sd_fail(state: State, cx: BlockCx, message: string)
	state.sd.step, state.sd.err, state.sd.url = "menu", message, nil
	cx:render()
end

-- Installed? Running? And is "Tern" in this account's device list?
local function sd_refresh(state: State, cx: BlockCx)
	spotifyd.status(function(st)
		if alive(cx.pane) then
			state.sd.status = st
			cx:render()
		end
	end)
	local client = state.client
	if client then
		spotify.request(client, "GET", "/me/player/devices", nil, nil, function(reply)
			if alive(cx.pane) and reply.ok then
				state.sd.visible = has_local_device(spotify.parse_devices(reply.json))
				cx:render()
			end
		end)
	end
end

local function sd_log(): string
	local p = spotifyd.paths()
	return if p then spotifyd.log_tail(p.log, 4) else ""
end

-- After the agent is loaded: it counts as up only when launchd says it runs AND Spotify lists "Tern" in
-- this account. A file on disk, or a device left over from the pairing run, is not proof.
local function sd_wait_ready(state: State, cx: BlockCx, gen: number, deadline: number)
	local sd = state.sd
	local client = state.client
	if sd.gen ~= gen or not client or not alive(cx.pane) then
		return
	end
	local function again()
		if tern.now() >= deadline then
			local log = sd_log()
			sd_fail(state, cx, "spotifyd didn't show up as “Tern” in your Spotify account in time." .. (if log ~= "" then "\n" .. log else ""))
		else
			tern.timer(3000, function()
				sd_wait_ready(state, cx, gen, deadline)
			end)
		end
	end
	spotifyd.status(function(st)
		if sd.gen ~= gen or not alive(cx.pane) then
			return
		end
		if not st.running then
			again()
			return
		end
		spotify.request(client, "GET", "/me/player/devices", nil, nil, function(reply)
			if sd.gen ~= gen or not alive(cx.pane) then
				return
			end
			if reply.ok and has_local_device(spotify.parse_devices(reply.json)) then
				sd.step, sd.err, sd.visible, sd.status = "menu", nil, true, st
				cx:render()
			else
				again()
			end
		end)
	end)
end

-- Loads the agent. While launchctl is at it (up to a few seconds: it waits for the old job to go) no other
-- flow may start, whatever the screen shows: a pairing's unload landing in the middle would leave the agent
-- running beside it. The keys and clicks are ignored while `restoring` is set.
local function sd_enable(sd: SD, cb: (boolean, string?) -> ())
	sd.restoring = true
	spotifyd.enable(function(ok, err)
		sd.restoring = false
		cb(ok, err)
	end)
end

local AGENT_UP_MS = 45000

-- Loads the agent and waits until it really plays as "Tern". `gen` is the run this belongs to.
local function sd_bring_up(state: State, cx: BlockCx, gen: number)
	local sd = state.sd
	sd.step = "starting"
	cx:render()
	sd_enable(sd, function(ok, err)
		if sd.gen ~= gen or not alive(cx.pane) then
			return
		end
		if not ok then
			sd_fail(state, cx, err or "Could not start the local player.")
			return
		end
		sd_wait_ready(state, cx, gen, tern.now() + AGENT_UP_MS)
	end)
end

-- Writes and loads the LaunchAgent, then waits until it really plays as "Tern".
local function sd_start(state: State, cx: BlockCx)
	local sd = state.sd
	if not spotifyd.has_login() then
		sd.err = "Nothing to start yet: sign in first (1 pair from phone, or 2 browser)."
		return
	end
	sd.gen += 1
	sd.err = nil
	sd_bring_up(state, cx, sd.gen)
end

-- Install, stop or remove: shows `step` while `op` runs (stopping is quick enough not to), then goes back to
-- the menu with the error it gave, if any, and looks at the state again.
local function sd_op(state: State, cx: BlockCx, step: Step, op: ((boolean, string?) -> ()) -> (), clear_visible: boolean)
	local sd = state.sd
	sd.gen += 1
	sd.step, sd.err = step, nil
	if step ~= "menu" then
		cx:render()
	end
	op(function(ok, err)
		if not alive(cx.pane) then
			return
		end
		sd.step = "menu"
		if not ok then
			sd.err = err
		end
		if clear_visible then
			sd.visible = nil
		end
		cx:render()
		sd_refresh(state, cx)
	end)
end

-- Asks "is Tern in this account yet?" every 3 s, but only once a login has landed in staging: until then
-- nobody has paired with this Mac and Spotify has nothing to tell. `found` says whether it was the real
-- thing; if not the polling goes on, until the deadline (the pairing run has its own timeout and reports that).
local function sd_poll_device(state: State, cx: BlockCx, gen: number, deadline: number, found: () -> boolean)
	local client = state.client
	if state.sd.gen ~= gen or state.sd.step ~= "pairing" or not client or not alive(cx.pane) then
		return
	end
	local function again()
		if tern.now() < deadline then
			tern.timer(3000, function()
				sd_poll_device(state, cx, gen, deadline, found)
			end)
		end
	end
	if not spotifyd.staging_has_login() then
		again()
		return
	end
	spotify.request(client, "GET", "/me/player/devices", nil, nil, function(reply)
		if state.sd.gen ~= gen or not alive(cx.pane) then
			return
		end
		if reply.ok and has_local_device(spotify.parse_devices(reply.json)) and found() then
			return
		end
		again()
	end)
end

-- A pairing or browser sign-in didn't work out: drop what it wrote (the login that was working is
-- untouched) and bring back the agent that was running. Safe when the pane is already gone.
local function sd_discard_login(state: State, cx: BlockCx)
	local sd = state.sd
	spotifyd.wipe_staging()
	if sd.was_enabled and spotifyd.has_login() then
		sd_enable(sd, function()
			if alive(cx.pane) then
				sd_refresh(state, cx)
			end
		end)
	else
		sd.restoring = false
	end
end

-- The new login worked: it replaces the old one, and the agent runs on it.
local function sd_adopt_login(state: State, cx: BlockCx, gen: number)
	local sd = state.sd
	sd.step = "saving" -- can't be cancelled: the old login is being swapped for the new one
	cx:render()
	spotifyd.commit(function(committed, cerr)
		if sd.gen ~= gen then
			return
		end
		if not alive(cx.pane) then
			-- The pane is gone: keep what is consistent. A kept login gets its agent back; a failed one is dropped.
			if committed then
				if sd.was_enabled then
					sd_enable(sd, function() end)
				end
			else
				sd_discard_login(state, cx)
			end
			return
		end
		if not committed then
			sd_discard_login(state, cx)
			sd_fail(state, cx, "Could not keep the new login: " .. (cerr or "unknown error"))
			return
		end
		sd_bring_up(state, cx, gen)
	end)
end

-- Starts a sign-in that writes into staging (pairing or the browser): the agent is unloaded first, then
-- `run(gen)` starts spotifyd and says whether it could. Whatever goes wrong drops the staging login and
-- brings back the agent that was running.
local function sd_new_login(state: State, cx: BlockCx, step: Step, run: (number) -> boolean)
	local sd = state.sd
	if not spotifyd.find_binary() then
		sd.err = "Install spotifyd first (i)."
		return
	end
	sd.gen += 1
	local gen = sd.gen
	sd.step, sd.err, sd.was_enabled = step, nil, spotifyd.is_enabled()
	cx:render()
	spotifyd.disable(function()
		if sd.gen ~= gen then
			return
		end
		if not alive(cx.pane) then
			sd_discard_login(state, cx) -- the agent we just unloaded comes back
			return
		end
		if not run(gen) then
			sd_discard_login(state, cx)
			sd_fail(state, cx, "Could not start spotifyd.")
		end
	end)
end

-- Pair from the phone. spotifyd runs with discovery on for at most PAIR_TIMEOUT_MS into a staging login,
-- as a child of this call (never the agent). Whoever on the network pairs first gets the device, so
-- success needs both: a login arrived in staging AND "Tern" is in THIS account's device list. Anything
-- else wipes the staging login and leaves the one you had.
local function sd_pair(state: State, cx: BlockCx)
	local sd = state.sd
	sd_new_login(state, cx, "pairing", function(gen)
		local started = spotifyd.pair(function(result)
			if sd.gen ~= gen or sd.step ~= "pairing" then
				return -- it ended because we stopped it
			end
			sd_discard_login(state, cx) -- even if the pane is gone: a stranger's pairing must not stay on disk
			if not alive(cx.pane) then
				return
			end
			local why = if result.timed_out then "Nobody paired in time." else "spotifyd stopped: " .. spotifyd.tail(result.stderr, 3)
			sd_fail(state, cx, why .. " Open Spotify on your phone, pick “" .. spotifyd.DEVICE_NAME .. "” in the device list, then try again.")
		end)
		if started then
			sd_poll_device(state, cx, gen, tern.now() + spotifyd.PAIR_TIMEOUT_MS, function()
				if not spotifyd.staging_has_login() then
					return false -- a Tern is listed, but nobody paired with this Mac
				end
				sd.step = "saving" -- from here the pairing run's own report is no longer a failure, and esc can't half-cancel the swap
				spotifyd.cancel_pairing(function()
					if sd.gen == gen then
						sd_adopt_login(state, cx, gen)
					end
				end)
				return true
			end)
		end
		return started
	end)
end

-- Sign in with the browser. spotifyd prints an address, waits for Spotify's redirect on a local port and
-- stores the login in staging. The address is read from its log while it waits, and opened for you.
local function sd_oauth(state: State, cx: BlockCx)
	local sd = state.sd
	sd.url = nil
	sd_new_login(state, cx, "oauth", function(gen)
		local function watch()
			if sd.gen ~= gen or sd.step ~= "oauth" or not alive(cx.pane) then
				return
			end
			local url = spotifyd.oauth_url()
			if url then
				sd.url = url
				cx:open(url)
				cx:render()
				return -- printed once: nothing more to read
			end
			tern.timer(1000, watch)
		end
		local started = spotifyd.authenticate(function(result)
			if sd.gen ~= gen or sd.step ~= "oauth" then
				return
			end
			sd.url = nil
			if result.status ~= 0 then
				sd_discard_login(state, cx)
				if not alive(cx.pane) then
					return
				end
				local p = spotifyd.paths()
				local log = if p then spotifyd.log_tail(p.oauth_log, 3) else ""
				sd_fail(state, cx, if result.timed_out then "The browser sign-in timed out." else "The browser sign-in failed." .. (if log ~= "" then "\n" .. log else ""))
				return
			end
			if not alive(cx.pane) then
				sd_discard_login(state, cx)
			elseif not spotifyd.staging_has_login() then
				sd_discard_login(state, cx)
				sd_fail(state, cx, "The browser sign-in finished but no login was saved.")
			else
				sd_adopt_login(state, cx, gen)
			end
		end)
		if started then
			watch()
		end
		return started
	end)
end

-- What each click (by action name) and each key of the local player screen does. Nothing starts while a run
-- is going or the agent that ran before a failed sign-in is coming back.
local SD_ACTS: { [string]: (State, BlockCx) -> () } = {
	sd_pair = sd_pair,
	sd_oauth = sd_oauth,
	sd_install = function(state, cx)
		sd_op(state, cx, "installing", spotifyd.install, false)
	end,
	sd_start = sd_start,
	sd_stop = function(state, cx)
		sd_op(state, cx, "menu", spotifyd.disable, true)
	end,
	sd_remove = function(state, cx)
		sd_op(state, cx, "removing", spotifyd.remove, true)
	end,
	sd_refresh = sd_refresh,
}
local SD_KEYS: { [string]: string } = {
	["1"] = "sd_pair",
	["2"] = "sd_oauth",
	i = "sd_install",
	s = "sd_start",
	x = "sd_stop",
	U = "sd_remove",
	r = "sd_refresh",
}

local function sd_act(state: State, cx: BlockCx, act: string?): boolean
	local run = if act then SD_ACTS[act] else nil
	if not run or state.sd.step ~= "menu" or state.sd.restoring then
		return false
	end
	run(state, cx)
	return true
end

-- Esc while pairing or signing in: stop it, drop what it wrote and bring back the agent that ran.
local function sd_cancel(state: State, cx: BlockCx)
	local sd = state.sd
	local was = sd.step
	if was == "installing" or was == "removing" or was == "saving" then
		return -- brew, the cleanup and the swap of the login can't be interrupted
	end
	sd.gen += 1
	sd.step, sd.url = "menu", nil
	if was == "pairing" or was == "oauth" then
		sd.restoring = true -- until the stopped run is cleaned up and the old agent is back
		spotifyd.cancel_pairing(function()
			sd_discard_login(state, cx)
		end)
	else
		sd_refresh(state, cx)
	end
	cx:render()
end

local function sd_open(state: State, cx: BlockCx)
	if not spotifyd.supported() then
		state.err = "The local player needs macOS."
		return
	end
	state.mode = "localplayer"
	state.sd.err = nil
	sd_refresh(state, cx)
end

local function run_search(state: State, cx: BlockCx)
	local client = state.client
	local q = string.match(state.query.text, "^%s*(.-)%s*$") or ""
	if not client or q == "" then
		return
	end
	state.searching, state.focus, state.sel = true, "list", 1
	focus_op(cx, nil)
	local sent_market = sends_market(state)
	spotify.request(client, "GET", "/search", market_query(state, { { "q", q }, { "type", "track" }, { "limit", "10" } }), nil, function(reply)
		if not alive(cx.pane) then
			return
		end
		if market_refused(reply, sent_market) then
			-- from_token isn't available to this token: search without it.
			state.market = false
			tern.log.warn("spotify-api: market=from_token refused on /search, retrying without:", reply.err or "")
			run_search(state, cx)
			return
		end
		state.searching, state.searched = false, true
		if reply.ok then
			state.err = nil
			state.results = spotify.parse_tracks(reply.json)
		else
			state.results = {}
			fail(state, reply)
		end
		cx:render()
	end)
end

local function enter_search(state: State, cx: BlockCx)
	state.mode, state.focus = "search", "input"
	focus_op(cx, node_path(BOX.search, "query"))
end

local function sign_out(state: State, cx: BlockCx)
	cancel_debounced(state)
	state.poll_fails = 0
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	local function removed(ok: boolean, err: string?)
		if not ok and alive(cx.pane) then
			-- Nothing else would say it: the sign-in would come back at the next start.
			state.warn = "Signed out, but the Keychain item could not be removed: " .. (err or "unknown error")
			cx:render()
		end
	end
	if state.client then
		spotify.sign_out(state.client, removed)
	else
		spotify.forget(removed)
	end
	state.gen += 1
	state.phase, state.mode = "login", "player"
	state.playback, state.login, state.waiting, state.err, state.warn = nil, nil, false, nil, nil
end

-- Sign-in --------------------------------------------------------------------------------------

-- Signs in with the saved token if there is one, else asks to sign in. Also where esc on the sign-in method
-- choice lands: the saved sign-in is still there after "Connecting", so try it again. The Keychain answers
-- asynchronously, so the pane says "Connecting" until it has.
local function resume(state: State, cx: BlockCx)
	state.poll_fails = 0
	local client = state.client
	if not client then
		state.phase = "login"
		return
	end
	state.phase = "loading"
	spotify.load(client, function(has, warn)
		if not alive(cx.pane) or state.client ~= client or state.phase ~= "loading" then
			return -- the user went elsewhere (another method, a sign-out) while the Keychain answered
		end
		state.warn = if has then warn else nil
		if has then
			poll(state, cx)
		else
			state.phase = "login"
			state.err = warn
		end
		cx:render()
	end)
end

local function begin_client(state: State, cx: BlockCx, client_id: string, auth: spotify.AuthMode)
	cancel_debounced(state)
	state.auth = auth
	state.client_id = client_id
	local old = state.client
	if old then
		spotify.retire(old) -- an answer to one of its requests must not store a token any more
	end
	secret.reset(secret.default) -- a new choice by the user: the Keychain may be tried again
	local client = spotify.new(client_id, auth)
	if old and old.client_id == client_id then
		-- Spotify limits per client id: choosing the same one again doesn't clear a wait it imposed.
		client.retry_until, client.retry_reason = old.retry_until, old.retry_reason
	end
	state.client = client
	state.err = nil
	resume(state, cx)
end

-- Takes `auth` as the way this block signs in. A token obtained the other way belongs to another
-- client id, so it is dropped rather than refreshed against the wrong one.
local function adopt(state: State, cx: BlockCx, auth: spotify.AuthMode, client_id: string)
	local other_client = state.client ~= nil and state.client_id ~= client_id
	if (tern.kv.get("auth_mode") or "own") ~= auth or other_client then
		spotify.forget(function(ok, err)
			if not ok and alive(cx.pane) then
				state.warn = "The old sign-in could not be removed from the Keychain: " .. (err or "unknown error")
				cx:render()
			end
		end)
	end
	tern.kv.set("auth_mode", auth)
	begin_client(state, cx, client_id, auth)
end

local function finish_login(state: State, cx: BlockCx, result: spotify.Callback)
	local login, client = state.login, state.client
	state.gen += 1
	state.waiting = false
	spotify.release_listener(state.auth)
	if not login or not client then
		return
	end
	state.login = nil
	if result.error then
		state.err = "Spotify did not grant access: " .. result.error
	elseif result.state ~= login.state then
		state.err = "Sign-in state did not match; start again."
	elseif not result.code then
		state.err = "The redirect carried no authorization code."
	else
		state.phase = "loading"
		state.err = nil
		spotify.exchange(client, result.code, login.verifier, function(reply)
			if not alive(cx.pane) then
				return
			end
			if state.client ~= client or state.phase ~= "loading" then
				return -- the user left for the choice of sign-in method meanwhile; a saved token is picked up when they come back
			end
			state.warn = client.warn
			if reply.ok then
				poll(state, cx)
			else
				state.phase = "login"
				state.err = "Sign-in failed: " .. (reply.err or "unknown error")
			end
			cx:render()
		end)
	end
end

local function listen(state: State, cx: BlockCx, gen: number, deadline: number)
	local remaining = deadline - tern.now()
	if remaining <= 0 then
		state.waiting = false
		state.err = "Sign-in timed out."
		cx:render()
		return
	end
	spotify.listen(state.auth, remaining, function(target, err)
		if state.gen ~= gen or not alive(cx.pane) then
			return
		end
		if err then
			state.waiting = false
			state.err = if err == "timeout"
				then "Sign-in timed out."
				else `Could not listen on 127.0.0.1:{spotify.port(state.auth)} ({err}). Paste the address Spotify sent you to instead.`
			cx:render()
			return
		end
		local result = if target then spotify.parse_callback(target) else nil
		if result then
			finish_login(state, cx, result)
			cx:render()
		else
			listen(state, cx, gen, deadline) -- a stray request (favicon, preconnect): keep waiting
		end
	end)
end

local function start_login(state: State, cx: BlockCx)
	if state.waiting then
		return
	end
	-- spotifyd's browser sign-in listens on 8000, the port of the Keymaster redirect; your own Client ID uses 43821.
	if state.sd.step == "oauth" and state.auth == "keymaster" then
		state.err = "The local player is signing in on the same port: finish it in the browser, or wait until it times out (3 min)."
		return
	end
	local client = state.client
	if not client then
		return
	end
	state.err = nil
	secret.reset(secret.default)
	spotify.begin_login(client, function(login, err)
		if not alive(cx.pane) then
			return
		end
		if not login then
			state.err = err or "Could not start sign-in."
			cx:render()
			return
		end
		state.login, state.waiting = login, true
		state.gen += 1
		cx:open(login.url)
		listen(state, cx, state.gen, tern.now() + SIGNIN_TIMEOUT_MS)
		cx:render()
	end)
end

local function cancel_login(state: State)
	if state.waiting then
		state.gen += 1
		state.waiting, state.login = false, nil
		spotify.release_listener(state.auth)
	end
end

-- Views ----------------------------------------------------------------------------------------

-- How many rows a list may take in this pane; `reserve` is what the rest of the screen uses (title, input, hint).
-- Past it the list scrolls inside, which keeps the selected row in view.
local function list_lines(cx: BlockCx, reserve: number): number
	return math.clamp(cx.rows - reserve, 2, 10)
end

local function tracks_list(key: string, prefix: string, tracks: { spotify.Track }, selected: number, empty: string, lines: number): Node
	local items = {}
	for i, t in tracks do
		items[i] = {
			label = t.name,
			detail = (if t.album ~= "" then t.artists .. " · " .. t.album else t.artists) .. (if t.playable == false then " · unavailable" else ""),
			value = fmt_time(t.duration_ms),
		}
	end
	return keyed_list(key, prefix, items, selected, empty, BOX.search, lines)
end

-- Said first on every screen that offers a way in: without Premium nothing here works.
local function premium_line(): Node
	return ui.text({
		ui.span("Requires Spotify Premium. ", "strong"),
		ui.span("Spotify only lets Premium accounts control playback through its API; a free account gets \"Premium required\" errors.", "muted"),
	})
end

local function choose_view(): { Node }
	return {
		panel("Connect Spotify", {
			premium_line(),
			ui.text({ ui.span("Choose how to sign in:") }),
			click(ui.text({ ui.span("1  Your own Client ID (recommended)", "strong") }), "mode_own"),
			hint("   Register a free Spotify app once. Within Spotify's terms; the app's owner needs Premium."),
			click(ui.text({ ui.span("2  Keymaster (unofficial)", "strong") }), "mode_keymaster"),
			hint("   No app to register. Signs in as Spotify's own desktop app: you will be shown a warning first."),
		}),
	}
end

local function keymaster_view(): { Node }
	return {
		panel("Sign in with Keymaster", {
			premium_line(),
			ui.text({ ui.span("Read this first:", "error") }),
			ui.text({ ui.span("- It uses the client ID of Spotify's own desktop app, the one librespot and spotifyd present themselves as. It is not an app of yours.") }),
			ui.text({ ui.span("- Using it from unofficial software likely breaches Spotify's terms of use. Spotify can block or change it without notice, and sign-in would stop working.") }),
			ui.text({ ui.span("- Everyone who uses it shares its identity and limits. You use it at your own risk.") }),
			ui.text({ ui.span("- This block only asks to read the playback state and to control playback.") }),
			click(ui.badge("I understand, continue  y", "accent"), "keymaster_ok"),
		}),
	}
end

local function own_setup_view(state: State): { Node }
	return {
		panel("Connect Spotify with your own app", {
			premium_line(),
			ui.text({
				ui.span("1. Create an app at "),
				ui.link("developer.spotify.com/dashboard", "https://developer.spotify.com/dashboard", "link"),
				ui.span(" (the app owner needs Spotify Premium)."),
			}),
			ui.text({ ui.span("2. Add this Redirect URI to the app (click to copy):") }),
			click(ui.text({ ui.span(spotify.redirect_uri("own"), "code") }), "copy"),
			ui.text({ ui.span("3. Paste the app's Client ID below and press Enter.") }),
			ui.node("input", {
				key = "client",
				text = state.id_field.text,
				cursor = field.utf16_cursor(state.id_field),
				placeholder = "Client ID (32 hex characters)",
				prompt = { ui.span("> ", "muted") },
			}),
		}, { key = BOX.setup }),
	}
end

local function setup_view(state: State): { Node }
	if state.setup == "keymaster" then
		return keymaster_view()
	elseif state.setup == "own" then
		return own_setup_view(state)
	end
	return choose_view()
end

local function login_view(state: State): { Node }
	if state.waiting then
		return {
			panel("Spotify", {
				ui.node("spinner", { style = "dots", label = { ui.span("Waiting for Spotify in your browser", "muted") } }),
				hint("If this machine can't receive the redirect (a remote host, say), copy the sign-in URL with c,"),
				hint("open it anywhere, then paste the address you land on here. Esc cancels."),
			}),
		}
	end
	return {
		panel("Spotify", {
			premium_line(),
			ui.text(
				if state.auth == "keymaster"
					then { ui.span("Not signed in. Using Keymaster, Spotify's desktop client ID.") }
					else { ui.span("Not signed in. Client ID "), ui.span(state.client_id, "code"), ui.span(".") }
			),
			click(ui.badge("Sign in  ⏎", "accent"), "signin"),
		}),
		hint("enter sign in · e change sign-in method"),
	}
end

-- An SVG sent as a blob (once per `cache_key`: `build` only runs on a miss) and shown as an image,
-- clickable when `act` is given. A bare image would zoom on click, over a backdrop the theme colours
-- can't be read on, so pictures that are not buttons take INERT: an action nothing handles.
local INERT = "inert"
local function svg_image(state: State, cx: BlockCx, node_key: string, cache_key: string, build: () -> string, w: number, h: number, alt: string, act: string): Node
	local id = state.blobs[cache_key]
	if not id then
		id = cx:blob(build(), "image/svg+xml")
		state.blobs[cache_key] = id
	end
	return click(ui.node("image", { key = node_key, blob = id, alt = alt, w = w, h = h }), act)
end

local function toggle_icon(state: State, cx: BlockCx, name: viz.Icon, on: boolean, alt: string, act: string): Node
	return svg_image(state, cx, name, `ic2:{name}:{on}`, function()
		return viz.icon(name, on)
	end, viz.ICON_W, viz.ICON_H, alt, act)
end

local function transport_row(state: State, cx: BlockCx, pb: spotify.Playback): Node
	local repeating = pb.repeat_mode ~= "off"
	local repeat_name: viz.Icon = if pb.repeat_mode == "track" then "repeat_one" else "repeat_all"
	local repeat_alt = if pb.repeat_mode == "track" then "Repeat one" elseif repeating then "Repeat all" else "Repeat off"
	return ui.el("div", { class = "sp-transport" }, {
		toggle_icon(state, cx, "search", false, "Search", "search"),
		toggle_icon(state, cx, "shuffle", pb.shuffle, if pb.shuffle then "Shuffle on" else "Shuffle off", "shuffle"),
		toggle_icon(state, cx, "prev", false, "Previous", "prev"),
		svg_image(state, cx, "play", `ic2:play:{pb.playing}`, function()
			return viz.play_button(pb.playing)
		end, viz.PLAY_SIZE, viz.PLAY_SIZE, if pb.playing then "Pause" else "Play", "toggle"),
		toggle_icon(state, cx, "next", false, "Next", "next"),
		toggle_icon(state, cx, repeat_name, repeating, repeat_alt, "repeat"),
		toggle_icon(state, cx, "help", false, "Shortcuts", "help"),
	})
end

-- The volume and where the audio plays. `full` (docked): speaker (click: mute), -/+, a ten-step meter, the device
-- (click: picker) and the links to Spotify and the local player. `float` (floating card with the focus): the same
-- without the links. `info` (parked or floating without focus: nothing there can be clicked): level and device only.
local function volume_row(state: State, cx: BlockCx, device: spotify.Device?, track: spotify.Track, style: "full" | "float" | "info"): Node
	local kids: { Node } = {}
	local volume = if device and device.volume_ok then device.volume else nil
	local live = style ~= "info"
	if volume then
		local level = if volume == 0 then 0 elseif volume <= 50 then 30 else 80
		table.insert(kids, svg_image(state, cx, "vol", `ic2:vol:{level}`, function()
			return viz.volume_icon(level)
		end, viz.ICON_W, viz.ICON_H, if not live then (if volume == 0 then "Muted" else "Volume") elseif volume == 0 then "Unmute" else "Mute", if live then "mute" else INERT))
		if live then
			table.insert(kids, toggle_icon(state, cx, "minus", false, "Volume down", "vol_down"))
		end
		local lit = math.clamp(math.floor(volume / 10 + 0.5), 0, 10)
		table.insert(kids, svg_image(state, cx, "volbar", `vb2:{lit}`, function()
			return viz.volume_bar(lit * 10)
		end, viz.VOL_BAR_W, viz.VOL_BAR_H, `Volume {volume}%`, INERT))
		if live then
			table.insert(kids, toggle_icon(state, cx, "plus", false, "Volume up", "vol_up"))
		end
		table.insert(kids, ui.text({ ui.span(`{volume}%`, "num") }))
	else
		table.insert(kids, ui.text({ ui.span("volume n/a", "muted") }))
	end
	table.insert(kids, ui.el("span", { class = "sp-grow" }, {}))
	local where = ui.text({ ui.span(if device then `{device.name} ({device.kind})` else "no device", "muted") })
	table.insert(kids, if live then click(where, "devices") else where)
	if style == "full" then
		if track.link then
			table.insert(kids, click(ui.badge("OPEN SPOTIFY", "neutral"), "open"))
		end
		if spotifyd.supported() then
			table.insert(kids, click(ui.badge("LOCAL PLAYER", "muted"), "local_open"))
		end
	end
	return ui.el("div", { class = if live then "sp-row" else "sp-row sp-info" }, kids)
end

-- Three bars that dance while a track plays and sit flat when it doesn't (CSS only: no re-render).
local function equaliser(playing: boolean): Node
	return ui.el("span", { class = if playing then "sp-eq" else "sp-eq sp-eq-off" }, {
		ui.el("span", {}, {}),
		ui.el("span", {}, {}),
		ui.el("span", {}, {}),
	})
end

-- The song: the equaliser and title, then the artist (and the album when `album` is set).
local function song_lines(pb: spotify.Playback, track: spotify.Track, album: boolean): { Node }
	local lines: { Node } = {
		ui.el("div", { class = "sp-row" }, { equaliser(pb.playing), ui.text({ ui.span(track.name, "strong") }) }),
		ui.text({ ui.span(track.artists, "accent") }),
	}
	if album then
		table.insert(lines, ui.text({ ui.span(track.album, "muted") }))
	end
	return lines
end

-- The native bar: `value` is 0..1, and 0 for a track whose length is unknown.
local function progress_bar(pos: number, duration: number): Node
	return ui.node("progress", { key = "progress", value = if duration > 0 then pos / duration else 0 })
end

-- Elapsed, grow, duration; `seek` adds the -10s and +10s badges.
local function times_row(pos: number, duration: number, seek: boolean): Node
	local kids: { Node } = { ui.text({ ui.span(fmt_time(pos), "num") }) }
	if seek then
		table.insert(kids, click(ui.badge("-10s", "muted"), "seek_back"))
		table.insert(kids, click(ui.badge("+10s", "muted"), "seek_fwd"))
	end
	table.insert(kids, ui.el("span", { class = "sp-grow" }, {}))
	table.insert(kids, ui.text({ ui.span(fmt_time(duration), "num") }))
	return ui.el("div", { class = "sp-row" }, kids)
end

-- Docked: one card, the cover (uncropped) on the left and, in a column beside it, the song, the bar, the
-- times, the controls and the volume. A pane too narrow for both stacks the column under the cover.
local function docked_view(state: State, cx: BlockCx, pb: spotify.Playback, track: spotify.Track, art: string?): { Node }
	local pos = position(pb)
	local deck: { Node } = {}
	if art then
		-- The cover links back to Spotify (a bare image would zoom): Spotify's policy asks for that link.
		table.insert(deck, click(ui.node("image", { key = "art", blob = art, alt = track.album, w = 200, h = 200 }), "open"))
	end
	table.insert(deck, ui.el("div", { class = "sp-body" }, {
		ui.el("div", { class = "sp-song" }, song_lines(pb, track, true)),
		progress_bar(pos, track.duration_ms),
		times_row(pos, track.duration_ms, true),
		transport_row(state, cx, pb),
		volume_row(state, cx, pb.device, track, "full"),
	}))
	return { ui.el("div", { class = "sp-deck" }, deck) }
end

-- Floating or parked: the glass card with the song, the cover (when it is this track's), the bar and the volume
-- with the device. The controls and the volume buttons are there only while the card has the focus.
local function glass_view(state: State, cx: BlockCx, pb: spotify.Playback, track: spotify.Track, art: string?, controls: boolean): { Node }
	local pos = position(pb)
	local head: { Node } = {}
	if art then
		table.insert(head, click(ui.node("image", { key = "art", blob = art, alt = track.album, w = 64, h = 64 }), "open"))
	end
	table.insert(head, with(ui.col(song_lines(pb, track, false)), { grow = 1 }))
	local kids: { Node } = {
		ui.el("div", { class = "sp-head" }, head),
		progress_bar(pos, track.duration_ms),
		times_row(pos, track.duration_ms, false),
	}
	if controls then
		table.insert(kids, transport_row(state, cx, pb))
	end
	table.insert(kids, volume_row(state, cx, pb.device, track, if controls then "float" else "info"))
	return { ui.el("div", { class = "sp-glass" }, kids) }
end

local function player_view(state: State, cx: BlockCx): { Node }
	local pb = state.playback
	local track = if pb then pb.track else nil
	if not pb or not track then
		if state.shape == "compact" then
			return { panel("Nothing playing", {}) }
		end
		return {
			panel("Nothing playing", {
				hint("space resumes on your last device, d picks a device, / searches, P sets up a local player (no Spotify app), ? lists every key."),
			}),
		}
	end
	-- Only this track's cover that has finished downloading is shown: a pending or failed download shows nothing.
	local art = if state.art and state.art.url == track.art_url and state.art.blob then state.art.blob else nil
	if state.shape == "docked" then
		return docked_view(state, cx, pb, track, art)
	end
	return glass_view(state, cx, pb, track, art, state.shape == "float")
end

local function search_view(state: State, cx: BlockCx): { Node }
	local empty = if state.searching then "Searching…" elseif state.searched then "No results" else "Type a query and press Enter"
	return {
		header("Search", { act = "back", label = "back" }),
		panel(nil, {
			ui.node("input", {
				key = "query",
				text = state.query.text,
				cursor = field.utf16_cursor(state.query),
				placeholder = "Search tracks",
				prompt = { ui.span("/ ", "muted") },
			}),
			tracks_list("results", "r", state.results, state.sel, empty, list_lines(cx, 10)),
		}, { key = BOX.search }),
	}
end

local function devices_view(state: State, cx: BlockCx): { Node }
	local items = {}
	for i, d in state.devices do
		items[i] = { label = d.name, detail = d.kind, value = if d.active then "active" else nil, tone = if d.active then "accent" else nil }
	end
	return {
		header("Devices", { act = "back", label = "back" }),
		panel(nil, { keyed_list("devices", "d", items, state.dsel, "No devices. Open Spotify on one, then press r.", BOX.devices, list_lines(cx, 8)) }, { key = BOX.devices }),
	}
end

-- The shortcuts screen (`?`): every key the player answers (`=` is a quiet alias of `+`), in groups. `kbd`
-- upper-cases a single letter, so a capital is written as a shift chord ({"shift", "p"}) to tell P (local player)
-- from p (previous).
local HELP: { keycaps.Group } = {
	{
		title = "Playback",
		rows = {
			{ caps = { { "space" }, { "k" } }, text = "Play / pause" },
			{ caps = { { "n" }, { "p" } }, text = "Next / previous" },
			{ caps = { { "left" }, { "right" } }, text = "Seek ∓10 s" },
			{ caps = { { "+" }, { "-" }, { "up" }, { "down" } }, text = "Volume" },
			{ caps = { { "m" } }, text = "Mute" },
			{ caps = { { "s" } }, text = "Shuffle" },
			{ caps = { { "r" } }, text = "Repeat" },
		},
	},
	{
		title = "Find and open",
		rows = {
			{ caps = { { "/" } }, text = "Search" },
			{ caps = { { "d" } }, text = "Devices" },
			{ caps = { { "o" } }, text = "Open in Spotify" },
			{ caps = { { "shift", "p" } }, text = "Local player" },
		},
	},
	{
		title = "Window and more",
		rows = {
			{ caps = { { "z" } }, text = "Park" },
			{ caps = { { "f" } }, text = "Float" },
			{ caps = { { "shift", "f" } }, text = "Dock" },
			{ caps = { { "?" }, { "esc" } }, text = "This screen / back" },
			{ caps = { { "shift", "l" } }, text = "Sign out" },
		},
	},
}

local function help_view(): { Node }
	local groups: { Node } = {}
	for _, group in HELP do
		table.insert(groups, keycaps.group(group))
	end
	return {
		header("Shortcuts", { act = "back", label = "esc back" }),
		ui.el("div", { class = "sp-keys" }, groups),
	}
end

local function sd_lines(text: string, style: string): { Node }
	local out: { Node } = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, ui.text({ ui.span(line, style) }))
	end
	return out
end

local function local_view(state: State): { Node }
	local sd = state.sd
	local st = sd.status
	local info: { Node } = {
		hint(`Plays Spotify on this Mac as the device “{spotifyd.DEVICE_NAME}”, with no Spotify app running. It runs spotifyd (installed with Homebrew) as a login item.`),
	}
	local function row(label: string, value: string, style: string?)
		table.insert(info, ui.text({ ui.span(label .. "  ", "muted"), ui.span(value, style) }))
	end
	if not st then
		row("spotifyd", "checking…")
	else
		row("spotifyd", if st.bin then `installed{if st.version then " " .. st.version else ""}` else "not installed (press i; needs Homebrew)", if st.bin then "strong" else "error")
		row("service", if st.running then `running{if st.pid then " (pid " .. st.pid .. ")" else ""}` elseif st.loaded then "loaded, not running" elseif st.enabled then "set to start at login, not loaded" else "off", if st.running then "strong" else nil)
	end
	row(`in your Spotify`, if sd.visible == true then `“{spotifyd.DEVICE_NAME}” is in your device list` elseif sd.visible == false then `“{spotifyd.DEVICE_NAME}” isn't listed` else "not checked", if sd.visible then "strong" else nil)

	local act: { Node } = {}
	if sd.step == "installing" then
		table.insert(act, ui.node("spinner", { style = "dots", label = { ui.span("Installing spotifyd with Homebrew (a minute or two)…", "muted") } }))
	elseif sd.step == "removing" then
		table.insert(act, ui.node("spinner", { style = "dots", label = { ui.span("Removing the local player…", "muted") } }))
	elseif sd.step == "saving" then
		table.insert(act, ui.node("spinner", { style = "dots", label = { ui.span("Saving the new login…", "muted") } }))
	elseif sd.step == "starting" then
		table.insert(act, ui.node("spinner", { style = "dots", label = { ui.span(`Starting spotifyd and waiting for it to appear as “{spotifyd.DEVICE_NAME}”…`, "muted") } }))
	elseif sd.step == "pairing" then
		table.insert(act, ui.node("spinner", { style = "dots", label = { ui.span(`Waiting for you to pick “{spotifyd.DEVICE_NAME}” in Spotify on your phone (same Wi-Fi), up to 3 minutes…`, "muted") } }))
		table.insert(act, hint("Open Spotify on your phone, tap the device icon, choose Tern. esc cancels."))
	elseif sd.step == "oauth" then
		table.insert(act, ui.node("spinner", { style = "dots", label = { ui.span("Waiting for the browser sign-in, up to 3 minutes…", "muted") } }))
		if sd.url then
			table.insert(act, hint("Opened in your browser. If it didn't open, use this address:"))
			table.insert(act, ui.text({ ui.link(sd.url, sd.url) }))
		end
		table.insert(act, hint("esc cancels."))
	else
		table.insert(act, ui.row({
			click(ui.badge("1 pair from phone", "accent"), "sd_pair"),
			click(ui.badge("2 sign in with browser", "accent"), "sd_oauth"),
		}))
		table.insert(act, ui.row({
			click(ui.badge("i install", "neutral"), "sd_install"),
			click(ui.badge("s start", "neutral"), "sd_start"),
			click(ui.badge("x stop", "neutral"), "sd_stop"),
			click(ui.badge("r refresh", "neutral"), "sd_refresh"),
			click(ui.badge("U remove", "muted"), "sd_remove"),
		}))
	end
	if sd.err then
		for _, n in sd_lines(sd.err, "error") do
			table.insert(act, n)
		end
	end
	return {
		header("Local player", { act = "back", label = "back" }),
		panel(nil, info),
		panel(nil, act),
		hint("It starts at every login and stays on until you stop or remove it. Signing in again replaces the saved login. Unofficial: spotifyd presents itself as Spotify's desktop app, the same caveat as Keymaster."),
	}
end

local HINTS: { [string]: string } = {
	help = "? or esc back",
	input = "enter search · ↓ results · esc back",
	list = "j/k move · enter play · / edit query · esc back",
	devices = "j/k move · enter play here · r refresh · esc back",
	localplayer = "1 pair from phone · 2 sign in with browser · i install · s start · x stop · r refresh · U remove · esc back",
	login = "",
}

local function build_view(state: State, cx: BlockCx): BlockView
	local main: { Node }
	local help: string
	if state.phase == "setup" then
		main = setup_view(state)
		help = if state.setup == "choose"
			then "1 your own Client ID · 2 Keymaster" .. (if state.client then " · esc back" else "")
			elseif state.setup == "keymaster" then "y continue · esc back"
			else "enter save · esc back"
	elseif state.phase == "login" then
		main, help = login_view(state), HINTS.login
	elseif state.phase == "loading" then
		main = { panel(nil, { ui.node("spinner", { style = "dots", label = { ui.span("Connecting to Spotify", "muted") } }) }) }
		help = "e / esc other sign-in method · L sign out"
	elseif state.mode == "search" then
		main, help = search_view(state, cx), if state.focus == "input" then HINTS.input else HINTS.list
	elseif state.mode == "devices" then
		main, help = devices_view(state, cx), HINTS.devices
	elseif state.mode == "help" and state.shape ~= "compact" then
		main, help = help_view(), HINTS.help
	elseif state.mode == "localplayer" then
		main, help = local_view(state), HINTS.localplayer
	else
		main, help = player_view(state, cx), ""
	end

	local dock: { Node } = {}
	if state.err then
		table.insert(dock, ui.text({ ui.span(state.err, "error") }))
	end
	if state.warn then
		table.insert(dock, ui.text({ ui.span(state.warn, "error") }))
	end
	if help ~= "" then
		table.insert(dock, hint(help))
	end
	return { main = ui.col(main), dock = ui.col(dock) }
end

-- Input ----------------------------------------------------------------------------------------

local function valid_client_id(s: string): boolean
	return #s == 32 and string.match(s, "^%x+$") ~= nil
end

local function choose_own(state: State, cx: BlockCx)
	state.setup, state.err = "own", nil
	state.id_field = field.new(if state.auth == "own" then state.client_id else "")
	focus_op(cx, node_path(BOX.setup, "client"))
end

local function choose_keymaster(state: State, cx: BlockCx)
	state.setup, state.err = "keymaster", nil
	focus_op(cx, nil)
end

-- The warning has been read: remember it, so the block doesn't ask again on every start.
local function confirm_keymaster(state: State, cx: BlockCx)
	tern.kv.set("keymaster_ack", true)
	adopt(state, cx, "keymaster", spotify.KEYMASTER_CLIENT_ID)
end

local function key_setup(state: State, key: Key, cx: BlockCx): boolean
	if state.setup == "choose" then
		if key.text == "1" then
			choose_own(state, cx)
		elseif key.text == "2" then
			choose_keymaster(state, cx)
		elseif key.name == "escape" and state.client then
			state.err = nil
			resume(state, cx)
		else
			return false
		end
		return true
	elseif state.setup == "keymaster" then
		if key.text == "y" or key.text == "Y" then
			confirm_keymaster(state, cx)
		elseif key.name == "escape" then
			state.setup, state.err = "choose", nil
		else
			return false
		end
		return true
	end
	local outcome = field.handle(state.id_field, key)
	if outcome == "submit" then
		local id = string.lower(string.match(state.id_field.text, "^%s*(.-)%s*$") or "")
		if valid_client_id(id) then
			tern.kv.set("client_id", id)
			adopt(state, cx, "own", id)
		else
			state.err = "A Spotify Client ID is 32 hexadecimal characters."
		end
	elseif outcome == "cancel" then
		state.setup, state.err = "choose", nil
		focus_op(cx, nil)
	elseif outcome == "ignored" then
		return false
	end
	return true
end

local function key_login(state: State, key: Key, cx: BlockCx): boolean
	if key.name == "paste" and state.login then
		local result = spotify.parse_callback(key.text or "")
		if result then
			finish_login(state, cx, result)
			return true
		end
		state.err = "That text has no authorization code in it."
		return true
	elseif key.name == "enter" then
		start_login(state, cx)
	elseif key.name == "escape" then
		cancel_login(state)
	elseif key.name == "c" and state.login then
		cx:copy(state.login.url)
		cx:toast("info", "Sign-in URL copied")
	elseif key.name == "e" and not state.waiting then
		state.setup, state.phase, state.err = "choose", "setup", nil
		focus_op(cx, nil)
	else
		return false
	end
	return true
end

local function move(sel: number, delta: number, count: number): number
	return math.clamp(sel + delta, 1, math.max(count, 1))
end

local function open_track(state: State, cx: BlockCx)
	local track = if state.playback then state.playback.track else nil
	if track and track.link then
		cx:open(track.link)
	end
end

-- Where the "back" badge and Esc lead from each screen: the player. Search also drops the field's focus (Esc in the
-- field with results first moves to the results and does not come here); the local player cancels the step it is in
-- (pairing, sign-in, starting) and does nothing while it installs, removes or saves.
local function search_back(state: State, cx: BlockCx)
	state.mode = "player"
	focus_op(cx, nil)
end

local function devices_back(state: State)
	state.pending = nil
	state.mode = "player"
end

local function local_back(state: State, cx: BlockCx)
	if state.sd.step == "menu" then
		state.mode = "player"
	else
		sd_cancel(state, cx)
	end
end

local function key_local(state: State, key: Key, cx: BlockCx): boolean
	local name = key.name
	if name == "escape" then
		local_back(state, cx)
	else
		return sd_act(state, cx, SD_KEYS[if key.text == "U" then "U" else name])
	end
	return true
end

-- `?` is shift+/: depending on the layout and the sender it arrives as the typed "?", as the key "?", or as the key "/"
-- with shift held. It must be told apart before the plain "/" (search).
local function is_help_key(key: Key): boolean
	return key.text == "?" or key.name == "?" or (key.name == "/" and key.shift == true)
end

local function key_player(state: State, key: Key, cx: BlockCx): boolean
	local name = key.name
	if key.text == "L" then
		sign_out(state, cx)
	elseif key.text == "P" then
		sd_open(state, cx)
	elseif is_help_key(key) then
		state.mode = "help"
	elseif name == "space" or name == "k" then
		toggle(state, cx)
	elseif name == "n" then
		skip(state, cx, "next")
	elseif name == "p" then
		skip(state, cx, "previous")
	elseif name == "left" then
		seek(state, cx, -10000)
	elseif name == "right" then
		seek(state, cx, 10000)
	elseif name == "+" or name == "=" or name == "up" then
		change_volume(state, cx, 5)
	elseif name == "-" or name == "down" then
		change_volume(state, cx, -5)
	elseif name == "m" then
		mute(state, cx)
	elseif name == "s" then
		toggle_shuffle(state, cx)
	elseif name == "r" then
		cycle_repeat(state, cx)
	elseif name == "/" then
		enter_search(state, cx)
	elseif name == "d" then
		open_devices(state, cx)
	elseif name == "o" then
		open_track(state, cx)
	else
		return false
	end
	return true
end

local function key_search(state: State, key: Key, cx: BlockCx): boolean
	if state.focus == "input" then
		local outcome = field.handle(state.query, key)
		if outcome == "submit" then
			run_search(state, cx)
		elseif outcome == "cancel" then
			if #state.results > 0 then
				state.focus = "list"
				focus_op(cx, nil)
			else
				search_back(state, cx)
			end
		elseif outcome == "ignored" then
			if key.name == "down" and #state.results > 0 then
				state.focus = "list"
				focus_op(cx, nil)
			else
				return false
			end
		end
		return true
	end
	local name = key.name
	if name == "j" or name == "down" then
		state.sel = move(state.sel, 1, #state.results)
	elseif name == "k" or name == "up" then
		state.sel = move(state.sel, -1, #state.results)
	elseif name == "enter" then
		local track = state.results[state.sel]
		if track then
			play_track(state, cx, track)
		end
	elseif name == "/" or name == "tab" then
		enter_search(state, cx)
	elseif name == "escape" then
		search_back(state, cx)
	else
		return false
	end
	return true
end

local function key_devices(state: State, key: Key, cx: BlockCx): boolean
	local name = key.name
	if name == "j" or name == "down" then
		state.dsel = move(state.dsel, 1, #state.devices)
	elseif name == "k" or name == "up" then
		state.dsel = move(state.dsel, -1, #state.devices)
	elseif name == "enter" then
		local device = state.devices[state.dsel]
		if device then
			transfer(state, cx, device)
		end
	elseif name == "r" then
		open_devices(state, cx)
	elseif name == "escape" or name == "d" then
		devices_back(state)
	else
		return false
	end
	return true
end

local function key_help(state: State, key: Key): boolean
	if key.name == "escape" or is_help_key(key) then
		state.mode = "player"
		return true
	end
	return false
end

local function item_index(ev: UiEvent): number?
	return tonumber(string.match(tostring(ev.item), "%.[rd](%d+)$"))
end

-- Block ----------------------------------------------------------------------------------------

local player: BlockDef<State> = {
	init = function(cx, _args, _saved)
		-- Only what is not secret sits in this folder's kv.json now (a token an earlier version left there is moved
		-- to the Keychain when it is found): keep other local users out of it.
		pcall(function()
			tern.process.run({ "chmod", "700", tern.plugin.data }, function() end)
		end)

		local state: State = {
			phase = "setup",
			mode = "player",
			client_id = "",
			auth = "own",
			setup = "choose",
			id_field = field.new(""),
			waiting = false,
			gen = 0,
			query = field.new(""),
			focus = "input",
			results = {},
			searched = false,
			searching = false,
			sel = 1,
			devices = {},
			dsel = 1,
			inflight = false,
			ticking = false,
			market = true,
			blobs = {},
			poll_fails = 0,
			debounce = {},
			sent_at = {},
			sd = { step = "menu", gen = 0, tried = false, was_enabled = false, restoring = false },
			shape = "docked",
		}

		local env = tern.getenv("SPOTIFY_CLIENT_ID")
		local stored = tern.kv.get("client_id")
		if type(env) == "string" and valid_client_id(env) then
			begin_client(state, cx, env, "own")
		elseif tern.kv.get("auth_mode") == "keymaster" and tern.kv.get("keymaster_ack") == true then
			begin_client(state, cx, spotify.KEYMASTER_CLIENT_ID, "keymaster")
		elseif type(stored) == "string" and valid_client_id(stored) then
			begin_client(state, cx, stored, "own")
		end
		return state
	end,

	title = function(state)
		local pb = state.playback
		if state.phase ~= "ready" or not pb or not pb.track then
			return "Spotify"
		end
		local t = pb.track
		local label = if t.artists ~= "" then `{t.name} – {t.artists}` else t.name
		return if pb.playing then "♪ " .. label else label .. " (paused)"
	end,

	view = function(state, cx)
		return build_view(state, cx)
	end,

	key = function(state, key, cx)
		-- z/f/F, once connected and not while typing a search: the window half parks/floats/docks this pane.
		local window_action = WINDOW_KEYS[key.text or ""]
		if
			window_action
			and state.phase == "ready"
			and not (state.mode == "search" and state.focus == "input")
			and not (key.ctrl or key.alt or key.meta)
		then
			cx:open(bridge.PREFIX .. window_action)
			return false
		end
		if state.phase == "setup" then
			return key_setup(state, key, cx)
		elseif state.phase == "login" then
			return key_login(state, key, cx)
		elseif state.phase == "loading" then
			-- Spotify may keep refusing (rate limit, no network): never leave the block with no way out.
			if key.text == "L" then
				sign_out(state, cx)
				return true
			elseif key.text == "e" or key.name == "escape" then
				-- Only a way to choose another method: the saved sign-in stays until a different method is picked.
				-- Polling pauses by itself: poll() does nothing outside the loading and ready phases.
				state.setup, state.phase, state.err = "choose", "setup", nil
				focus_op(cx, nil)
				return true
			end
			return false
		elseif state.mode == "search" then
			return key_search(state, key, cx)
		elseif state.mode == "devices" then
			return key_devices(state, key, cx)
		elseif state.mode == "help" then
			return key_help(state, key)
		elseif state.mode == "localplayer" then
			return key_local(state, key, cx)
		end
		return key_player(state, key, cx)
	end,

	event = function(state, ev, cx)
		if ev.ev == "action" then
			local act = ev.act
			local shape: bridge.Shape? = bridge.parse_shape(act)
			if shape ~= nil then
				state.shape = shape -- from the window half: how the pane is shown
			elseif act == "signin" then
				start_login(state, cx)
			elseif state.phase == "setup" and state.setup == "own" and act == "copy" then
				cx:copy(spotify.redirect_uri("own"))
				cx:toast("info", "Redirect URI copied")
			elseif state.phase == "setup" and state.setup == "choose" and act == "mode_own" then
				choose_own(state, cx)
			elseif state.phase == "setup" and state.setup == "choose" and act == "mode_keymaster" then
				choose_keymaster(state, cx)
			elseif state.phase == "setup" and state.setup == "keymaster" and act == "keymaster_ok" then
				confirm_keymaster(state, cx)
			elseif state.phase == "ready" and shows_player(state) then
				if act == "toggle" then
					toggle(state, cx)
				elseif act == "next" then
					skip(state, cx, "next")
				elseif act == "prev" then
					skip(state, cx, "previous")
				elseif act == "shuffle" then
					toggle_shuffle(state, cx)
				elseif act == "repeat" then
					cycle_repeat(state, cx)
				elseif act == "seek_back" then
					seek(state, cx, -10000)
				elseif act == "seek_fwd" then
					seek(state, cx, 10000)
				elseif act == "mute" then
					mute(state, cx)
				elseif act == "vol_down" then
					change_volume(state, cx, -10)
				elseif act == "vol_up" then
					change_volume(state, cx, 10)
				elseif act == "devices" then
					open_devices(state, cx)
				elseif act == "open" then
					open_track(state, cx)
				elseif act == "search" then
					enter_search(state, cx)
				elseif act == "help" then
					state.mode = "help"
				elseif act == "local_open" then
					sd_open(state, cx)
				end
			elseif state.phase == "ready" and state.mode ~= "player" then
				if act == "back" then
					if state.mode == "search" then
						search_back(state, cx)
					elseif state.mode == "devices" then
						devices_back(state)
					elseif state.mode == "localplayer" then
						local_back(state, cx)
					else
						state.mode = "player"
					end
				elseif state.mode == "localplayer" then
					sd_act(state, cx, act)
				end
			end
		elseif ev.ev == "select" or ev.ev == "activate" then
			local i = item_index(ev)
			if not i then
				return
			end
			if state.mode == "search" then
				state.sel, state.focus = i, "list"
				local track = state.results[i]
				if ev.ev == "activate" and track then
					play_track(state, cx, track)
				end
			elseif state.mode == "devices" then
				state.dsel = i
				local device = state.devices[i]
				if ev.ev == "activate" and device then
					transfer(state, cx, device)
				end
			end
		elseif ev.ev == "focus" then
			if state.phase == "setup" then
				if state.setup == "own" then
					focus_op(cx, node_path(BOX.setup, "client"))
				end
			elseif state.mode == "search" then
				state.focus = "input"
				focus_op(cx, node_path(BOX.search, "query"))
			end
		end
	end,
}

tern.block.define("web-player", player)
