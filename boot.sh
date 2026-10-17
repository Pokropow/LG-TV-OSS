#!/bin/sh
set +x
IP=$1
ssh root@$IP "mkdir -p os_loader" 2>/dev/null

files=(kexec/sbin/kexec Image boot-initramfs.cpio.gz modules/fix_stuck_cpus.ko)

for file in "${files[@]}"; do
    if [ ! -f build/$file ]; then
        echo "local file $file is missing"
        exit 1
    fi
    target_name=`basename $file`
    local_file_hash_res=$(sha1sum build/$file)
    IFS=" " read -r local_hash _ <<< "$local_file_hash_res"

    remote_hash_res=$(ssh root@$IP "sha1sum os_loader/$target_name" 2>/dev/null)

    IFS=" " read -r remote_hash _ <<< "$remote_hash_res"

    if [[ "$remote_hash" != "$local_hash" ]]; then
        printf "file: %s local hash: %s, remote hash: %s\n" $file $local_hash $remote_hash
        scp build/$file root@$IP:os_loader/$target_name
    fi
done

echo "Booting OS"

cat tv-env.sh boot_kernel.sh | ssh root@$IP "bash -s"