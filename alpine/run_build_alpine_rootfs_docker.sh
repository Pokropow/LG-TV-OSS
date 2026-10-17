#!/bin/sh
set -e
set -x
SELF="$(cd "$(dirname "$0")" && pwd)"

echo $SELF
cd alpine
# sudo rm -rf alpine-rootfs
mkdir -p alpine-rootfs
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker --debug build --platform linux/arm64 -t alpine-builder-aarch64 .
docker run --platform linux/arm64 -it \
  -v $SELF/alpine-rootfs:/root/alpine-workspace \
  alpine-builder-aarch64 sh build-alpine-rootfs.sh
cd ..

echo
echo "done. rootfs tree: $ROOTFS"
echo "write it with:  sudo $SELF/write-alpine-usb.sh /dev/sdX"
