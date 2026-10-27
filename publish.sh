#!/usr/bin/env bash
# Host-side launcher for building and publishing protection-domain-mapper.
# Debian packaging runs in an Ubuntu container, so this also works on Gentoo.
set -euo pipefail

PPA_REMOTE="${PPA_REMOTE:-ppa:lightofmysoul/gxr}"
PPA_PACKAGES_URL="${PPA_PACKAGES_URL:-https://launchpad.net/~lightofmysoul/+archive/ubuntu/gxr/+packages}"
SERIES="${SERIES:-resolute stonking}"
GPG_KEY_FINGERPRINT="${GPG_KEY_FINGERPRINT:-C21DA3A97F220CA130545721B179022596F6BFCD}"
IMAGE_TAG="${IMAGE_TAG:-protection-domain-mapper-ppa-builder}"

declare -A UBUNTU_VERSIONS=([resolute]=26.04 [stonking]=26.10)

NO_UPLOAD=0
UNSIGNED=0
ALLOW_DIRTY=0
SELECTED_SERIES=()

say() {
    printf '\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build one source-only protection-domain-mapper package per Ubuntu series (${SERIES})
in an Ubuntu Podman container. By default they are signed and uploaded to
${PPA_REMOTE}.

Every series reuses the newest debian/changelog entry with its own ~YY.MM.N
version suffix.

  --series CODENAME Publish only to this Ubuntu series; repeatable.
  --no-upload       Build, sign, and validate, but do not run dput.
  --unsigned        Build and validate without a key; implies --no-upload.
  --allow-dirty     Permit local changes (validation only).
  --key FINGERPRINT Override the OpenPGP signing-key fingerprint.
  --ppa TARGET      Override the dput target (default: ${PPA_REMOTE}).
  -h, --help        Show this help.

Normal uploads deliberately refuse a dirty tree. Generated source artifacts
are retained beneath build-packages/ (gitignored). An unsigned artifact set can
be transferred to a machine with the upload key and signed with debsign.

Host requirements: podman, git, and gpg (unless --unsigned is used).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --series)
            [ "$#" -ge 2 ] || die "--series needs an Ubuntu codename"
            SELECTED_SERIES+=("$2")
            shift 2
            ;;
        --no-upload)
            NO_UPLOAD=1
            shift
            ;;
        --unsigned)
            UNSIGNED=1
            NO_UPLOAD=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --key)
            [ "$#" -ge 2 ] || die "--key needs a fingerprint"
            GPG_KEY_FINGERPRINT="$2"
            shift 2
            ;;
        --ppa)
            [ "$#" -ge 2 ] || die "--ppa needs a dput target"
            PPA_REMOTE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac
done

if [ "${ALLOW_DIRTY}" -eq 1 ] && [ "${NO_UPLOAD}" -eq 0 ]; then
    die "--allow-dirty is restricted to --no-upload/--unsigned validation"
fi

if [ "${#SELECTED_SERIES[@]}" -eq 0 ]; then
    read -r -a SELECTED_SERIES <<<"${SERIES}"
fi
[ "${#SELECTED_SERIES[@]}" -gt 0 ] || die "no Ubuntu series selected"
for series in "${SELECTED_SERIES[@]}"; do
    [ -n "${UBUNTU_VERSIONS[${series}]+x}" ] || die "unknown Ubuntu series: ${series}"
done

need_command() {
    command -v "$1" >/dev/null 2>&1 || MISSING_COMMANDS+=("$1")
}

MISSING_COMMANDS=()
for command_name in git podman sed date mktemp cp find sha256sum; do
    need_command "${command_name}"
done
if [ "${UNSIGNED}" -eq 0 ]; then
    need_command gpg
fi
if [ "${#MISSING_COMMANDS[@]}" -ne 0 ]; then
    printf 'error: missing required host commands:' >&2
    printf ' %s' "${MISSING_COMMANDS[@]}" >&2
    printf '\nOn Gentoo, install Podman with:\n' >&2
    printf '  sudo emerge --ask app-containers/podman\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)" \
    || die "publish.sh must be run from the Git checkout"
PACKAGE_DIR="${REPO}"
[ "${SCRIPT_DIR}" = "${PACKAGE_DIR}" ] \
    || die "publish.sh must be at the repository root"

PACKAGE_STATUS="$(git -C "${REPO}" status --porcelain --untracked-files=all)"
if [ -n "${PACKAGE_STATUS}" ]; then
    if [ "${ALLOW_DIRTY}" -eq 0 ]; then
        printf '%s\n' "${PACKAGE_STATUS}" >&2
        die "the repository has uncommitted files; commit them or use --allow-dirty for validation"
    fi
    warn "building from a dirty tree"
fi

CHANGELOG_HEADER="$(sed -n '1p' "${PACKAGE_DIR}/debian/changelog")"
CHANGELOG_PATTERN='^([^[:space:]]+)[[:space:]]+\(([^)]*)\)[[:space:]]+([^;[:space:]]+);'
if [[ "${CHANGELOG_HEADER}" =~ ${CHANGELOG_PATTERN} ]]; then
    SOURCE="${BASH_REMATCH[1]}"
    VERSION="${BASH_REMATCH[2]}"
    DISTRIBUTION="${BASH_REMATCH[3]}"
else
    die "cannot parse the first line of debian/changelog"
fi
[ "${SOURCE}" = "protection-domain-mapper" ] \
    || die "unexpected source package: ${SOURCE}"
[ -n "${UBUNTU_VERSIONS[${DISTRIBUTION}]+x}" ] \
    || die "debian/changelog targets unknown series ${DISTRIBUTION}"
[ "$(<"${PACKAGE_DIR}/debian/source/format")" = "3.0 (native)" ] \
    || die "expected Debian source format 3.0 (native)"

SERIES_SUFFIX_PATTERN='^(.+)~([0-9]+\.[0-9]+)\.([0-9]+)$'
[[ "${VERSION}" =~ ${SERIES_SUFFIX_PATTERN} ]] \
    && [ "${BASH_REMATCH[2]}" = "${UBUNTU_VERSIONS[${DISTRIBUTION}]}" ] \
    || die "version ${VERSION} must end in ~${UBUNTU_VERSIONS[${DISTRIBUTION}]}.N for ${DISTRIBUTION}"
BASE_VERSION="${BASH_REMATCH[1]}"
SERIES_REVISION="${BASH_REMATCH[3]}"

TARGETS=()
for series in "${SELECTED_SERIES[@]}"; do
    TARGETS+=("${series}=${BASE_VERSION}~${UBUNTU_VERSIONS[${series}]}.${SERIES_REVISION}")
done

if [ "${UNSIGNED}" -eq 0 ]; then
    HOST_GNUPG_HOME="${GNUPGHOME:-${HOME}/.gnupg}"
    [ -d "${HOST_GNUPG_HOME}" ] \
        || die "GnuPG home does not exist: ${HOST_GNUPG_HOME}"
    SECRET_KEY_LIST="$(
        gpg --homedir "${HOST_GNUPG_HOME}" --batch --with-colons \
            --list-secret-keys "${GPG_KEY_FINGERPRINT}" 2>/dev/null \
            || true
    )"
    if ! grep -q '^sec:' <<<"${SECRET_KEY_LIST}"; then
        die "secret GPG key ${GPG_KEY_FINGERPRINT} is not available"
    fi
    unset SECRET_KEY_LIST
else
    warn "building an unsigned source package; upload is disabled"
fi

CONTAINERFILE="${PACKAGE_DIR}/Containerfile"
INSIDE_SCRIPT="${PACKAGE_DIR}/inside-container.sh"
[ -f "${CONTAINERFILE}" ] || die "missing ${CONTAINERFILE}"
[ -f "${INSIDE_SCRIPT}" ] || die "missing ${INSIDE_SCRIPT}"

CONTAINERFILE_SHA256="$(sha256sum -- "${CONTAINERFILE}")"
CONTAINERFILE_SHA256="${CONTAINERFILE_SHA256%% *}"
IMAGE_CONTAINERFILE_SHA256=""
if podman image exists "${IMAGE_TAG}"; then
    IMAGE_CONTAINERFILE_SHA256="$(
        podman image inspect \
            --format '{{ index .Labels "org.protection-domain-mapper.containerfile-sha256" }}' \
            "${IMAGE_TAG}" 2>/dev/null || true
    )"
fi
if [ "${IMAGE_CONTAINERFILE_SHA256}" != "${CONTAINERFILE_SHA256}" ]; then
    say "Building Ubuntu packaging image ${IMAGE_TAG}"
    podman build \
        --label "org.protection-domain-mapper.containerfile-sha256=${CONTAINERFILE_SHA256}" \
        --tag "${IMAGE_TAG}" \
        --file "${CONTAINERFILE}" \
        "${PACKAGE_DIR}"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_VERSION="${BASE_VERSION//:/_}"
ARTIFACT_DIR="${PACKAGE_DIR}/build-packages/protection-domain-mapper-${SAFE_VERSION}-${RUN_ID}"
[ ! -e "${ARTIFACT_DIR}" ] \
    || die "artifact directory already exists: ${ARTIFACT_DIR}"
install -d -m 0755 "${ARTIFACT_DIR}"

TEMP_GPG=""
cleanup() {
    if [ -n "${TEMP_GPG}" ] && [ -d "${TEMP_GPG}" ] && [ ! -L "${TEMP_GPG}" ]; then
        chmod -R u+w "${TEMP_GPG}" 2>/dev/null || true
        find "${TEMP_GPG}" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

CONTAINER_ARGS=(
    run --rm
    --volume "${REPO}:/repo:ro"
    --volume "${ARTIFACT_DIR}:/out"
    --env "TARGETS=${TARGETS[*]}"
    --env "PPA_REMOTE=${PPA_REMOTE}"
    --env "GPG_KEY=${GPG_KEY_FINGERPRINT}"
    --env "UNSIGNED=${UNSIGNED}"
    --env "NO_UPLOAD=${NO_UPLOAD}"
)

if [ "${UNSIGNED}" -eq 0 ]; then
    TEMP_GPG="$(mktemp -d "${TMPDIR:-/tmp}/protection-domain-mapper-gnupg.XXXXXX")"
    cp -a "${HOST_GNUPG_HOME}/." "${TEMP_GPG}/"
    find "${TEMP_GPG}" \
        \( -name 'S.*' -o -name '*.lock' -o -name '.#lk*' \) -delete
    chmod 700 "${TEMP_GPG}"
    CONTAINER_ARGS+=(--volume "${TEMP_GPG}:/root/.gnupg")
fi

say "Building ${SOURCE} ${BASE_VERSION} for ${SELECTED_SERIES[*]} in Ubuntu 26.04"
podman "${CONTAINER_ARGS[@]}" "${IMAGE_TAG}" \
    bash /repo/inside-container.sh

mapfile -t CHANGES_FILES < <(
    find "${ARTIFACT_DIR}" -maxdepth 1 -type f \
        -name "${SOURCE}_*_source.changes" -print
)
[ "${#CHANGES_FILES[@]}" -eq "${#TARGETS[@]}" ] \
    || die "expected ${#TARGETS[@]} source .changes files, found ${#CHANGES_FILES[@]}"

say "Artifacts: ${ARTIFACT_DIR}"
(
    cd "${ARTIFACT_DIR}"
    sha256sum -- *
)

if [ "${NO_UPLOAD}" -eq 1 ]; then
    say "Upload skipped"
else
    say "Upload complete; watch ${PPA_PACKAGES_URL}"
fi
