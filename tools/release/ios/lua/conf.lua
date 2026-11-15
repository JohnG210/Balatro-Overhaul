-- Balatro Overhaul for iOS: launcher window settings. GPL-3.0-or-later.
love.conf = function(t)
	t.identity = "BalatroOverhaul"
	t.version = "11.5"
	t.console = false
	t.title = "Balatro Overhaul"
	t.window.width = 0
	t.window.height = 0
	t.window.fullscreen = true
	t.window.highdpi = true
	t.window.minwidth, t.window.minheight = 100, 100
end
