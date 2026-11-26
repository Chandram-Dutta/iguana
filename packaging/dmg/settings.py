# The disk image's window, for dmgbuild. scripts/dmg.sh runs it:
#
#   dmgbuild -s packaging/dmg/settings.py -D app=<Iguana.app> -D background=<background.png> \
#       -D icon=<Iguana.icns> "Iguana <version>" <output.dmg>
#
# dmgbuild writes the window's layout (the .DS_Store) itself. Finder is never opened, so a
# release can be made on a Mac with nobody sitting at it.

import os.path

# dmgbuild runs this file with "defines" already set from the -D options.
app = defines["app"]  # noqa: F821
picture = defines["background"]  # noqa: F821
volume_icon = defines["icon"]  # noqa: F821

# What the picture and Finder have to agree on. packaging/dmg/background.swift draws the tongue
# from one icon to the other, so these two places are in that file as well.
APP_AT = (165, 180)
APPLICATIONS_AT = (495, 180)
PICTURE_SIZE = (660, 420)

# Finder counts the title bar as part of the window. It is 28 points high on macOS 14 and 15
# and 32 on macOS 27. With the smaller of the two the window is never taller than the picture,
# which would show a bare strip under it; where the title bar is higher, the last 4 points of
# plain green are cut off instead.
TITLE_BAR = 28

# Compressed, as the image always was. HFS+ is the file system dmgbuild is made for and the one
# disk images with a picture have always used; every macOS that Iguana runs on reads it.
format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}

# The volume's own icon, on the desktop and in the sidebar.
icon = volume_icon

# dmgbuild looks for background@2x.png beside this file and packs the two into one picture
# with both sizes, hidden on the volume as .background.tiff.
background = picture

# Where the window opens matters little: Finder moves it onto the screen if need be.
window_rect = ((200, 200), (PICTURE_SIZE[0], PICTURE_SIZE[1] + TITLE_BAR))
default_view = "icon-view"
include_icon_view_settings = True

show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False

# The icons stay where they are put: nothing sorts them or snaps them to a grid.
arrange_by = None
grid_offset = (0, 0)
scroll_position = (0, 0)
icon_size = 128
text_size = 13
label_pos = "bottom"
show_icon_preview = False
show_item_info = False

icon_locations = {
    os.path.basename(app.rstrip("/")): APP_AT,
    "Applications": APPLICATIONS_AT,
}
