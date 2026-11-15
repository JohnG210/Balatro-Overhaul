-- Balatro Overhaul for iOS: import-your-own-game launcher.
-- Copyright (C) 2026 Balatro Overhaul iOS port contributors. GPL-3.0-or-later.
--
-- The user picks THEIR OWN Balatro file (Steam Balatro.exe, Balatro.love,
-- or a .zip of the Balatro folder / Balatro.app) in the iOS Files picker.
-- The file is copied into the app sandbox, opened as a zip, checked and
-- patched on the device by the Overhaul's own pure-Lua patcher
-- (patcher/apply.lua via overhaul_install.lua). Lovely patches are applied
-- at game start by the Overhaul's Lua modloader; nothing is injected
-- natively. No game file is ever sent anywhere.

local M = {}

M.PICKED = "picked_game.bin"
M.MENU = "ios_menu"
M.REIMPORT_DOC = "reimport.txt"
M.NEED = "1.0.1o-FULL"

local install

local function save_path(rel)
	return (love.filesystem.getSaveDirectory():gsub("/$", "")) .. "/" .. rel
end
M.save_path = save_path

function M.native()
	if M._native == nil then
		local ok, mod = pcall(require, "overhaul_ios")
		M._native = (ok and type(mod) == "table") and mod or false
	end
	return M._native or nil
end

local function sniff(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local head = f:read(4) or ""
	local size = f:seek("end") or 0
	f:close()
	return head, size
end

local INNER = {
	"Balatro.love", "game.love", "assets/game.love",
	"Contents/Resources/Balatro.love", "Balatro.app/Contents/Resources/Balatro.love",
}

local function is_root(fs, dir)
	return fs.getInfo(dir .. "/version.jkr", "file") and fs.getInfo(dir .. "/main.lua", "file")
end

local function find_root(mount)
	local fs = love.filesystem
	if is_root(fs, mount) then return mount .. "/" end
	if fs.getInfo(mount .. "/assets/version.jkr", "file") then return mount .. "/assets/" end
	for _, item in ipairs(fs.getDirectoryItems(mount)) do
		if is_root(fs, mount .. "/" .. item) then return mount .. "/" .. item .. "/" end
	end
	return nil
end

local function find_inner(mount)
	local fs = love.filesystem
	for _, rel in ipairs(INNER) do
		if fs.getInfo(mount .. "/" .. rel, "file") then return mount .. "/" .. rel end
	end
	for _, item in ipairs(fs.getDirectoryItems(mount)) do
		for _, rel in ipairs(INNER) do
			local p = mount .. "/" .. item .. "/" .. rel
			if fs.getInfo(p, "file") then return p end
		end
	end
	return nil
end

-- Replaces overhaul_install's Android-only source (OVERHAUL_OFFICIAL_APK).
-- Returns the vanilla root inside the mounted copy, or nil, code, detail.
function M.open(report, copy)
	local fs = love.filesystem
	local src = save_path(M.PICKED)
	local head, size = sniff(src)
	if not head then return nil, "not_found" end
	local magic = head:sub(1, 2)
	if size < 22 or (magic ~= "PK" and magic ~= "MZ") then return nil, "not_zip" end
	copy(src, report)
	fs.unmount(install.COPY)
	if not fs.mount(install.COPY, install.MOUNT) then
		fs.remove(install.COPY)
		return nil, "not_zip"
	end
	local root = find_root(install.MOUNT)
	if root then return root end
	local inner = find_inner(install.MOUNT)
	if inner then
		local data = fs.read(inner)
		fs.unmount(install.COPY)
		fs.remove(install.COPY)
		if not data or not fs.write(install.COPY, data) then return nil, "failed", "inner copy" end
		data = nil
		collectgarbage()
		if not fs.mount(install.COPY, install.MOUNT) then
			fs.remove(install.COPY)
			return nil, "not_zip"
		end
		root = find_root(install.MOUNT)
		if root then return root end
	end
	return nil, "not_game"
end

function M.attach(inst)
	install = inst
	install.ios_open = M.open
	return M
end

M.MESSAGES = {
	not_found = "No game file was received. Tap Import and choose your Balatro file again.",
	not_zip = "That file is not a Balatro game file. Choose Balatro.exe from your Steam Balatro folder, Balatro.love, or a .zip of the Balatro folder.",
	not_game = "That archive has no Balatro game in it (no main.lua and version.jkr). Zip the whole Balatro folder, or pick Balatro.exe.",
	bad_version = "This Balatro copy (%s) does not match. This Overhaul version needs the unmodded Steam version " .. M.NEED .. ". Update Balatro on Steam, then copy Balatro.exe again.",
	damaged = "The Overhaul update file is damaged. Try again.",
	folder = "That is a folder. Choose one file: Balatro.exe, Balatro.love, or a .zip.",
	cancelled = "No file chosen.",
	failed = "Import failed: %s",
	launch = "The installed Overhaul did not start. Import your Balatro file again.",
	updated = "The Overhaul was updated. Import your Balatro file again to rebuild it.",
}

function M.explain(code, detail)
	local msg = M.MESSAGES[code] or M.MESSAGES.failed
	if msg:find("%s", 1, true) then
		msg = msg:format(tostring(detail or code))
	end
	return msg
end

-- Runs the whole import synchronously (inside a coroutine for the UI).
-- Returns true, or false, code, detail.
function M.import_now(report)
	report = report or function() end
	local plan = install.plan(true)
	local ok, why, detail = install.run(report, plan)
	os.remove(save_path(M.PICKED))
	if ok == true then return true end
	return false, why or "failed", detail
end

-- Copy a desktop path into the sandbox (simulator / desktop testing only).
function M.copy_in(path)
	local inp = io.open(path, "rb")
	if not inp then return false, "not_found" end
	local out = io.open(save_path(M.PICKED), "wb")
	if not out then inp:close() return false, "failed" end
	while true do
		local chunk = inp:read(4 * 1024 * 1024)
		if not chunk then break end
		out:write(chunk)
	end
	inp:close()
	out:close()
	return true
end

function M.take_menu_request()
	local asked = false
	if love.filesystem.getInfo(M.MENU) then
		love.filesystem.remove(M.MENU)
		asked = true
	end
	local native = M.native()
	local docs = native and native.documents and native.documents()
	if docs then
		local p = docs .. "/" .. M.REIMPORT_DOC
		local f = io.open(p, "rb")
		if f then
			f:close()
			os.remove(p)
			asked = true
		end
	end
	return asked
end

------------------------------------------------------------------------
-- Minimal launcher UI (touch + mouse).
------------------------------------------------------------------------

local ui = {state = "menu", lines = {}, buttons = {}}

local function set_error(code, detail)
	ui.state = "error"
	ui.error = M.explain(code, detail)
end

local function start_job()
	ui.state = "working"
	ui.progress = {"copy", 0, 1}
	ui.job = coroutine.create(function()
		return M.import_now(function(stage, i, n)
			ui.progress = {stage, i or 0, n or 1}
			coroutine.yield()
		end)
	end)
end

local function start_pick()
	ui.error = nil
	local native = M.native()
	if native then
		native.reset()
		local ok, err = native.pick(save_path(M.PICKED))
		if not ok then return set_error("failed", err) end
		ui.state = "picking"
		return
	end
	local env = os.getenv("OVERHAUL_IOS_PICK")
	if env and env ~= "" then
		local ok, err = M.copy_in(env)
		if not ok then return set_error(err) end
		return start_job()
	end
	set_error("failed", "the Files picker is only available on iOS")
end

local function play()
	love.filesystem.remove(M.MENU)
	love.event.quit("restart")
end

function M.start_ui(plan)
	plan = plan or install.plan()
	ui.installed = plan.have ~= nil and not plan.need
	if M.launch_failed then
		set_error("launch")
	elseif plan.have and plan.need then
		ui.state = "error"
		ui.error = M.MESSAGES.updated
	end

	function love.load() end

	function love.update()
		if ui.state == "picking" then
			local native = M.native()
			local st, a = native.poll()
			if st == "done" then
				native.reset()
				start_job()
			elseif st == "cancelled" then
				native.reset()
				set_error("cancelled")
			elseif st == "error" then
				native.reset()
				set_error(a == "folder" and "folder" or "failed", a)
			end
		elseif ui.state == "working" and ui.job then
			local ok, res, code, detail = coroutine.resume(ui.job)
			if not ok then
				ui.job = nil
				set_error("failed", res)
			elseif coroutine.status(ui.job) == "dead" then
				ui.job = nil
				if res == true then
					ui.state = "ready"
					ui.installed = true
					if ui.autoplay then
						ui.autoplay = nil
						return play()
					end
				else
					ui.autoplay = nil
					set_error(code, detail)
				end
			end
		end
	end

	local function layout(w, h)
		local bw, bh = math.min(w * 0.8, 520), math.max(56, h * 0.07)
		local x = (w - bw) / 2
		local list = {}
		if ui.state ~= "working" and ui.state ~= "picking" then
			list[#list + 1] = {label = ui.installed and "Import again" or "Import my Balatro file", run = start_pick}
			if ui.installed then list[#list + 1] = {label = "Play", run = play} end
		end
		local y = h * 0.62
		for _, b in ipairs(list) do
			b.x, b.y, b.w, b.h = x, y, bw, bh
			y = y + bh * 1.3
		end
		ui.buttons = list
	end

	function love.draw()
		local w, h = love.graphics.getDimensions()
		layout(w, h)
		love.graphics.clear(0.13, 0.18, 0.22)
		love.graphics.setColor(1, 1, 1)
		local pad = w * 0.08
		love.graphics.printf("Balatro Overhaul", pad, h * 0.12, (w - 2 * pad) / 2, "center", 0, 2, 2)
		local body
		if ui.state == "working" then
			local p = ui.progress or {"", 0, 1}
			local label = p[1] == "copy" and "Copying your game" or p[1] == "find" and "Checking your game" or "Patching"
			local frac = (p[3] and p[3] > 0) and (p[2] / p[3]) or 0
			body = string.format("%s... %d%%", label, math.floor(frac * 100))
		elseif ui.state == "picking" then
			body = "Choose your Balatro file in the Files window."
		elseif ui.state == "ready" then
			body = "Installed. Tap Play."
		elseif ui.state == "error" then
			love.graphics.setColor(1, 0.55, 0.5)
			body = ui.error
		elseif ui.installed then
			body = "The Overhaul is installed. Tap Play, or import your game again."
		else
			body = "You need your own copy of Balatro (Steam).\nCopy Balatro.exe from your Balatro folder (or a .zip of the folder) to this device with AirDrop, iCloud Drive or a cable, then tap Import.\nNothing from Balatro is included in this app, and your file stays on this device."
		end
		love.graphics.printf(body or "", pad, h * 0.3, w - 2 * pad, "center")
		for _, b in ipairs(ui.buttons) do
			love.graphics.setColor(0.99, 0.37, 0.33)
			love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 12, 12)
			love.graphics.setColor(1, 1, 1)
			local fh = love.graphics.getFont():getHeight()
			love.graphics.printf(b.label, b.x, b.y + (b.h - fh) / 2, b.w, "center")
		end
	end

	local function press(x, y)
		for _, b in ipairs(ui.buttons) do
			if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
				b.run()
				return
			end
		end
	end
	function love.mousepressed(x, y, button, istouch)
		if not istouch then press(x, y) end
	end
	function love.touchpressed(_, x, y)
		press(x, y)
	end
end

M._ui = ui
return M
