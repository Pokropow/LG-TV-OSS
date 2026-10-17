#!/bin/sh
set -e
set -x

apk add autoconf

mkdir -p build

wget https://github.com/horms/kexec-tools/archive/refs/tags/v2.0.32.tar.gz
tar -xvzf v2.0.32.tar.gz
cd kexec-tools-2.0.32/
./bootstrap
LDFLAGS=-static ./configure
make install DESTDIR="`realpath ../build/kexec`" prefix=/