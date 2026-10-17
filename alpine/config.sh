# Shared settings for build-alpine-rootfs.sh and write-alpine-usb.sh.
# Every value can be overridden from the environment.
#
# Sourced, not executed. Expects SELF (this directory) and HERE (project root)
# to already be set.

# edge, because Plasma Bigscreen is only in edge/community.
ALPINE_BRANCH="${ALPINE_BRANCH:-edge}"
ARCH="${ARCH:-aarch64}"

# Filesystem labels. The kernel is told root=LABEL=$LABEL, so changing this
# means changing the kexec command line too.
LABEL="${LABEL:-alpineroot}"
SWAPLABEL="${SWAPLABEL:-alpineswap}"

# Sized for hibernation, which needs to fit a compressed image of all of RAM.
# SWAP_SIZE=0 skips the swap partition entirely.
SWAP_SIZE="${SWAP_SIZE:-4G}"

TV_HOSTNAME="${TV_HOSTNAME:-lgtv}"

# Where build-alpine-rootfs.sh leaves the prepared tree, and where
# write-alpine-usb.sh reads it from.
ROOTFS="${ROOTFS:-$SELF/alpine-rootfs}"
