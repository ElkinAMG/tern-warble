--!strict
-- Keycaps for the shortcuts screen. `kbd` upper-cases a single letter, so a capital is a shift chord
-- ({"shift", "p"}), and a row can offer several chords for the same thing.

local ui = tern.ui
local panel = require("./panel")

local M = {}

export type Chord = { string }
export type Row = { caps: { Chord }, text: string }
export type Group = { title: string, rows: { Row } }

-- The keycaps (chords told apart by a dot) and what they do.
function M.row(row: Row): Node
	local caps: { Node } = {}
	for i, chord in row.caps do
		if i > 1 then
			table.insert(caps, ui.text({ ui.span("·", "muted") }))
		end
		table.insert(caps, ui.node("kbd", { keys = chord }))
	end
	return ui.el("div", { class = "sp-key" }, { ui.el("div", { class = "sp-caps" }, caps), ui.text({ ui.span(row.text, "muted") }) })
end

function M.group(group: Group): Node
	local rows: { Node } = {}
	for _, row in group.rows do
		table.insert(rows, M.row(row))
	end
	return panel.panel(group.title, rows, { class = "sp-keygroup" })
end

return M
