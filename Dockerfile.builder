#
# Builder dependencies. This takes a long time to build from scratch!
# Also note that if build fails due to C++ internal error or similar,
# it is possible that the image build needs more RAM than available by
# default on non-Linux docker installs.
FROM docker.io/library/ubuntu:24.04@sha256:cd1dba651b3080c3686ecf4e3c4220f026b521fb76978881737d24f200828b2b AS base
LABEL maintainer="maintainer@cilium.io"
ARG TARGETARCH
# Setup TimeZone to prevent tzdata package asking for it interactively
ENV TZ=Etc/UTC

# renovate: datasource=golang-version depName=go
ENV GO_VERSION=1.24.13

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      # Multi-arch cross-compilation packages
      gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross binutils-aarch64-linux-gnu \
      gcc-x86-64-linux-gnu g++-x86-64-linux-gnu libc6-dev-amd64-cross binutils-x86-64-linux-gnu \
      gcc-s390x-linux-gnu g++-s390x-linux-gnu libc6-dev-s390x-cross binutils-s390x-linux-gnu \
      libc6-dev \
      # Envoy Build dependencies
      autoconf automake cmake coreutils curl git libtool make ninja-build patch patchelf libatomic1 \
	python3 python-is-python3 unzip virtualenv wget zip \
      # Cilium-envoy build dependencies
      software-properties-common && \
    wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc && \
    apt-add-repository -y "deb http://apt.llvm.org/noble/ llvm-toolchain-noble-18 main" && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      clang-18 clang-tidy-18 clang-tools-18 llvm-18-dev lldb-18 lld-18 clang-format-18 libc++-18-dev libc++abi-18-dev && \
    apt-get purge --auto-remove && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

#
# Install Bazelisk
#
# renovate: datasource=github-releases depName=bazelbuild/bazelisk
ENV BAZELISK_VERSION=v1.28.1
ARG BAZEL_VERSION

RUN ARCH=$TARGETARCH \
	&& if [ "${ARCH}" = "amd64" ] || [ "${ARCH}" = "arm64" ]; then \
		curl -sfL "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${ARCH}" -o /usr/bin/bazel; \
		chmod +x /usr/bin/bazel; \
			elif [ "${ARCH}" = "s390x" ]; then \
				# Bazelisk does not publish linux/s390x binaries. Build Bazel from the release dist zip.
				apt-get update \
				&& apt-get install -y --no-install-recommends bazel-bootstrap default-jdk-headless \
				&& TMPDIR="$(mktemp -d)" \
				&& BZ_VERSION="${BAZEL_VERSION}" \
				&& curl -sfL "https://github.com/bazelbuild/bazel/releases/download/${BZ_VERSION}/bazel-${BZ_VERSION}-dist.zip" -o "${TMPDIR}/bazel-dist.zip" \
				&& unzip -q "${TMPDIR}/bazel-dist.zip" -d "${TMPDIR}/bazel-src" \
		&& cd "${TMPDIR}/bazel-src" \
		&& if ! grep -q 'module_name = "apple_support"' MODULE.bazel; then printf '\nsingle_version_override(\n    module_name = "apple_support",\n    version = "1.8.1",\n)\n' >> MODULE.bazel; fi \
		&& if ! grep -q 'name = "function_transition_allowlist"' tools/allowlists/function_transition_allowlist/BUILD; then \
			printf '%s\n' \
				'' \
				'package_group(' \
				'    name = "function_transition_allowlist",' \
				'    packages = ["public"],' \
				')' >> tools/allowlists/function_transition_allowlist/BUILD; \
		fi \
		&& if ! find . -path '*/com/google/protobuf/UnusedPrivateParameter.java' -print -quit | grep -q .; then \
			PB_DIR="$(find . -type d -path '*/com/google/protobuf' | head -n 1)" \
			&& if [ -n "${PB_DIR}" ]; then \
				printf '%s\n' \
					'package com.google.protobuf;' \
					'' \
					'final class UnusedPrivateParameter {' \
					'  static final UnusedPrivateParameter INSTANCE = new UnusedPrivateParameter();' \
					'  private UnusedPrivateParameter() {}' \
					'}' > "${PB_DIR}/UnusedPrivateParameter.java"; \
			fi; \
				fi \
				&& EXTRA_BAZEL_ARGS="--lockfile_mode=refresh --java_runtime_version=local_jdk --tool_java_runtime_version=local_jdk --java_language_version=21 --tool_java_language_version=21" ./compile.sh \
				&& install -m 0755 output/bazel "/usr/bin/bazel-${BZ_VERSION}" \
				&& ln -sf "/usr/bin/bazel-${BZ_VERSION}" /usr/bin/bazel \
				&& rm -rf "${TMPDIR}" \
				&& apt-get clean \
				&& rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
			else \
			echo "Unsupported TARGETARCH for Bazel bootstrap: ${ARCH}" >&2; \
			exit 1; \
		fi

RUN if [ "${TARGETARCH}" = "s390x" ]; then \
		apt-get update \
		&& apt-get install -y --no-install-recommends linux-libc-dev-s390x-cross libssl-dev \
		&& curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
		&& . /root/.cargo/env \
		&& cargo --version \
		&& cargo install --locked --git https://github.com/bazelbuild/rules_rust.git --tag 0.56.0 cargo-bazel --root /usr/local \
		&& /usr/local/bin/cargo-bazel --version \
		&& rm -rf /root/.cargo/registry /root/.cargo/git \
		&& apt-get clean \
		&& rm -rf /var/lib/apt/lists/*; \
	fi
#
# Install Go
#
RUN curl -sfL https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz -o go.tar.gz \
	&& tar -C /usr/local -xzf go.tar.gz \
	&& rm go.tar.gz \
	&& export PATH=$PATH:/usr/local/go/bin \
	&& go version
#
# Switch to non-root user for builds
#
RUN groupadd -f -g 1337 cilium && useradd -m -d /cilium/proxy -g cilium -u 1337 cilium
USER 1337:1337
WORKDIR /cilium/proxy
