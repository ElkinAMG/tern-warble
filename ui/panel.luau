--!strict
-- The glass panel every screen is made of, and the title row that goes above it. Their look is `.sp-panel` and
-- `.sp-row` in spotify.css: theme colours only.

local ui = tern.ui
local core = require("./core")

local M = {}

export type Back = { act: string, label: string }

-- A panel with an optional bold title and then `children`. `opts.class` adds a class (how a layout places it);
-- `opts.key` makes it a keyed node, which then becomes part of its children's ids (see core.node_path).
function M.panel(title: string?, children: { Node }, opts: { class: string?, key: string? }?): Node
	local kids: { Node } = {}
	if title then
		table.insert(kids, ui.text({ ui.span(title, "strong") }))
	end
	for _, child in children do
		table.insert(kids, child)
	end
	local class = if opts and opts.class then `sp-panel {opts.class}` else "sp-panel"
	return ui.el("div", { class = class, key = if opts then opts.key else nil }, kids)
end

-- The title of a screen. With `back`, a badge at the right that runs `back.act` when clicked.
function M.header(title: string, back: Back?): Node
	local kids: { Node } = { ui.text({ ui.span(title, "strong") }), ui.el("span", { class = "sp-grow" }, {}) }
	if back then
		table.insert(kids, core.click(ui.badge(back.label, "muted"), back.act))
	end
	return ui.el("div", { class = "sp-row" }, kids)
end

return M
