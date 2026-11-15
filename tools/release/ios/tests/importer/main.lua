-- Headless importer test (LOVE 11.5 desktop). Synthetic fixtures only.
local install = require("overhaul_install")
local importer = require("ios_import").attach(install)
local fixtures = os.getenv("FIXTURES")
local fails, n = 0, 0

local function check(name, file, want_code, want_detail)
	n = n + 1
	os.remove(importer.save_path(importer.PICKED))
	if file then assert(importer.copy_in(fixtures .. "/" .. file)) end
	local ok, code, detail = importer.import_now()
	local msg = importer.explain(code, detail)
	local good = ok == false and code == want_code and (not want_detail or tostring(detail):find(want_detail, 1, true))
	if not good then fails = fails + 1 end
	print(string.format("%s %-22s -> %s %s | %s", good and "PASS" or "FAIL", name, tostring(code), tostring(detail), msg))
	if love.filesystem.getInfo(install.COPY) or love.filesystem.getInfo(importer.PICKED) then
		fails = fails + 1
		print("FAIL leftover copy of the picked file in the sandbox")
	end
end

function love.load()
	for _, f in ipairs({"main.lua", "conf.lua", "ios_import.lua", "overhaul_install.lua"}) do
		local chunk, err = love.filesystem.load(f == "main.lua" and "main_real.lua" or f)
		n = n + 1
		if not chunk then fails = fails + 1 print("FAIL compile " .. f .. ": " .. tostring(err)) else print("PASS compile " .. f) end
	end
	n = n + 1
	local p = install.bundled()
	if p and p.man and p.man.overhaul_name then print("PASS bundled patch set " .. p.man.overhaul_name .. " / " .. p.version)
	else fails = fails + 1 print("FAIL bundled patch set not readable") end
	check("missing file", nil, "not_found")
	check("random bytes", "random.bin", "not_zip")
	check("fake exe (MZ, no zip)", "fake.exe", "not_zip")
	check("zip without game", "nogame.zip", "not_game")
	check("wrong version folder", "folder.zip", "bad_version", "0.9.0-FAKE")
	check("wrong version exe", "Balatro.exe", "bad_version", "0.9.0-FAKE")
	check("wrong version app zip", "app.zip", "bad_version", "0.9.0-FAKE")
	print(string.format("RESULT %s (%d checks, %d failures)", fails == 0 and "PASS" or "FAIL", n, fails))
	love.event.quit(fails == 0 and 0 or 1)
end
