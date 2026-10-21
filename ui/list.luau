--!strict
-- The native list the screens share: rows keyed `prefix .. i`, row `selected` highlighted when there is one.

local ui = tern.ui
local core = require("./core")

local M = {}

-- `scope` is the key of the keyed panel the list sits in: it is part of every row's id (see core.node_path).
-- `lines` caps the list's height: past it the list scrolls inside, and that is the only way Tern keeps the
-- selected row in view (an uncapped list is clipped by the pane with the selection possibly out of sight).
function M.keyed(key: string, prefix: string, items: { any }, selected: number, empty: string, scope: string, lines: number): Node
	local list = ui.list(items)
	local children: { Node } = list.c or {}
	for i, child in children do
		core.with(child, { key = prefix .. i })
	end
	core.with(list, {
		key = key,
		max = { lines = lines },
		selected = if items[selected] then core.node_path(scope, key, prefix .. selected) else nil,
		empty = { ui.span(empty, "muted") },
	})
	return list
end

return M
