#!/bin/sh
# Runs tests/flow.test.luau. The plugin modules read the global `tern`, which the luau CLI
# (sandboxed globals) won't let a script define, so this inlines them after the test's own
# `local tern` and rewrites require() to a tiny module table.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp "${TMPDIR:-/tmp}/flow.XXXXXX")
trap 'rm -f "$out"' EXIT
{
	while IFS= read -r line; do
		if [ "$line" = "--@modules" ]; then
			echo "local __modules, __loaded = {}, {}"
			# shellcheck disable=SC2016
			echo 'local function __require(p) local n = string.match(p, "([%w_]+)$"); if not __loaded[n] then __loaded[n] = __modules[n]() end; return __loaded[n] end'
			for m in pkce field bridge secret spotify viz spotifyd ui/core ui/panel ui/list ui/keycaps host; do
				echo "__modules.${m##*/} = function()"
				sed 's/require(/__require(/g' "$root/$m.luau"
				echo "end"
			done
		else
			printf '%s\n' "$line" | sed 's/require(/__require(/g'
		fi
	done <"$root/tests/flow.test.luau"
} >"$out"
luau "$out"
