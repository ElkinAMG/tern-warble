--!strict
-- Run: luau tests/logic.test.luau   (pure logic only: no tern runtime needed)
local spotify = require("../spotify")
local field = require("../field")

local failures = 0
local function eq(name: string, got: any, want: any)
	if got ~= want then
		failures += 1
		print(`FAIL {name}\n  got  {tostring(got)}\n  want {tostring(want)}`)
	end
end

-- Redirect parsing: the three shapes the sign-in can hand us.
local line = spotify.parse_callback("GET /callback?code=AQB-x_y%2Bz&state=abc123 HTTP/1.1")
eq("request line code", line and line.code, "AQB-x_y+z")
eq("request line state", line and line.state, "abc123")
local url = spotify.parse_callback("http://127.0.0.1:43821/callback?state=s1&code=c1#frag")
eq("pasted url code", url and url.code, "c1")
eq("pasted url state", url and url.state, "s1")
local denied = spotify.parse_callback("/callback?error=access_denied&state=s2")
eq("denied error", denied and denied.error, "access_denied")
eq("denied has no code", denied and denied.code, nil)
eq("favicon request is not a callback", spotify.parse_callback("/favicon.ico"), nil)
eq("empty code is not a callback", spotify.parse_callback("/callback?code=&state=x"), nil)

-- Form/query encoding.
eq("encode reserved", spotify.encode("a b&c=d/é"), "a%20b%26c%3Dd%2F%C3%A9")
eq("query order", spotify.query({ { "q", "x y" }, { "type", "track" } }), "q=x%20y&type=track")

-- Cover art: smallest image that is still >= 300px, else the largest.
local function art(widths: { number }): string?
	local images = {}
	for _, w in widths do
		table.insert(images, { url = "u" .. w, width = w })
	end
	local track = spotify.parse_track({ uri = "spotify:track:1", name = "n", duration_ms = 1, album = { name = "a", images = images } })
	return track and track.art_url
end
eq("art picks 300 of 640/300/64", art({ 640, 300, 64 }), "u300")
eq("art falls back to largest", art({ 64, 200 }), "u200")

-- Text field: the cursor counts code points, so multibyte text edits cleanly.
local f = field.new("añb")
eq("cursor at end", f.cursor, 3)
field.handle(f, { name = "left", ctrl = false, alt = false, shift = false, meta = false })
field.handle(f, { name = "backspace", ctrl = false, alt = false, shift = false, meta = false })
eq("backspace removes a whole character", f.text, "ab")
field.handle(f, { name = "paste", text = "😀\n", ctrl = false, alt = false, shift = false, meta = false })
eq("paste flattens newlines", f.text, "a😀 b")
eq("utf16 caret counts surrogate pairs", field.utf16_cursor(f), 4)

if failures > 0 then
	error(`{failures} failure(s)`)
end
print("logic: ok")
