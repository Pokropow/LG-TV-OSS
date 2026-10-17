# Force Docker to pull the aarch64 (ARM64) variant of the image
FROM --platform=linux/arm64 alpine:3.24

ENV DEBIAN_FRONTEND=noninteractive

# Install core build tools and dependencies inside the ARM64 environment
# RUN apt-get update && apt-get install -y \
#     sudo \
#     git \
#     python3 \
#     python3-pip \
#     curl \
#     lsb-release \
#     software-properties-common \
#     locales \
#     && rm -rf /var/lib/apt/lists/*

RUN apk update && apk add git sudo python3 curl build-base linux-headers

# Set up locale (required by many KDE build tools)
# RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create a non-root user (kde-builder should NOT be run as root)
# RUN useradd -m -s /bin/bash user && \
#     user "kdeuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
RUN adduser user -D -s /bin/ash
# RUN echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
#
# USER user
WORKDIR /root
# COPY build-alpine-rootfs.sh .
# COPY packages.txt .
# COPY overlay ./overlay
COPY . .
# Clone the official kde-builder tool
# RUN git clone https://kde.org /home/kdeuser/kde-builder

# Set up the environment
CMD ["/bin/ash"]
