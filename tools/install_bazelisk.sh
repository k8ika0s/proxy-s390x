#!/usr/bin/env bash

if ! command -v sudo >/dev/null; then
    SUDO=
else
    SUDO=sudo
fi

# renovate: datasource=github-releases depName=bazelbuild/bazelisk
BAZELISK_VERSION=v1.28.1
BAZEL_VERSION="${BAZEL_VERSION:-$(cat .bazelversion 2>/dev/null || echo 7.7.1)}"

installed_bazelisk_version=""

if [[ $(command -v bazel) ]]; then
    installed_bazelisk_version=$(bazel version | grep 'Bazelisk' | cut -d ' ' -f 3)
fi

echo "Checking if Bazelisk ${BAZELISK_VERSION} needs to be installed..."
if [[ "${installed_bazelisk_version}" = "${BAZELISK_VERSION}" || "${installed_bazelisk_version}" = "development" ]]; then
    echo "Bazelisk ${BAZELISK_VERSION} (or development) already installed, skipping."
else
    BAZEL=$(command -v bazel)
    if [ -n "${BAZEL}" ] ; then
        echo "Removing old Bazel version at ${BAZEL}"
        ${SUDO} rm "${BAZEL}"
    else
        BAZEL=/usr/local/bin/bazel
    fi
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH="arm64"
    elif [ "$ARCH" = "s390x" ]; then
        if command -v apt-get >/dev/null; then
            echo "Bazelisk binary is unavailable on s390x; bootstrapping Bazel ${BAZEL_VERSION} from source."
            ${SUDO} apt-get update
            ${SUDO} apt-get install -y --no-install-recommends bazel-bootstrap default-jdk-headless python3 unzip zip
            TMPDIR=$(mktemp -d)
            trap 'rm -rf "${TMPDIR}"' EXIT
            curl -sfL "https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/bazel-${BAZEL_VERSION}-dist.zip" -o "${TMPDIR}/bazel-dist.zip"
            unzip -q "${TMPDIR}/bazel-dist.zip" -d "${TMPDIR}/bazel-src"
            (
                cd "${TMPDIR}/bazel-src"
                if ! grep -q 'module_name = "apple_support"' MODULE.bazel; then
                    printf '\nsingle_version_override(\n    module_name = "apple_support",\n    version = "1.8.1",\n)\n' >> MODULE.bazel
                fi
                if ! grep -q 'name = "function_transition_allowlist"' tools/allowlists/function_transition_allowlist/BUILD; then
                    cat >> tools/allowlists/function_transition_allowlist/BUILD <<'EOF'

package_group(
    name = "function_transition_allowlist",
    packages = ["public"],
)
EOF
                fi
                if ! find . -path '*/com/google/protobuf/UnusedPrivateParameter.java' -print -quit | grep -q .; then
                    pb_dir=$(find . -type d -path '*/com/google/protobuf' | head -n 1 || true)
                    if [ -n "${pb_dir}" ]; then
                        cat > "${pb_dir}/UnusedPrivateParameter.java" <<'EOF'
package com.google.protobuf;

final class UnusedPrivateParameter {
  static final UnusedPrivateParameter INSTANCE = new UnusedPrivateParameter();
  private UnusedPrivateParameter() {}
}
EOF
                    fi
                fi
                EXTRA_BAZEL_ARGS="--lockfile_mode=refresh --java_runtime_version=local_jdk --tool_java_runtime_version=local_jdk --java_language_version=21 --tool_java_language_version=21" ./compile.sh
            )
            ${SUDO} install -m 0755 "${TMPDIR}/bazel-src/output/bazel" "${BAZEL}"
            ${SUDO} ln -sf "${BAZEL}" "/usr/local/bin/bazel-${BAZEL_VERSION}"
            exit 0
        fi
        echo "Bazelisk binary is unavailable on s390x and no apt-based fallback is configured." >&2
        exit 1
    fi
    echo "Downloading bazelisk-${OS}-${ARCH} to ${BAZEL}"
    ${SUDO} curl -sfL "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-${OS}-${ARCH}" -o "${BAZEL}"
    ${SUDO} chmod +x "${BAZEL}"
fi
