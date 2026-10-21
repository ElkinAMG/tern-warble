--!strict
-- Window half: palette commands that put the player in Tern's park deck (program still running,
-- no tab) and bring it back, and the rule that the player opens as a small floating card (picture in
-- picture) over the other panes instead of taking a split. The host half can't touch layout, so this
-- lives in the window; the block's z/f/F keys reach it through a link (see bridge.luau).

local bridge = require("./bridge")

local KIND = "spotify-api.web-player"

local function players(cx: WindowCx): { PaneInfo }
	local found: { PaneInfo } = {}
	for _, p in cx.session:panes() do
		if p.block == KIND then
			table.insert(found, p)
		end
	end
	return found
end

-- The player to act on: the focused one when it matches, else the first that does.
local function pick(cx: WindowCx, list: { PaneInfo }, parked: boolean): PaneInfo?
	local focused = cx.session:focused()
	local first: PaneInfo? = nil
	for _, p in list do
		if (p.parked == true) == parked then
			if p.pane == focused then
				return p
			end
			first = first or p
		end
	end
	return first
end

local function report(cx: WindowCx, what: string, ok: boolean, err: string?)
	if not ok then
		cx:toast("error", `Could not {what}`, err)
	end
end

-- Floats the player over the block that owns its space, bottom right, at Tern's small card size.
-- Floating hands the focus to the owner, so the next key would be typed into that terminal: when the
-- player had the focus (or `force_focus`), it takes it back. Nothing to do when it already floats or
-- is parked. Fails (with Tern's reason) when the tab has no other tiled block to float over.
local function float_player(cx: WindowCx, pane: number, force_focus: boolean?): (boolean, string?)
	local info = cx.session:pane(pane)
	if not info or info.block ~= KIND or info.floating or info.parked then
		return true, nil
	end
	local had_focus = cx.session:focused() == pane
	local ok, err = cx.layout:float(pane, nil, "br")
	if ok and (had_focus or force_focus) then
		cx.layout:focus(pane)
	end
	return ok, err
end

-- Takes a parked player out of the pile and floats it.
local function unpark_player(cx: WindowCx, pane: number)
	local ok, err = cx.layout:unpark(pane)
	report(cx, "bring the player back", ok, err)
	if ok then
		local floated, why = float_player(cx, pane, true)
		if not floated then
			cx:toast("info", "The player is docked: it couldn't float", why)
		end
	end
end

-- What the block can't see for itself: whether its pane floats or is parked, and whether it has the focus.
-- Controls only make sense when the pane can take keys and clicks, so the block shows the song, the volume and
-- the device without buttons while it is parked or floating without focus; a floating card that has the focus
-- gets the glass card with its controls, and a docked pane the wide card.
-- The shape is sent to the block as an action event (see bridge.luau) on every focus change; the loop below
-- only catches changes that raise no focus event (Tern's own dock button). A pane is told only when its shape
-- changed, so with the same session in two windows the one whose state just changed decides, instead of both
-- repeating their own view every second. The focus is always `session:focused()` at the moment of the call,
-- never the pane a focus event names: after a click on the terminal Tern delivers a stale focus event for the
-- card about a second late, and trusting it flashed the buttons back on. A block that restarts without this
-- window noticing starts docked (the wide card) and stays there until its shape next changes.
local sent: { [number]: bridge.Shape } = {}

local function tell_shapes(cx: WindowCx)
	for _, c in bridge.changes(cx.session:panes(), KIND, cx.session:focused(), sent) do
		local ok, err = pcall(function()
			cx.session:event(c.pane, bridge.shape_event(c.shape))
		end)
		if ok then
			sent[c.pane] = c.shape
		else
			tern.log.warn("player shape not sent:", err)
		end
	end
end

-- Tern runs `window_start` once per window, not again when the plugins are reloaded, and timers need a
-- window event to get going after a reload. So the first window event of any kind starts the loop (once per
-- load) instead of relying on `window_start`.
local watching = false

local function watch_shapes(cx: WindowCx)
	tell_shapes(cx)
	tern.timer(1000, function(timer_cx)
		watch_shapes(timer_cx or cx)
	end)
end

local function start_watching(cx: WindowCx)
	if not watching then
		watching = true
		watch_shapes(cx)
	end
end

-- A player this window opens (palette, "Show player", "Park player") starts floating. The pane needs a
-- moment to land in its tab first. Panes restored from the daemon don't fire this, so a player you
-- docked on purpose stays docked across restarts.
tern.on("pane_created", function(ev, cx)
	tern.timer(0, function(timer_cx)
		local ok, err = float_player(timer_cx or cx, ev.pane)
		if not ok then
			tern.log.warn("player not floated:", err)
		end
		tell_shapes(timer_cx or cx)
		start_watching(timer_cx or cx)
	end)
end)

tern.on("window_start", start_watching)
tern.on("focus", function(_ev, cx)
	tell_shapes(cx) -- now, not on the next tick: no delay between focusing the card and its buttons
	start_watching(cx)
end)
for _, event in { "title", "tab_created", "tab_closed", "pane_closed" } do
	tern.on(event, function(_ev, cx)
		start_watching(cx)
	end)
end
-- Nothing may be going on to raise an event, so also try as soon as this file has loaded.
tern.timer(0, function(timer_cx)
	if timer_cx then
		start_watching(timer_cx)
	end
end)

tern.command({
	id = "park",
	title = "Park player",
	icon = "sparkle",
	run = function(cx)
		local list = players(cx)
		local shown = pick(cx, list, false)
		if shown then
			local ok, err = cx.layout:park(shown.pane)
			report(cx, "park the player", ok, err)
		elseif #list > 0 then
			cx:toast("info", "The player is already parked")
		else
			-- No player yet: start one straight into the deck.
			local pane = cx:new_block(KIND, nil, nil, { focus = false })
			if not pane then
				cx:toast("error", "Could not open the player", "Is the Spotify (Web API) plugin ready?")
				return
			end
			local ok, err = cx.layout:park(pane)
			report(cx, "park the new player", ok, err)
		end
		tell_shapes(cx)
	end,
})

tern.command({
	id = "show",
	title = "Show player",
	icon = "sparkle",
	run = function(cx)
		local list = players(cx)
		local parked = pick(cx, list, true)
		if parked then
			unpark_player(cx, parked.pane)
			tell_shapes(cx) -- it is floating and focused now: the controls, at once
			return
		end
		local shown = pick(cx, list, false)
		if shown then
			cx.layout:focus(shown.pane)
		elseif not cx:new_block(KIND) then
			cx:toast("error", "Could not open the player", "Is the Spotify (Web API) plugin ready?")
		end
		tell_shapes(cx)
	end,
})

-- The block's keys. Each one names a target state, never a toggle: a session shown in several windows
-- runs this in every one of them, and "make it floating" is safe to run twice where "flip it" is not.
local actions: { [string]: (cx: WindowCx, p: PaneInfo) -> () } = {
	park = function(cx, p)
		if not p.parked then
			local ok, err = cx.layout:park(p.pane)
			report(cx, "park the player", ok, err)
		end
	end,
	float = function(cx, p)
		if p.parked then
			unpark_player(cx, p.pane)
		elseif p.floating then
			cx.layout:focus(p.pane)
		else
			local ok, err = float_player(cx, p.pane, true)
			report(cx, "float the player", ok, err)
		end
	end,
	dock = function(cx, p)
		if p.floating and not p.parked then
			local ok, err = cx.layout:dock(p.pane, nil, nil)
			report(cx, "dock the player", ok, err)
			if ok then
				cx.layout:focus(p.pane)
			end
		end
	end,
}

tern.route.link(function(link, cx)
	if string.sub(link.url, 1, #bridge.PREFIX) ~= bridge.PREFIX then
		return nil
	end
	local action = actions[string.sub(link.url, #bridge.PREFIX + 1)]
	if not action then
		return nil
	end
	-- The pane the key came from; if Tern gave none, whichever player matches the focus.
	local from = if link.pane then cx.session:pane(link.pane) else nil
	local target = if from and from.block == KIND then from else nil
	if not target then
		local list = players(cx)
		target = pick(cx, list, false) or pick(cx, list, true)
	end
	if target then
		action(cx, target)
		tell_shapes(cx) -- the layout just changed: say so now, not on the next tick
	end
	return { handled = true }
end)
