--!strict
-- PKCE helpers: SHA-256 (RFC 6234) and base64url (RFC 4648 §5, no padding).
-- Luau ships no hash function and Tern exposes none, so the digest is computed here.

local band, bxor, bnot, rshift, rrotate = bit32.band, bit32.bxor, bit32.bnot, bit32.rshift, bit32.rrotate

local K: { number } = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local M = {}

-- The raw 32-byte SHA-256 digest of `msg`.
function M.sha256(msg: string): string
	local len = #msg
	-- Padding: 0x80, zeros up to 56 mod 64, then the bit length as a 64-bit big-endian integer.
	local padded = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
	local bits = len * 8
	padded ..= string.pack(">I4I4", bits // 0x100000000, bits % 0x100000000)

	local h0, h1, h2, h3, h4, h5, h6, h7 =
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

	local w: { number } = table.create(64, 0)
	for chunk = 1, #padded, 64 do
		for i = 0, 15 do
			w[i + 1] = string.unpack(">I4", padded, chunk + i * 4)
		end
		for i = 17, 64 do
			local a, b = w[i - 15], w[i - 2]
			local s0 = bxor(rrotate(a, 7), rrotate(a, 18), rshift(a, 3))
			local s1 = bxor(rrotate(b, 17), rrotate(b, 19), rshift(b, 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 0x100000000
		end

		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = (h + S1 + ch + K[i] + w[i]) % 0x100000000
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = (S0 + maj) % 0x100000000
			h, g, f, e, d, c, b, a = g, f, e, (d + t1) % 0x100000000, c, b, a, (t1 + t2) % 0x100000000
		end

		h0, h1, h2, h3 = (h0 + a) % 0x100000000, (h1 + b) % 0x100000000, (h2 + c) % 0x100000000, (h3 + d) % 0x100000000
		h4, h5, h6, h7 = (h4 + e) % 0x100000000, (h5 + f) % 0x100000000, (h6 + g) % 0x100000000, (h7 + h) % 0x100000000
	end
	return string.pack(">I4I4I4I4I4I4I4I4", h0, h1, h2, h3, h4, h5, h6, h7)
end

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

-- base64url without padding.
function M.base64url(bytes: string): string
	local out = {}
	for i = 1, #bytes, 3 do
		local a, b, c = string.byte(bytes, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1, c2, c3, c4 = rshift(n, 18), band(rshift(n, 12), 63), band(rshift(n, 6), 63), band(n, 63)
		table.insert(out, string.sub(ALPHABET, c1 + 1, c1 + 1))
		table.insert(out, string.sub(ALPHABET, c2 + 1, c2 + 1))
		if b then
			table.insert(out, string.sub(ALPHABET, c3 + 1, c3 + 1))
		end
		if c then
			table.insert(out, string.sub(ALPHABET, c4 + 1, c4 + 1))
		end
	end
	return table.concat(out)
end

-- The S256 code challenge for a PKCE code verifier.
function M.challenge(verifier: string): string
	return M.base64url(M.sha256(verifier))
end

-- Hex of a byte string; for tests and logs.
function M.hex(bytes: string): string
	return (string.gsub(bytes, ".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

return M
