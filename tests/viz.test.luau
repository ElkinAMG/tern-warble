--!strict
-- Run: luau tests/viz.test.luau   (pure: no tern runtime needed)
local viz = require("../viz")

local failures = 0
local function check(name: string, ok: boolean, detail: any?)
	if not ok then
		failures += 1
		print(`FAIL {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

-- Lit volume steps are the `hi` path: each step is one `M` in its `d`.
local function lit_bars(svg: string): number
	local d = string.match(svg, `<path class="hi" d="([^"]*)"`)
	if not d then
		return 0
	end
	local _, n = string.gsub(d, "M", "")
	return n
end

local function dim_bars(svg: string): number
	local d = string.match(svg, `<path d="([^"]*)" stroke="currentColor" stroke%-opacity`)
	if not d then
		return 0
	end
	local _, n = string.gsub(d, "M", "")
	return n
end

-- Toggles carry the `hi` class and a dot when on, so colour is not the only cue.
local on, off = viz.icon("shuffle", true), viz.icon("shuffle", false)
check("icon on: hi class and dotted", string.find(on, 'class="hi"', 1, true) ~= nil and string.find(on, '<circle class="hi-fill"', 1, true) ~= nil)
check("solid icon on: hi-fill class", string.find(viz.icon("next", true), '<g class="hi-fill"', 1, true) ~= nil)
check("icon off: no class, no dot, currentColor", string.find(off, "class=", 1, true) == nil and string.find(off, "<circle", 1, true) == nil and string.find(off, "currentColor", 1, true) ~= nil)
check("repeat one differs from repeat all", viz.icon("repeat_one", true) ~= viz.icon("repeat_all", true))

-- Volume: ten steps, rounded to the nearest, clamped.
check("volume bar: 40% lights 4", lit_bars(viz.volume_bar(40)) == 4)
check("volume bar: 0 lights none", lit_bars(viz.volume_bar(0)) == 0 and dim_bars(viz.volume_bar(0)) == 10)
check("volume bar: 100 lights all", lit_bars(viz.volume_bar(100)) == 10)
check("volume bar: out of range clamps", lit_bars(viz.volume_bar(250)) == 10 and lit_bars(viz.volume_bar(-5)) == 0)
check("volume icon: silent is crossed out, 1 wave to 50, 2 above", viz.volume_icon(0) ~= viz.volume_icon(30) and viz.volume_icon(30) == viz.volume_icon(50) and viz.volume_icon(80) ~= viz.volume_icon(50) and string.find(viz.volume_icon(0), "m16 9", 1, true) ~= nil and string.find(viz.volume_icon(30), "m16 9", 1, true) == nil)

-- Anything Tern's SVG sanitiser or the theme could trip over.
local all = { viz.play_button(true), viz.play_button(false), viz.volume_bar(50), viz.volume_icon(0), viz.volume_icon(80) }
for _, name in { "prev", "next", "shuffle", "repeat_all", "repeat_one", "minus", "plus", "search", "help" } do
	table.insert(all, viz.icon(name :: viz.Icon, true))
	table.insert(all, viz.icon(name :: viz.Icon, false))
end
for _, name in { "search", "help" } do
	local svg = viz.icon(name :: viz.Icon, false)
	local shapes, filled = 0, 0
	for tag in string.gmatch(svg, "<path[^>]*>") do
		shapes += 1
		filled += if string.find(tag, "fill=", 1, true) then 1 else 0
	end
	check(`icon {name}: every shape sets its fill (an unset one paints black)`, shapes > 0 and shapes == filled and string.find(svg, "<circle", 1, true) == nil)
end
for i, svg in all do
	check(`svg {i}: one root, closed`, string.sub(svg, 1, 4) == "<svg" and string.sub(svg, -6) == "</svg>" and select(2, string.gsub(svg, "<svg", "")) == 1)
	check(`svg {i}: no theme variables (they paint black in a blob)`, string.find(svg, "var(", 1, true) == nil)
	check(`svg {i}: nothing active`, string.find(svg, "<script", 1, true) == nil and string.find(svg, "href", 1, true) == nil and string.find(svg, "<foreignObject", 1, true) == nil)
	check(`svg {i}: currentColor fallback`, string.find(svg, "currentColor", 1, true) ~= nil)
end
check("play button: pause and play differ", viz.play_button(true) ~= viz.play_button(false))
check("play button: disc takes the sheet's fill", string.find(viz.play_button(true), '<circle class="disc"', 1, true) ~= nil)

if failures > 0 then
	error(`{failures} failure(s)`)
end
print("viz: ok")
