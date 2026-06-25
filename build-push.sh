#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./build-push.sh [tag]
#   ./build-push.sh [tag] --push-latest
#
# Environment overrides:
#   REGISTRY=reg.example.com/ns ./build-push.sh v0.60.0
#   BUILDER=multi-builder ./build-push.sh
#   DEFAULT_PLATFORMS=linux/amd64,linux/arm64 ./build-push.sh
#   AMD64_LEVELS="v2 v3 v4" ./build-push.sh
#   PUSH_LATEST=true ./build-push.sh v0.60.0

REGISTRY="${REGISTRY:-reg.lianli.com.cn/fsyx}"
TAG="${TAG:-latest}"
BUILDER="${BUILDER:-multi-builder}"
DEFAULT_PLATFORMS="${DEFAULT_PLATFORMS:-linux/amd64,linux/arm64}"
AMD64_LEVELS="${AMD64_LEVELS:-v2 v3 v4}"
PUSH_LATEST="${PUSH_LATEST:-false}"

usage() {
    cat <<EOF
Usage:
  $0 [tag] [--push-latest]

Options:
  -l, --push-latest  Also push latest tags while building a version tag.
  -h, --help         Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--push-latest)
            PUSH_LATEST=true
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

ensure_builder() {
    if docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
        echo "Using existing buildx builder: ${BUILDER}"
        docker buildx use "${BUILDER}" >/dev/null
    else
        echo "Creating buildx builder: ${BUILDER}"
        docker buildx create --use --name "${BUILDER}" --driver docker-container >/dev/null
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
    echo "=================================================="

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
