-- Balatro Overhaul for iOS: runtime fixes applied around the game.
-- Copyright (C) 2026 Balatro Overhaul iOS port contributors. GPL-3.0-or-later.
--
-- 1. jit.opt shim: the iOS LuaJIT is built without the JIT compiler, so
--    jit.opt is nil. The Overhaul's main.lua calls jit.opt.start() on
--    non-arm builds (the x86_64 Simulator). A no-op keeps it from crashing.
-- 2. On-screen keyboard: on iOS, LOVE only shows the keyboard while text
--    input is enabled (love.keyboard.setTextInput). The desktop game never
--    enables it, so tapping a text box did nothing. This follows the game's
--    own focus state (G.CONTROLLER.text_input_hook): keyboard up while a
--    text box is focused, down when focus ends. A tap while a box is still
--    focused but the keyboard was dismissed brings it back.

local M = {}

-- Debug trace (only while ios_kb_debug exists in the save directory).
function M.log(...)
	if not love.filesystem.getInfo("ios_kb_debug") then return end
	local t = {}
	for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
	love.filesystem.append("ios_kb.log", os.date("%H:%M:%S ") .. string.format("%.2f ", love.timer.getTime()) .. table.concat(t, " ") .. "\n")
end

function M.before_launch()
	-- 3. Multiplayer: start the native TLS tunnel the game expects on
	--    127.0.0.1:44380 (see ios/native/overhaul_ios.mm).
	local ok, ios = pcall(require, "overhaul_ios")
	if ok and type(ios) == "table" and ios.tunnel_start then pcall(ios.tunnel_start) end
	if type(jit) == "table" and jit.opt == nil then
		jit.opt = {start = function() end}
	end
	-- 7. Window mode: the game restores a saved "resolution" (and windowed
	--    mode) from its settings. On a phone that is just the screen size
	--    from last time, which is wrong after a rotation or an iPhone Duo
	--    fold/unfold and left the game drawing in part of the screen. Always
	--    use the current full screen instead.
	local lw = love.window
	if lw and not lw.__ios_mode_wrapped then
		local function fix(w, h, flags)
			flags = type(flags) == "table" and flags or {}
			flags.fullscreen = true
			flags.fullscreentype = "desktop"
			flags.resizable = true
			flags.highdpi = true
			local vw, vh
			if ok and type(ios) == "table" and ios.view_size then vw, vh = ios.view_size() end
			if not vw then vw, vh = lw.getDesktopDimensions() end
			M.log("mode", w, h, "->", vw, vh)
			return vw or w, vh or h, flags
		end
		local setMode, updateMode = lw.setMode, lw.updateMode
		lw.setMode = function(...) return setMode(fix(...)) end
		lw.updateMode = function(...) return updateMode(fix(...)) end
		lw.__ios_mode_wrapped = true
	end
end

local function focused()
	local g = rawget(_G, "G")
	local c = type(g) == "table" and g.CONTROLLER
	return type(c) == "table" and c.text_input_hook or nil
end

-- 4. Capital letters: the iOS keyboard reports a capital as Shift-down,
--    key-down, key-up, Shift-up all in one go. The game only checks Shift
--    when it handles the key on the next frame, by which time Shift is
--    already released, so every letter came out lower case. Remember
--    whether Shift was held at the moment each key went down and replay
--    that when the game handles it.
local function wrap_shift(C)
	if type(C) ~= "table" or C.__ios_shift_wrapped then return end
	if type(C.key_press) ~= "function" or type(C.key_press_update) ~= "function" then return end
	local key_press, key_press_update = C.key_press, C.key_press_update
	C.key_press = function(self, key, ...)
		local h = self.held_keys
		if h and (h.lshift or h.rshift) then
			self.__ios_shifted = self.__ios_shifted or {}
			self.__ios_shifted[key] = true
		elseif self.__ios_shifted then
			self.__ios_shifted[key] = nil
		end
		return key_press(self, key, ...)
	end
	C.key_press_update = function(self, key, ...)
		local s = self.__ios_shifted
		local h = self.held_keys
		if s and s[key] and h and not (h.lshift or h.rshift) then
			s[key] = nil
			h.lshift = true
			local r = {pcall(key_press_update, self, key, ...)}
			h.lshift = nil
			if not r[1] then error(r[2], 0) end
			return unpack(r, 2)
		end
		if s then s[key] = nil end
		return key_press_update(self, key, ...)
	end
	C.__ios_shift_wrapped = true
end

-- 5. Haptics: the game queues buzzes in G.HAPTIC_LEVEL (1-4) but only plays
--    them on Android. Play them on the Taptic Engine instead, honouring the
--    in-game Haptic Feedback toggle and Haptic Intensity slider.
local ios_native
local function play_haptics()
	local g = rawget(_G, "G")
	local level = type(g) == "table" and g.HAPTIC_LEVEL
	if type(level) ~= "number" or level <= 0 then return end
	g.HAPTIC_LEVEL = 0
	local st = g.SETTINGS
	if not (st and st.haptic_feedback) then return end
	if ios_native == nil then
		local ok, mod = pcall(require, "overhaul_ios")
		ios_native = ok and type(mod) == "table" and mod.haptic and mod or false
	end
	if not ios_native then return end
	local i = (st.haptic_intensity or 50) / 100
	M.log("haptic", level, i)
	pcall(ios_native.haptic, level, math.min(1, 0.25 + i * 0.75) * (i > 0 and 1 or 0))
end

-- 6. Screen size changes (iPhone Duo fold/unfold, rotation): make sure the
--    game re-lays itself out when the drawable size changes.
local last_w, last_h, resized_to
local last_sync = -10
local function native()
	if ios_native == nil then
		local ok, mod = pcall(require, "overhaul_ios")
		ios_native = ok and type(mod) == "table" and mod or false
	end
	return ios_native
end
local function watch_size()
	local w, h = love.graphics.getDimensions()
	-- After a rotation or iPhone Duo fold/unfold the GL drawable can be left
	-- at an in-between size, so the game draws into part of the screen.
	-- Check every frame (at most every 0.1 s) and rebuild it if it is stale.
	local n = native()
	local now = love.timer.getTime()
	if n and n.sync_size and now - last_sync > 0.1 then
		last_sync = now
		local force = false
		if n.view_size then
			local vw, vh = n.view_size()
			force = vw ~= nil and (math.abs(vw - w) > 1 or math.abs(vh - h) > 1)
		end
		if force then M.log("force sync") end
		local ok2, fixed = pcall(n.sync_size, force)
		if ok2 and fixed then M.log("drawable resynced") end
	end
	if w == last_w and h == last_h then
		-- A stale love.resize (old orientation) can arrive after the drawable
		-- already has its new size; the game would then lay out for the old
		-- size and leave a black bar. Re-send the real size.
		if resized_to and resized_to ~= w .. "x" .. h and love.resize then
			M.__stale_since = M.__stale_since or now
			if now - M.__stale_since > 0.3 then
				M.__stale_since = nil
				M.log("late stale resize", resized_to, "->", w, h)
				love.resize(w, h)
			end
		else
			M.__stale_since = nil
		end
		return
	end
	local pw, ph = love.graphics.getPixelDimensions()
	local ww, wh = love.window.getMode()
	M.log("size", w, h, "px", pw, ph, "win", ww, wh, "resized_to", tostring(resized_to))
	local first = last_w == nil
	last_w, last_h = w, h
	if not first and resized_to ~= w .. "x" .. h and love.resize then
		M.log("forcing resize", w, h)
		love.resize(w, h)
	end
end

function M.after_launch()
	local resize = love.resize
	love.resize = function(w, h, ...)
		resized_to = tostring(w) .. "x" .. tostring(h)
		M.log("love.resize", w, h)
		local r
		if resize then r = {resize(w, h, ...)} end
		-- The menu background and play area normally ease to their new size,
		-- which after a rotation/fold leaves black gaps for a second or two.
		-- Snap them instead.
		local g = rawget(_G, "G")
		if type(g) == "table" then
			for _, o in ipairs({g.SPLASH_BACK, g.ROOM, g.ROOM_ATTACH}) do
				if type(o) == "table" and o.T and o.VT then
					if o.hard_set_VT then pcall(o.hard_set_VT, o)
					else for k, v in pairs(o.T) do o.VT[k] = v end end
				end
			end
		end
		if r then return unpack(r) end
	end

	local kb = love.keyboard
	if not (kb and kb.setTextInput and kb.hasTextInput) then return end
	local shown, tapped = false, false

	local update = love.update
	love.update = function(...)
		if update then
			local r = {update(...)}
			pcall(play_haptics)
			M.frame(kb)
			return unpack(r)
		end
		pcall(play_haptics)
		M.frame(kb)
	end

	M.frame = function(kb)
		pcall(watch_size)
		if not rawget(_G, "__ios_shift_done") then
			local C = rawget(_G, "Controller")
			if type(C) == "table" then
				pcall(wrap_shift, C)
				rawset(_G, "__ios_shift_done", true)
			end
		end
		local hook = focused()
		local want = hook ~= nil
		if want then
			if (not shown or tapped) and not kb.hasTextInput() then
				kb.setTextInput(true)
			end
			shown = true
		elseif shown then
			if kb.hasTextInput() then kb.setTextInput(false) end
			shown = false
		end
		tapped = false
	end

	local mousepressed = love.mousepressed
	love.mousepressed = function(...)
		tapped = true
		if mousepressed then return mousepressed(...) end
	end
	local touchpressed = love.touchpressed
	love.touchpressed = function(...)
		tapped = true
		if touchpressed then return touchpressed(...) end
	end
	M.installed = true
end

return M
