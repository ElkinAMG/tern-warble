--!strict
-- The three helpers every view is built from: set props on a node, make it clickable, and a muted line of text.

local ui = tern.ui

local M = {}

function M.with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- The node runs `name` (an action the block's `event` handles) when it is clicked.
function M.click(node: Node, name: string): Node
	return M.with(node, { actions = { click = name } })
end

function M.hint(text: string): Node
	return ui.text({ ui.span(text, "muted") })
end

-- The id Tern gives a keyed node: "main." and every key from the screen's root down, joined by dots. Focus and
-- a list's `selected` name nodes by it, and a keyed panel around them is one of the keys.
function M.node_path(...: string): string
	return "main." .. table.concat({ ... }, ".")
end

return M
