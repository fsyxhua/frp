#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./build-push.sh [tag]
#   ./build-push.sh [tag] --push-latest
#
# Environment overrides:
#   REGISTRY=reg.example.com/ns ./build-push.sh v0.60.0
#   REGISTRY_MIRROR=https://registry.linkease.net:5443 ./build-push.sh
#   BUILDER=multi-builder ./build-push.sh
#   DEFAULT_PLATFORMS=linux/amd64,linux/arm64 ./build-push.sh
#   AMD64_LEVELS="v2 v3 v4" ./build-push.sh
#   PUSH_LATEST=true ./build-push.sh v0.60.0
#   BUILD_WEB=false ./build-push.sh v0.60.0
#   RECREATE_BUILDER=true ./build-push.sh v0.60.0

REGISTRY="${REGISTRY:-reg.lianli.com.cn/fsyx}"
TAG="${TAG:-latest}"
BUILDER="${BUILDER:-multi-builder}"
DEFAULT_PLATFORMS="${DEFAULT_PLATFORMS:-linux/amd64,linux/arm64}"
AMD64_LEVELS="${AMD64_LEVELS:-v2 v3 v4}"
PUSH_LATEST="${PUSH_LATEST:-false}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-https://registry.linkease.net:5443}"
BUILD_WEB="${BUILD_WEB:-true}"
RECREATE_BUILDER="${RECREATE_BUILDER:-false}"

TMP_CONFIG_FILE=""
cleanup() {
    if [[ -n "${TMP_CONFIG_FILE}" && -f "${TMP_CONFIG_FILE}" ]]; then
        rm -f "${TMP_CONFIG_FILE}"
    fi
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage:
  $0 [tag] [options]

Options:
  -l, --push-latest         Also push latest tags while building a version tag.
  -m, --mirror <url>        Docker registry mirror URL (default: https://registry.linkease.net:5443).
      --no-mirror           Disable registry mirror for buildx.
      --skip-web-build      Skip pre-building frontend web static assets.
      --recreate-builder    Force recreate the buildx builder instance to apply new config/mirror.
  -h, --help                Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--push-latest)
            PUSH_LATEST=true
            shift
            ;;
        -m|--mirror)
            REGISTRY_MIRROR="$2"
            shift 2
            ;;
        --no-mirror)
            REGISTRY_MIRROR=""
            shift
            ;;
        --skip-web-build)
            BUILD_WEB=false
            shift
            ;;
        --recreate-builder)
            RECREATE_BUILDER=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            TAG="$1"
            shift
            ;;
    esac
done

build_web() {
    if [[ "${BUILD_WEB}" != "true" ]]; then
        echo "Skipping web build (--skip-web-build / BUILD_WEB=false)."
        return 0
    fi

    echo "=================================================="
    echo "Building web frontend assets (once for all architectures)"
    echo "=================================================="

    if command -v npm >/dev/null 2>&1; then
        echo "Using local npm to build web assets..."
        (
            cd web
            npm install
            npm run build --workspace frps
            npm run build --workspace frpc
        )
    else
        echo "Local npm not found. Building web assets using node:22 container..."
        local workspace_dir
        workspace_dir="$(pwd)"
        docker run --rm -v "${workspace_dir}:/app" -w /app/web node:22 sh -c "npm install && npm run build --workspace frps && npm run build --workspace frpc"
    fi

    echo "Web frontend assets built successfully."
    echo "--------------------------------------------------"
}

ensure_builder() {
    local buildkit_args=()

    if [[ -n "${REGISTRY_MIRROR}" ]]; then
        local mirror_host="${REGISTRY_MIRROR#*://}"
        mirror_host="${mirror_host%/}"

        TMP_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/buildkitd.XXXXXX.toml" 2>/dev/null || echo "buildkitd_tmp.toml")"
        cat <<EOF > "${TMP_CONFIG_FILE}"
[registry."docker.io"]
  mirrors = ["${mirror_host}"]

[registry."${mirror_host}"]
  http = false
  insecure = true
EOF
        buildkit_args+=("--buildkitd-config" "${TMP_CONFIG_FILE}")
        echo "Configured Docker mirror for buildx: ${mirror_host}"
    fi

    if docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
        if [[ "${RECREATE_BUILDER}" == "true" ]]; then
            echo "Recreating existing buildx builder: ${BUILDER}"
            docker buildx rm "${BUILDER}" >/dev/null 2>&1 || true
            docker buildx create --use --name "${BUILDER}" --driver docker-container "${buildkit_args[@]}" >/dev/null
        else
            echo "Using existing buildx builder: ${BUILDER}"
            echo "(Hint: Pass --recreate-builder if you updated registry mirror settings)"
            docker buildx use "${BUILDER}" >/dev/null
        fi
    else
        echo "Creating buildx builder: ${BUILDER}"
        docker buildx create --use --name "${BUILDER}" --driver docker-container "${buildkit_args[@]}" >/dev/null
    fi

    docker buildx inspect "${BUILDER}" --bootstrap >/dev/null
}

build_and_push() {
    local dockerfile="$1"
    local platform="$2"
    shift 2
    local images=("$@")
    local tag_args=()

    for image in "${images[@]}"; do
        tag_args+=("-t" "${image}")
    done

    echo "Building ${images[*]} for ${platform}"
    docker buildx build \
        -f "${dockerfile}" \
        --platform "${platform}" \
        --build-arg "WEB_BUILDER=external" \
        "${tag_args[@]}" \
        --push \
        .
    echo "Pushed ${images[*]}"
    echo "--------------------------------------------------"
}

main() {
    echo "=================================================="
    echo "Build and push frp Docker images"
    echo "Registry: ${REGISTRY}"
    echo "Tag: ${TAG}"
    echo "Push latest: ${PUSH_LATEST}"
    echo "Builder: ${BUILDER}"
    echo "Default platforms: ${DEFAULT_PLATFORMS}"
    echo "AMD64 levels: ${AMD64_LEVELS}"
    echo "Registry mirror: ${REGISTRY_MIRROR:-disabled}"
    echo "Build web once: ${BUILD_WEB}"
    echo "=================================================="

    build_web
    ensure_builder

    for app in frps frpc; do
        local dockerfile="dockerfiles/Dockerfile-for-${app}"

        if [[ ! -f "${dockerfile}" ]]; then
            echo "Missing Dockerfile: ${dockerfile}" >&2
            exit 1
        fi

        echo "================= ${app} ================="
        local default_images=("${REGISTRY}/${app}:${TAG}")
        if [[ "${PUSH_LATEST}" == "true" && "${TAG}" != "latest" ]]; then
            default_images+=("${REGISTRY}/${app}:latest")
        fi
        build_and_push "${dockerfile}" "${DEFAULT_PLATFORMS}" "${default_images[@]}"

        for level in ${AMD64_LEVELS}; do
            local level_images=("${REGISTRY}/${app}:${TAG}-${level}")
            if [[ "${PUSH_LATEST}" == "true" && "${TAG}" != "latest" ]]; then
                level_images+=("${REGISTRY}/${app}:latest-${level}")
            fi
            build_and_push "${dockerfile}" "linux/amd64/${level}" "${level_images[@]}"
        done
    done

    echo "All images have been built and pushed."
}

main "$@"
