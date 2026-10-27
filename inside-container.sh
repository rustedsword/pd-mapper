#!/usr/bin/env bash
# Debian-specific half of publish.sh. This runs in the Ubuntu 26.04 image.
set -euo pipefail

say() {
    printf '\033[1;34m==>\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

for variable_name in TARGETS PPA_REMOTE GPG_KEY UNSIGNED NO_UPLOAD; do
    [ -n "${!variable_name+x}" ] \
        || die "missing environment variable: ${variable_name}"
done

PACKAGE_DIR=/repo
OUTPUT_DIR=/out
[ -d "${PACKAGE_DIR}/debian" ] \
    || die "package source is not mounted at ${PACKAGE_DIR}"
[ -d "${OUTPUT_DIR}" ] \
    || die "artifact output is not mounted at ${OUTPUT_DIR}"

SOURCE="$(dpkg-parsechangelog -l"${PACKAGE_DIR}/debian/changelog" -SSource)"
[ "${SOURCE}" = "protection-domain-mapper" ] \
    || die "unexpected source package: ${SOURCE}"
[ "$(<"${PACKAGE_DIR}/debian/source/format")" = "3.0 (native)" ] \
    || die "expected Debian source format 3.0 (native)"

WORK="$(mktemp -d /tmp/protection-domain-mapper-publish.XXXXXX)"
cleanup() {
    if [ -d "${WORK}" ] && [ ! -L "${WORK}" ]; then
        find "${WORK}" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

verify_sha256_manifest() {
    local manifest="$1"
    local checksum_lines
    checksum_lines="$(
        awk '
            /^Checksums-Sha256:/ { inside = 1; next }
            inside && /^[^ ]/ { exit }
            inside && NF == 3 { print $1 "  " $3 }
        ' "${manifest}"
    )"
    [ -n "${checksum_lines}" ] \
        || die "no SHA-256 manifest in ${manifest}"
    (
        cd "$(dirname -- "${manifest}")"
        printf '%s\n' "${checksum_lines}" \
            | sha256sum --check --strict --quiet -
    )
}

build_source_package() {
    local series="$1"
    local version="$2"
    local series_work="${WORK}/${series}"
    local source_dir="${series_work}/${SOURCE}-${version//:/_}"
    local changelog="${source_dir}/debian/changelog"
    install -d -m 0755 "${source_dir}"

    # Keep dpkg-buildpackage away from the read-only checkout. Generated build and
    # package artifacts are excluded from this native source archive.
    tar -C "${PACKAGE_DIR}" \
        --exclude-vcs \
        --exclude-vcs-ignores \
        --exclude='./build' \
        --exclude='./build-*' \
        --exclude='./obj-*' \
        --exclude='./debian/.debhelper' \
        --exclude='./debian/debhelper-build-stamp' \
        --exclude='./debian/files' \
        --exclude='./debian/*.substvars' \
        --exclude='./debian/protection-domain-mapper' \
        --exclude='./debian/tmp' \
        -cf - . | tar -C "${source_dir}" -xf -

    # Every series reuses the newest changelog entry under its own version.
    sed -i -E "1s/^(${SOURCE}) \([^)]*\) [^;]*;/\1 (${version}) ${series};/" \
        "${changelog}"
    [ "$(dpkg-parsechangelog -l"${changelog}" -SVersion)" = "${version}" ] \
        || die "cannot set the changelog version to ${version}"
    [ "$(dpkg-parsechangelog -l"${changelog}" -SDistribution)" = "${series}" ] \
        || die "cannot set the changelog distribution to ${series}"

    say "Creating ${series} source package ${version}"
    local build_args=(-S -sa -d)
    if [ "${UNSIGNED}" -eq 1 ]; then
        build_args+=(-us -uc)
    else
        build_args+=("-k${GPG_KEY}")
    fi
    (
        cd "${source_dir}"
        dpkg-buildpackage "${build_args[@]}"
    )

    local -a changes_files dsc_files
    mapfile -t changes_files < <(
        find "${series_work}" -maxdepth 1 -type f \
            -name "${SOURCE}_*_source.changes" -print
    )
    mapfile -t dsc_files < <(
        find "${series_work}" -maxdepth 1 -type f -name "${SOURCE}_*.dsc" -print
    )
    [ "${#changes_files[@]}" -eq 1 ] \
        || die "expected one source .changes file, found ${#changes_files[@]}"
    [ "${#dsc_files[@]}" -eq 1 ] \
        || die "expected one .dsc file, found ${#dsc_files[@]}"
    local changes_file="${changes_files[0]}"
    local dsc_file="${dsc_files[0]}"

    say "Verifying source-package checksums"
    verify_sha256_manifest "${dsc_file}"
    verify_sha256_manifest "${changes_file}"

    if [ "${UNSIGNED}" -eq 0 ]; then
        say "Verifying OpenPGP signatures"
        gpg --batch --verify "${dsc_file}"
        gpg --batch --verify "${changes_file}"
    elif grep -q '^-----BEGIN PGP SIGNATURE-----$' "${changes_file}"; then
        die "unsigned mode unexpectedly produced a signed .changes file"
    fi

    say "Checking that the source package extracts cleanly"
    dpkg-source --no-check -x "${dsc_file}" "${series_work}/extracted" >/dev/null

    say "Running lintian"
    lintian --display-info --pedantic "${changes_file}"

    # Preserve artifacts before upload so a transient dput failure can be retried
    # without rebuilding the source package.
    while IFS= read -r -d '' artifact; do
        cp -a -- "${artifact}" "${OUTPUT_DIR}/"
    done < <(find "${series_work}" -maxdepth 1 -type f -print0)

    UPLOADS+=("${changes_file}")
}

# Build and validate every series before the first upload.
UPLOADS=()
for target in ${TARGETS}; do
    build_source_package "${target%%=*}" "${target#*=}"
done

if [ "${NO_UPLOAD}" -eq 1 ]; then
    say "Upload disabled"
else
    for changes_file in "${UPLOADS[@]}"; do
        say "Uploading $(basename -- "${changes_file}") to ${PPA_REMOTE}"
        dput "${PPA_REMOTE}" "${changes_file}"
    done
fi
