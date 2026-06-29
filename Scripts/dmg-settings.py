# dmgbuild settings for AgentMeter. Invoked by Scripts/dmg.sh:
#   dmgbuild -s Scripts/dmg-settings.py -D app=... -D background=... "AgentMeter" out.dmg
#
# dmgbuild writes the .DS_Store directly (no Finder/AppleScript), so the window
# layout and background render reliably in headless/CI environments — unlike
# create-dmg, whose Finder-scripted alias background did not resolve on the final
# read-only volume. Icon positions here must match make-assets.py's layout.
import os.path

app = defines.get("app", "dist/AgentMeter.app")
appname = os.path.basename(app)

# Volume contents
files = [app]
symlinks = {"Applications": "/Applications"}

# Output format
format = "UDZO"

# Window + icon view
background = defines.get("background", "Scripts/dmg-background.tiff")
# Height includes the title bar (~28pt). The background is 600x400, so the window
# must be ~428 tall or the content area is shorter than the background and Finder
# shows a vertical scrollbar.
window_rect = ((200, 150), (600, 430))   # ((x, y), (width, height))
icon_size = 128
text_size = 13
icon_locations = {
    appname: (150, 235),
    "Applications": (450, 235),
}
