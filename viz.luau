--!strict
-- Pure SVG generators for the player: the control icons, the play disc and the volume meter. No Tern
-- API in here, so the flow tests can read the markup.
--
-- An SVG blob cannot read the theme's CSS variables in attributes, so every glyph keeps `currentColor`
-- as its attribute fallback. The parts that show state carry a class instead (`hi` on stroked
-- elements, `hi-fill` on filled ones, `disc` on the play disc); the plugin sheet (spotify.css) paints
-- those classes from the theme's `--accent-*` variables.

local M = {}

M.ICON_W = 28
M.ICON_H = 30
M.PLAY_SIZE = 44
M.VOL_BAR_W = 72
M.VOL_BAR_H = 14

local NS = 'xmlns="http://www.w3.org/2000/svg"'

local function f(x: number): string
	return string.format("%.1f", x)
end

-- Play/pause: a theme-coloured disc with a white glyph, the biggest control so the eye lands on it first.
function M.play_button(playing: boolean): string
	local glyph = if playing
		then '<rect x="15" y="14" width="5" height="16" rx="1.2"/><rect x="24" y="14" width="5" height="16" rx="1.2"/>'
		else '<path d="M17 13.5v17l14-8.5z"/>'
	local s = M.PLAY_SIZE
	return `<svg {NS} width="{s}" height="{s}" viewBox="0 0 44 44"><circle class="disc" cx="22" cy="22" r="21" fill="currentColor"/><g fill="#fff">{glyph}</g></svg>`
end

local PATHS = {
	prev = '<path d="M6 6h2.5v12H6z"/><path d="M19 6v12L9.5 12z"/>',
	next = '<path d="M15.5 6H18v12h-2.5z"/><path d="M5 6v12l9.5-6z"/>',
	shuffle = '<path d="M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5" fill="none"/>',
	repeat_all = '<path d="m17 2 4 4-4 4M3 11v-1a4 4 0 0 1 4-4h14m-14 16-4-4 4-4m14-1v1a4 4 0 0 1-4 4H3" fill="none"/>',
	repeat_one = '<path d="m17 2 4 4-4 4M3 11v-1a4 4 0 0 1 4-4h14m-14 16-4-4 4-4m14-1v1a4 4 0 0 1-4 4H3M11 10h1v4" fill="none"/>',
	minus = '<path d="M6 12h12" fill="none"/>',
	plus = '<path d="M6 12h12M12 6v12" fill="none"/>',
	search = '<path d="M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM15.5 16l5 5" fill="none"/>',
	help = '<path d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.6 9.6a2.4 2.4 0 1 1 3.4 2.2c-.6.3-1 .9-1 1.6M12 16.9v.1" fill="none"/>',
}

export type Icon = "prev" | "next" | "shuffle" | "repeat_all" | "repeat_one" | "minus" | "plus" | "search" | "help"

-- A 24-wide icon with room underneath for the "on" dot: an active toggle carries the `hi` class and a
-- dot, so the state does not rest on colour alone.
function M.icon(name: Icon, active: boolean): string
	local solid = name == "prev" or name == "next"
	local cls = if active then (if solid then ' class="hi-fill"' else ' class="hi"') else ""
	local style = if solid then 'fill="currentColor"' else 'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'
	local dot = if active then '<circle class="hi-fill" cx="12" cy="24.5" r="1.3" fill="currentColor"/>' else ""
	return `<svg {NS} width="{M.ICON_W}" height="{M.ICON_H}" viewBox="0 0 24 26"><g{cls} {style}>{PATHS[name]}</g>{dot}</svg>`
end

-- Speaker with 0, 1 or 2 sound waves for the level (0..100), crossed out at 0.
function M.volume_icon(percent: number): string
	local body = '<path d="M11 5 6 9H2v6h4l5 4z" fill="currentColor"/>'
	local waves = '<path d="m16 9 6 6m0-6-6 6" fill="none"/>'
	if percent > 0 then
		waves = '<path d="M15.5 8.5a5 5 0 0 1 0 7" fill="none"/>'
		if percent > 50 then
			waves ..= '<path d="M18.5 5.5a9 9 0 0 1 0 13" fill="none"/>'
		end
	end
	return `<svg {NS} width="{M.ICON_W}" height="{M.ICON_H}" viewBox="0 0 24 26">{body}<g stroke="currentColor" stroke-width="2" stroke-linecap="round">{waves}</g></svg>`
end

-- Ten-step level meter. Steps up to the volume are lit: the `hi` class, painted by the sheet.
function M.volume_bar(percent: number): string
	local w, h = M.VOL_BAR_W, M.VOL_BAR_H
	local lit = math.clamp(math.floor(percent / 10 + 0.5), 0, 10)
	local on, off = {}, {}
	for i = 1, 10 do
		local bar_h = 4 + i * 0.9
		local seg = `M{f((i - 0.5) * (w / 10))} {f(h - 1)}v{f(-bar_h)}`
		table.insert(if i <= lit then on else off, seg)
	end
	return `<svg {NS} width="{w}" height="{h}" viewBox="0 0 {w} {h}">`
		.. `<path d="{table.concat(off)}" stroke="currentColor" stroke-opacity="0.28" stroke-width="4" stroke-linecap="round" fill="none"/>`
		.. `<path class="hi" d="{table.concat(on)}" stroke="currentColor" stroke-width="4" stroke-linecap="round" fill="none"/>`
		.. "</svg>"
end

return M
