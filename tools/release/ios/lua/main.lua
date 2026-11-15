-- Balatro Overhaul for iOS: bootstrap. GPL-3.0-or-later.
-- If the Overhaul was already built from the user's own Balatro, start it.
-- Otherwise (or when reimport is requested) show the import screen.
local install = require("overhaul_install")
local importer = require("ios_import").attach(install)
local runtime = require("ios_runtime")

local plan = install.plan()
if plan.have and not plan.need and not importer.take_menu_request() then
	runtime.before_launch()
	if install.launch(plan.have) then
		runtime.after_launch()
		return
	end
	importer.launch_failed = true
end
importer.start_ui(plan)
