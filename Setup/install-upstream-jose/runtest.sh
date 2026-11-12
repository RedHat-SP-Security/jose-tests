#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k

. /usr/share/beakerlib/beakerlib.sh || exit 1

JOSE_UPSTREAM_URL="https://github.com/latchset/jose.git"
JOSE_UPSTREAM_REF="${JOSE_UPSTREAM_REF:-master}"
JOSE_EXPECTED_COMMIT="${JOSE_EXPECTED_COMMIT:-}"
JOSE_BUILD_ROOT="/var/tmp/jose-upstream"
JOSE_SOURCE_DIR="${JOSE_BUILD_ROOT}/source"
JOSE_BUILD_DIR="${JOSE_BUILD_ROOT}/build"
JOSE_INSTALLED_COMMIT_FILE="${JOSE_BUILD_ROOT}/installed-commit"
JOSE_LIBRARY_DIR="/usr/local/lib"

rlJournalStart
    rlPhaseStartSetup
        if [[ ! "${JOSE_UPSTREAM_REF}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || \
           ! git check-ref-format --allow-onelevel "${JOSE_UPSTREAM_REF}"; then
            rlDie "Invalid JOSE_UPSTREAM_REF: ${JOSE_UPSTREAM_REF}"
        fi

        if [[ -n "${JOSE_EXPECTED_COMMIT}" && ! "${JOSE_EXPECTED_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
            rlDie "JOSE_EXPECTED_COMMIT must be a 40-character lowercase commit hash"
        fi

        rlRun "mkdir -p '${JOSE_BUILD_ROOT}'"

        rlRun "rm -rf '${JOSE_SOURCE_DIR}' '${JOSE_BUILD_DIR}'"
        rlRun "mkdir -p '${JOSE_SOURCE_DIR}'"
        rlRun "git -C '${JOSE_SOURCE_DIR}' init" 0 "Initialize upstream jose checkout"
        rlRun "git -C '${JOSE_SOURCE_DIR}' remote add origin '${JOSE_UPSTREAM_URL}'" 0 "Configure upstream jose remote"
        rlRun "git -C '${JOSE_SOURCE_DIR}' fetch --depth=1 origin '${JOSE_UPSTREAM_REF}'" 0 "Fetch selected upstream jose revision"
        rlRun "git -C '${JOSE_SOURCE_DIR}' checkout --detach FETCH_HEAD" 0 "Check out selected jose revision"
        ACTUAL_COMMIT="$(git -C "${JOSE_SOURCE_DIR}" rev-parse HEAD)"
        rlLogInfo "Building jose commit ${ACTUAL_COMMIT} from ${JOSE_UPSTREAM_REF}"
        if [[ -n "${JOSE_EXPECTED_COMMIT}" && "${ACTUAL_COMMIT}" != "${JOSE_EXPECTED_COMMIT}" ]]; then
            rlDie "Expected jose commit ${JOSE_EXPECTED_COMMIT}, got ${ACTUAL_COMMIT}"
        fi

        INSTALLED_COMMIT=""
        if [[ -r "${JOSE_INSTALLED_COMMIT_FILE}" ]]; then
            read -r INSTALLED_COMMIT < "${JOSE_INSTALLED_COMMIT_FILE}"
        fi

        if [[ "${INSTALLED_COMMIT}" == "${ACTUAL_COMMIT}" && \
              -x /usr/local/bin/jose && -e /usr/local/lib/libjose.so.0 ]]; then
            rlLogInfo "Selected jose commit is already installed; skipping build and install"
        else
            rlRun "meson setup '${JOSE_BUILD_DIR}' '${JOSE_SOURCE_DIR}' --prefix=/usr/local --libdir=lib -Ddocs=disabled" 0 "Configure upstream jose"
            rlRun "meson compile -C '${JOSE_BUILD_DIR}'" 0 "Build jose"
            rlRun "meson install -C '${JOSE_BUILD_DIR}'" 0 "Install the upstream jose build" || rlDie "Build succeeded but install failed; check the build logs for details"
        fi

        rlRun "printf '%s\\n' '${JOSE_LIBRARY_DIR}' > /etc/ld.so.conf.d/jose-upstream.conf" 0 "Register the jose library directory"
        rlRun "ldconfig"

        rlRun "test -x /usr/local/bin/jose" 0 "Verify the upstream jose CLI was installed"
        rlRun "/usr/local/bin/jose jwk gen -i '{\"alg\":\"HS256\"}' > /dev/null" 0 "Verify the jose CLI can load its shared library"
        rlRun "printf '%s\\n' '${ACTUAL_COMMIT}' > '${JOSE_INSTALLED_COMMIT_FILE}'" 0 "Record the installed upstream commit"
    rlPhaseEnd
rlJournalEnd
