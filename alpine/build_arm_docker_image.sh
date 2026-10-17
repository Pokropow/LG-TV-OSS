# NO multiarch/qemu-user-static --reset here. aarch64 binfmt comes from the
# host's qemu-user-static-binfmt package (see docs/INSTALL.md), registered
# persistently by systemd-binfmt. Re-running the multiarch container would
# replace that registration with whatever qemu is baked into the image -- a
# three-year-old build of it crashed gcc at random while compiling busybox,
# in four different files across four runs.
docker --debug build --platform linux/arm64 -t alpine-builder-aarch64 .