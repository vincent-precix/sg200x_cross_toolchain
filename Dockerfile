ARG TARGET=milkv-duos-glibc-arm64-emmc
#ARG SDK_HASH=6f8962c394dd0a05729abb089f0feb7d5cc4aa5e
ARG SDK_HASH=main
ARG ARM_TOOLCHAIN_VERSION=14.3.Rel1
ARG RISCV_TOOLCHAIN_VERSION=15.2-r1
ARG CMAKE_VERSION=4.0.4
ARG BUILDPLATFORM
ARG TARGETPLATFORM
ARG TARGETARCH

FROM --platform=linux/amd64 milkvtech/milkv-duo:latest AS builder

WORKDIR /build
RUN git clone https://github.com/vincent-precix/duo-buildroot-sdk-v2.git sdk && \
    git clone https://github.com/milkv-duo/host-tools.git host-tools && \
    wget https://github.com/milkv-duo/duo-buildroot-sdk-v2/releases/download/dl/dl.tar


ARG SDK_HASH
WORKDIR /build/sdk
RUN git checkout ${SDK_HASH}

WORKDIR /build
RUN mv host-tools sdk/ && \
    tar xf dl.tar -C sdk/buildroot/ && \
    rm dl.tar

WORKDIR /build/sdk

ARG TARGET
ENV FORCE_UNSAFE_CONFIGURE=1

RUN TPU_REL=0 ./build.sh ${TARGET}

# we wont use the toolchains from host-tools because
# we will just use official toolchains

# firmware extraction
FROM scratch AS firmware-export
ARG TARGET
COPY --from=builder /build/sdk/out/ /firmware/

# cross-compile container
FROM debian:12-slim AS cross-compile

ARG TARGETARCH

# install base dependencies
RUN apt-get update && \
    apt-get install -y \
        wget \
        xz-utils \
        make \
        gdb-multiarch \
        openssh-server \
        pkg-config \
        && \
    apt-get -y remove --purge --auto-remove cmake && \
    rm -rf /var/lib/apt/lists/*

# install cmake from official kitware binary
ARG CMAKE_VERSION
RUN wget -q https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-$(uname -m).sh -O /tmp/cmake-install.sh && \
    chmod +x /tmp/cmake-install.sh && \
    /tmp/cmake-install.sh --skip-license --prefix=/usr && \
    rm /tmp/cmake-install.sh && \
    cmake --version

ARG TARGET
ARG ARM_TOOLCHAIN_VERSION
ARG RISCV_TOOLCHAIN_VERSION

# install toolchains based on TARGET
# for riscv64: download riscstar toolchain
# for arm64/arm32: download arm's official toolchain
RUN if echo "${TARGET}" | grep -qi "riscv\|cv180\|cv181"; then \
        # Map TARGETARCH to toolchain host naming
        if [ "${TARGETARCH}" = "amd64" ]; then \
            TOOLCHAIN_HOST="x86_64"; \
        elif [ "${TARGETARCH}" = "arm64" ]; then \
            TOOLCHAIN_HOST="aarch64"; \
        else \
            echo "unsupported TARGETARCH: ${TARGETARCH}"; \
            exit 1; \
        fi; \
        # Determine if target uses musl or glibc
        if echo "${TARGET}" | grep -qi "musl"; then \
            TOOLCHAIN_VARIANT="riscv64-none-linux-musl"; \
        else \
            TOOLCHAIN_VARIANT="riscv64-none-linux-gnu"; \
        fi; \
        TOOLCHAIN_URL="https://releases.riscstar.com/toolchain/${RISCV_TOOLCHAIN_VERSION}/riscstar-toolchain-${RISCV_TOOLCHAIN_VERSION}+qemu-${TOOLCHAIN_HOST}-${TOOLCHAIN_VARIANT}.tar.xz"; \
        echo "downloading RISCstar toolchain for riscv64 (${TOOLCHAIN_VARIANT}, host: ${TOOLCHAIN_HOST}) from: ${TOOLCHAIN_URL}"; \
        wget -q "${TOOLCHAIN_URL}" -O /tmp/toolchain.tar.xz && \
        mkdir -p /opt/toolchain && \
        tar xf /tmp/toolchain.tar.xz -C /opt/toolchain --strip-components=1 && \
        rm /tmp/toolchain.tar.xz; \
    elif echo "${TARGET}" | grep -qi "arm64\|aarch64"; then \
        # Map TARGETARCH to ARM's toolchain host naming
        if [ "${TARGETARCH}" = "amd64" ]; then \
            TOOLCHAIN_HOST="x86_64"; \
        elif [ "${TARGETARCH}" = "arm64" ]; then \
            TOOLCHAIN_HOST="aarch64"; \
        else \
            echo "unsupported TARGETARCH: ${TARGETARCH}"; \
            exit 1; \
        fi; \
        TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu/${ARM_TOOLCHAIN_VERSION}/binrel/arm-gnu-toolchain-${ARM_TOOLCHAIN_VERSION}-${TOOLCHAIN_HOST}-aarch64-none-linux-gnu.tar.xz"; \
        echo "downloading arm toolchain for aarch64 (host: ${TOOLCHAIN_HOST}) from: ${TOOLCHAIN_URL}"; \
        wget -q "${TOOLCHAIN_URL}" -O /tmp/toolchain.tar.xz && \
        mkdir -p /opt/toolchain && \
        tar xf /tmp/toolchain.tar.xz -C /opt/toolchain --strip-components=1 && \
        rm /tmp/toolchain.tar.xz; \
    fi

# add toolchain to path
ENV PATH="/opt/toolchain/bin:${PATH}"
RUN echo 'export PATH="/opt/toolchain/bin:$PATH"' >> /root/.bashrc

# copy the sysroot from the builder stage
COPY --from=builder /build/sdk/buildroot/output/${TARGET}/staging /opt/sysroot

# enable ssh
RUN mkdir -p /run/sshd && \
    echo 'root:root' | chpasswd && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# set up envars for cross compilation environment based on TARGET
RUN if echo "${TARGET}" | grep -qi "riscv\|cv180\|cv181"; then \
        if echo "${TARGET}" | grep -qi "musl"; then \
            CROSS_PREFIX="riscv64-none-linux-musl"; \
        else \
            CROSS_PREFIX="riscv64-none-linux-gnu"; \
        fi; \
    elif echo "${TARGET}" | grep -qi "arm64\|aarch64"; then \
        CROSS_PREFIX="aarch64-none-linux-gnu"; \
    else \
        CROSS_PREFIX="aarch64-none-linux-gnu"; \
    fi && \
    { \
        echo "export CROSS_COMPILE=${CROSS_PREFIX}-"; \
        echo "export SYSROOT=/opt/sysroot"; \
        echo "export CC=${CROSS_PREFIX}-gcc"; \
        echo "export CXX=${CROSS_PREFIX}-g++"; \
        echo "export PKG_CONFIG_LIBDIR=/opt/sysroot/usr/lib/pkgconfig:/opt/sysroot/usr/share/pkgconfig"; \
        echo "export PKG_CONFIG_SYSROOT_DIR=/opt/sysroot"; \
    } >> /root/.bashrc

# set environment variables for build tools
ENV PKG_CONFIG_LIBDIR=/opt/sysroot/usr/lib/pkgconfig:/opt/sysroot/usr/share/pkgconfig
ENV PKG_CONFIG_SYSROOT_DIR=/opt/sysroot
ENV CMAKE_SYSROOT_DIR=/opt/sysroot

WORKDIR /workspace
EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]

# test stage to validate cross-compilation
FROM cross-compile AS test-build

ARG TARGETARCH

COPY CMakeLists.txt /test/
COPY *.c /test/
COPY *.cmake /test/

ARG TARGET
RUN if echo "${TARGET}" | grep -qi "riscv\|cv180\|cv181"; then \
        if echo "${TARGET}" | grep -qi "musl"; then \
            TOOLCHAIN_FILE="sg200x_riscv64_musl.cmake"; \
        else \
            TOOLCHAIN_FILE="sg200x_riscv64_gnu.cmake"; \
        fi; \
        echo "compiling test for riscv64 (toolchain file: ${TOOLCHAIN_FILE})..."; \
        cmake -DCMAKE_TOOLCHAIN_FILE=/test/${TOOLCHAIN_FILE} -S /test -B /test/build; \
    elif echo "${TARGET}" | grep -qi "arm64\|aarch64"; then \
        TOOLCHAIN_FILE="sg200x_arm64_gnu.cmake"; \
        echo "compiling test for arm64 (toolchain file: ${TOOLCHAIN_FILE})..."; \
        cmake -DCMAKE_TOOLCHAIN_FILE=/test/${TOOLCHAIN_FILE} -S /test -B /test/build; \
    fi

RUN cmake --build /test/build

FROM --platform=linux/amd64 alpine:3.22.2 AS test

# install qemu
RUN apk add --no-cache qemu-aarch64 qemu-riscv64

ARG TARGETARCH
ARG TARGET

WORKDIR /workspace

# copy the sysroot from the builder stage
COPY --from=builder /build/sdk/buildroot/output/${TARGET}/staging /opt/sysroot

# copy the binary from the test-build stage
COPY --from=test-build /test/build/test_exec /workspace/test_exec

# run ldd using qemu to check linking
RUN if echo "${TARGET}" | grep -qi "riscv\|cv180\|cv181"; then \
        echo "checking linking using qemu riscv64"; \
        QEMU_LD_PATH=$(find /opt/sysroot/lib* /opt/sysroot/usr/lib* -name 'ld-musl-riscv64.so.1' 2>/dev/null | head -n 1); \
        if [ -z "$QEMU_LD_PATH" ]; then echo "target linker not found in sysroot!"; exit 1; fi; \
        qemu-riscv64 -L /opt/sysroot "$QEMU_LD_PATH" --list /workspace/test_exec; \
    elif echo "${TARGET}" | grep -qi "arm64\|aarch64"; then \
        echo "checking linking using qemu arm64"; \
        QEMU_LD_PATH=$(find /opt/sysroot/lib* /opt/sysroot/usr/lib* -name 'ld-linux-aarch64.so.1' 2>/dev/null | head -n 1); \
        if [ -z "$QEMU_LD_PATH" ]; then echo "target linker not found in sysroot!"; exit 1; fi; \
        qemu-aarch64 -L /opt/sysroot "$QEMU_LD_PATH" --list /workspace/test_exec; \
    fi

# run test with qemu
RUN if echo "${TARGET}" | grep -qi "riscv\|cv180\|cv181"; then \
        echo "running test with qemu riscv64 (generic rv64 CPU)..." && \
        qemu-riscv64 -cpu rv64 -L /opt/sysroot /workspace/test_exec; \
    elif echo "${TARGET}" | grep -qi "arm64\|aarch64"; then \
        echo "running test with qemu arm64 (cortex-a53 CPU)..." && \
        qemu-aarch64 -cpu cortex-a53 -L /opt/sysroot /workspace/test_exec; \
    fi

# set cross-compile back as default stage
FROM cross-compile
