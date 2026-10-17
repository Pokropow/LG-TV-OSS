docker run --platform linux/arm64 --name alpine-builder -v "$PWD/build:/root/build" -td alpine-builder-aarch64

if [ -f "$PWD/build/kexec/sbin/kexec" ]; then
    echo "kexec already compiled. Skipping."
else
    echo "Compiling kexec from source."
    cat alpine/build_kexec.sh | docker exec -i alpine-builder sh -s
fi

if [ -f "$PWD/build/busybox/busybox" ]; then
    echo "busybox already compiled. Skipping."
else
    echo "Compiling busybox from source."
    cat alpine/build_busybox.sh | docker exec -i alpine-builder sh -s
fi

sh alpine/build-boot-initramfs.sh

cat alpine/build-alpine-rootfs.sh | docker exec -i alpine-builder sh -s

docker stop alpine-builder
docker rm alpine-builder