FROM --platform=$BUILDPLATFORM debian:stable-slim AS builder

ARG MINISIG=0.12
ARG ZIG_MINISIG=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG V8=14.0.365.4
ARG ZIG_V8=v0.4.5
ARG BUILDPLATFORM
ARG TARGETPLATFORM
ARG TARGETARCH

RUN apt-get update -yq && \
    apt-get install -yq --no-install-recommends xz-utils ca-certificates \
        pkg-config libglib2.0-dev \
        clang make curl git && \
    rm -rf /var/lib/apt/lists/*

# Get Rust with cross-compilation target
RUN curl --fail -sSL --retry 3 --retry-delay 2 -o /tmp/rustup.sh https://sh.rustup.rs && \
    sh /tmp/rustup.sh --profile minimal -y && \
    rm /tmp/rustup.sh
ENV PATH="/root/.cargo/bin:${PATH}"
RUN case $TARGETARCH in \
      "arm64") rustup target add aarch64-unknown-linux-gnu ;; \
      *) rustup target add x86_64-unknown-linux-gnu ;; \
    esac

# install minisig (use build platform arch since we run it during build)
RUN case $BUILDPLATFORM in \
      "linux/arm64") BUILD_ARCH="aarch64" ;; \
      *) BUILD_ARCH="x86_64" ;; \
    esac && \
    curl --fail -L --retry 3 --retry-delay 2 -O https://github.com/jedisct1/minisign/releases/download/${MINISIG}/minisign-${MINISIG}-linux.tar.gz && \
    tar xzf minisign-${MINISIG}-linux.tar.gz -C /

# clone lightpanda
RUN git clone --depth 1 https://github.com/lightpanda-io/browser.git
WORKDIR /browser

# install zig (use build platform arch since the compiler runs on the build machine)
RUN ZIG=$(grep '\.minimum_zig_version = "' "build.zig.zon" | cut -d'"' -f2) && \
    case $BUILDPLATFORM in \
      "linux/arm64") BUILD_ARCH="aarch64" ;; \
      *) BUILD_ARCH="x86_64" ;; \
    esac && \
    curl --fail -L --retry 3 --retry-delay 2 -O https://ziglang.org/download/${ZIG}/zig-${BUILD_ARCH}-linux-${ZIG}.tar.xz && \
    curl --fail -L --retry 3 --retry-delay 2 -O https://ziglang.org/download/${ZIG}/zig-${BUILD_ARCH}-linux-${ZIG}.tar.xz.minisig && \
    /minisign-linux/${BUILD_ARCH}/minisign -Vm zig-${BUILD_ARCH}-linux-${ZIG}.tar.xz -P ${ZIG_MINISIG} && \
    tar xf zig-${BUILD_ARCH}-linux-${ZIG}.tar.xz && \
    mv zig-${BUILD_ARCH}-linux-${ZIG} /usr/local/lib && \
    ln -s /usr/local/lib/zig-${BUILD_ARCH}-linux-${ZIG}/zig /usr/local/bin/zig

# download v8 (use target platform arch since this is linked into the output binary)
RUN case $TARGETARCH in \
    "arm64") TARGET_ARCH="aarch64" ;; \
    *) TARGET_ARCH="x86_64" ;; \
    esac && \
    curl --fail -L --retry 3 --retry-delay 2 -o libc_v8.a https://github.com/lightpanda-io/zig-v8-fork/releases/download/${ZIG_V8}/libc_v8_${V8}_linux_${TARGET_ARCH}.a && \
    mkdir -p v8/ && \
    mv libc_v8.a v8/libc_v8.a

# resolve zig target triple from TARGETARCH
RUN case $TARGETARCH in \
      "arm64") echo "aarch64-linux-gnu" > /tmp/zig_target ;; \
      *) echo "x86_64-linux-gnu" > /tmp/zig_target ;; \
    esac

# build v8 snapshot
RUN ZIG_TARGET=$(cat /tmp/zig_target) && \
    zig build -Doptimize=ReleaseFast \
    -Dtarget=${ZIG_TARGET} \
    -Dprebuilt_v8_path=v8/libc_v8.a \
    snapshot_creator -- src/snapshot.bin

# build release
RUN ZIG_TARGET=$(cat /tmp/zig_target) && \
    zig build -Doptimize=ReleaseFast \
    -Dtarget=${ZIG_TARGET} \
    -Dsnapshot_path=../../snapshot.bin \
    -Dprebuilt_v8_path=v8/libc_v8.a

FROM --platform=$TARGETPLATFORM debian:stable-slim AS tini

RUN apt-get update -yq && \
    apt-get install -yq --no-install-recommends tini && \
    rm -rf /var/lib/apt/lists/*

FROM --platform=$TARGETPLATFORM debian:stable-slim

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

COPY --from=builder /browser/zig-out/bin/zenpanda /bin/zenpanda
COPY --from=tini /usr/bin/tini /usr/bin/tini

EXPOSE 9222/tcp

# Lightpanda install only some signal handlers, and PID 1 doesn't have a default SIGTERM signal handler.
# Using "tini" as PID1 ensures that signals work as expected, so e.g. "docker stop" will not hang.
# (See https://github.com/krallin/tini#why-tini).
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/zenpanda", "serve", "--host", "0.0.0.0", "--port", "9222", "--log-level", "info"]
