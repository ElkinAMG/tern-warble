--!strict
-- A one-line text field the block owns: Tern draws text and caret, keys come to `key`.
-- `cursor` counts code points; the `input` node wants UTF-16 units, see `utf16_cursor`.

export type Field = { text: string, cursor: number }

local M = {}

function M.new(text: string?): Field
	local t = text or ""
	return { text = t, cursor = utf8.len(t) or #t }
end

local function byte_at(text: string, cp: number): number
	return utf8.offset(text, cp + 1) or (#text + 1)
end

-- Printable text of `s` on one line; nil when it is not valid UTF-8.
function M.clean(s: string): string?
	if not utf8.len(s) then
		return nil
	end
	return (string.gsub(string.gsub(s, "[\r\n\t]+", " "), "[%c]", ""))
end

local function insert(f: Field, s: string)
	local clean = M.clean(s)
	if not clean or clean == "" then
		return
	end
	local at = byte_at(f.text, f.cursor)
	f.text = string.sub(f.text, 1, at - 1) .. clean .. string.sub(f.text, at)
	f.cursor += utf8.len(clean) :: number
end

export type Outcome = "submit" | "cancel" | "changed" | "ignored"

-- Applies one key. "submit" is Enter and "cancel" Escape; both leave the text alone.
function M.handle(f: Field, key: Key): Outcome
	local len = utf8.len(f.text) or #f.text
	local name = key.name
	if name == "enter" then
		return "submit"
	elseif name == "escape" then
		return "cancel"
	elseif name == "paste" then
		insert(f, key.text or "")
		return "changed"
	elseif name == "backspace" then
		if f.cursor > 0 then
			local from, to = byte_at(f.text, f.cursor - 1), byte_at(f.text, f.cursor)
			f.text = string.sub(f.text, 1, from - 1) .. string.sub(f.text, to)
			f.cursor -= 1
		end
		return "changed"
	elseif name == "delete" then
		if f.cursor < len then
			local from, to = byte_at(f.text, f.cursor), byte_at(f.text, f.cursor + 1)
			f.text = string.sub(f.text, 1, from - 1) .. string.sub(f.text, to)
		end
		return "changed"
	elseif name == "left" then
		f.cursor = math.max(0, f.cursor - 1)
		return "changed"
	elseif name == "right" then
		f.cursor = math.min(len, f.cursor + 1)
		return "changed"
	elseif name == "home" then
		f.cursor = 0
		return "changed"
	elseif name == "end" then
		f.cursor = len
		return "changed"
	elseif key.text and key.text ~= "" and not (key.ctrl or key.alt or key.meta) then
		insert(f, key.text)
		return "changed"
	end
	return "ignored"
end

-- The caret as the `input` node's UTF-16 offset.
function M.utf16_cursor(f: Field): number
	local units = 0
	local i = 0
	for _, cp in utf8.codes(f.text) do
		if i >= f.cursor then
			break
		end
		units += if cp > 0xFFFF then 2 else 1
		i += 1
	end
	return units
end

return M
