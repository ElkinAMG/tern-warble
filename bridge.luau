--!strict
-- The host half can't touch layout, so block keys that need it (park, float, dock) open a link in this
-- scheme; window.luau claims it with tern.route.link and acts on the player. Shared by both halves.
--
-- The block can't see its own layout or focus either, so the window half tells it with an action event
-- (`cx.session:event`), act `shape=docked`, `shape=float` or `shape=compact`. Nothing is written to disk or
-- to kv.json.

local M = {}

M.PREFIX = "tern-spotify://"

export type Shape = "docked" | "float" | "compact"

-- Which view the pane gets. Docked is the wide card with everything; a floating card that has the focus is
-- the small glass card with its controls and volume; compact (no controls, the volume and device read-only)
-- while the pane can't take input: parked, or floating without focus.
function M.shape(info: { floating: boolean?, parked: boolean? }, focused: boolean): Shape
	if info.parked == true then
		return "compact"
	elseif info.floating == true then
		return if focused then "float" else "compact"
	end
	return "docked"
end

function M.shape_event(shape: Shape): { [string]: any }
	return { ev = "action", act = "shape=" .. shape, id = "main" }
end

-- What this window has to tell which player panes: those of `kind` whose shape differs from the last one it
-- sent (`sent[pane]`, which the caller updates once a send worked). Only on change, so two windows that see
-- the same pane with different focus don't take turns overriding each other every tick: the window whose
-- state just changed is the one that speaks. `on` is the focused pane.
function M.changes(panes: { any }, kind: string, on: number?, sent: { [number]: Shape }): { { pane: number, shape: Shape } }
	local out: { { pane: number, shape: Shape } } = {}
	for _, p in panes do
		if p.block == kind then
			local shape: Shape = M.shape(p, p.pane == on)
			if sent[p.pane] ~= shape then
				table.insert(out, { pane = p.pane, shape = shape })
			end
		end
	end
	return out
end

-- The shape an action name carries, or nil when it is not a shape action.
function M.parse_shape(act: string?): Shape?
	if act == "shape=docked" then
		return "docked"
	elseif act == "shape=float" then
		return "float"
	elseif act == "shape=compact" then
		return "compact"
	end
	return nil
end

return M
