# Per-user, not hardcoded to 0: the session runs unprivileged.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
[ -d "$XDG_RUNTIME_DIR" ] || mkdir -p -m 0700 "$XDG_RUNTIME_DIR"

export XDG_SESSION_TYPE=wayland

# Without this, Qt apps launched inside the session default to the xcb
# platform plugin, fail to reach a display and exit.
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1

# lg1k drives the panel but exposes no render node; panfrost does the
# rendering. wlroots needs to be told to use separate devices for the two.
[ -e /dev/dri/renderD128 ] && export WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128

# Deliberately NOT set: WLR_BACKENDS (restricting it to "drm" drops the
# libinput backend and the session gets no input at all) and WLR_RENDERER
# (leave it unset so wlroots uses the GPU; set it to pixman only to fall
# back to software rendering for comparison).
