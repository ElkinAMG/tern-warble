--!strict
-- Run: luau tests/pkce.test.luau
local pkce = require("../pkce")

local failures = 0
local function eq(name: string, got: string, want: string)
	if got ~= want then
		failures += 1
		print(`FAIL {name}\n  got  {got}\n  want {want}`)
	end
end

-- FIPS 180-4 vectors: empty, one block, and a message whose padding spills into a second block.
eq("sha256 empty", pkce.hex(pkce.sha256("")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
eq("sha256 abc", pkce.hex(pkce.sha256("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
eq(
	"sha256 two-block",
	pkce.hex(pkce.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
	"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
)
eq("sha256 55 bytes", pkce.hex(pkce.sha256(string.rep("a", 55))), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
eq("sha256 56 bytes", pkce.hex(pkce.sha256(string.rep("a", 56))), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")

-- RFC 7636 Appendix B.
eq("pkce challenge", pkce.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

-- base64url padding boundaries (RFC 4648 vectors, URL alphabet, no padding).
eq("b64 1 byte", pkce.base64url("f"), "Zg")
eq("b64 2 bytes", pkce.base64url("fo"), "Zm8")
eq("b64 3 bytes", pkce.base64url("foo"), "Zm9v")
eq("b64 url alphabet", pkce.base64url("\251\255\254"), "-__-")

if failures > 0 then
	error(`{failures} failure(s)`)
end
print("pkce: ok")
