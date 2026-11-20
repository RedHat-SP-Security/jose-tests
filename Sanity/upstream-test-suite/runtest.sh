#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /jose-tests/Sanity/upstream-test-suite
#   Description: Run the upstream test suite
#   Author: Sergio Correia <scorreia@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2024 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/bin/rhts-environment.sh || :
. /usr/share/beakerlib/beakerlib.sh || exit 1

TEST_DIR="${PWD}"
KEM_RESULTS_SCRIPT="${TEST_DIR}/check_kem_test_results.py"
JOSE_BUILD_DIR="${JOSE_BUILD_DIR:-}"
JOSE_REQUIRE_PQC_TESTS="${JOSE_REQUIRE_PQC_TESTS:-no}"

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm "jose" || rlDie
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        if [[ -n "${JOSE_BUILD_DIR}" ]]; then
            if [[ ! -d "${JOSE_BUILD_DIR}" ]]; then
                rlDie "Configured JOSE_BUILD_DIR does not exist: ${JOSE_BUILD_DIR}"
            fi
            BUILD_DIR="${JOSE_BUILD_DIR}"
            rlLogInfo "Using the pre-built jose tree at ${BUILD_DIR}"
        else
            if [ -d /root/rpmbuild ]; then
                rlRun "rlFileBackup --clean /root/rpmbuild" 0 "Backup rpmbuild directory"
                touch backup
            fi
        fi
    rlPhaseEnd

    rlPhaseStartTest
        if [[ -z "${JOSE_BUILD_DIR}" ]]; then
            rlRun "rlFetchSrcForInstalled jose"
            rlRun "JOSE_SRC_RPM=\$(rpm -q --queryformat 'jose-%{VERSION}-%{RELEASE}.src.rpm' jose)"
            rlRun "rpm -i ${JOSE_SRC_RPM}" 0 "Install jose source rpm"

            # Enabling buildroot/CRB so that we can have the build dependencies.
            for _r in $(dnf repolist --all \
                        | grep -iE 'crb|codeready|powertools' \
                        | grep -ivE 'debug|source|latest' \
                        | awk '{ print $1 }'); do
                dnf config-manager --set-enabled "${_r}" ||:
            done

            rlRun "dnf builddep -y jose*" 0 "Install jose build dependencies"

            # Preparing source and applying existing patches.
            rlRun "SPEC=/root/rpmbuild/SPECS/jose.spec"
            rlRun "SRCDIR=/root/rpmbuild/SOURCES"

            rlRun "rm -rf jose-*"
            rlRun "tar xf ${SRCDIR}/jose-*.tar.*" 0 "Unpacking jose source"
            rlRun "pushd jose-*"
                for p in $(grep ^Patch "${SPEC}" | awk '{ print$2 }'); do
                    _patch="${SRCDIR}/${p}"
                    [ -e "${_patch}" ] || rlFail "Patch ${p} does not exist"
                    rlRun "patch -p1 < \"${_patch}\"" 0 "Applying patch ${p}" || rlFail "Failed to apply patch ${p}"
                done

               # Newer versions of jose (from v11) use meson instead of
                # autotools.
                MESON=
                [ -e "meson.build" ] && MESON=1

                if [ -n "${MESON}" ]; then
                    rlRun "mkdir build"
                    rlRun "pushd build"
                    BUILD_DIR="${PWD}"
                    rlRun "meson setup .."
                    rlRun "ninja"
                    rlRun "meson test --print-errorlogs" 0 "Running upstream test suite"
                    python3 "${KEM_RESULTS_SCRIPT}" "${BUILD_DIR}/meson-logs/testlog.json" "${JOSE_REQUIRE_PQC_TESTS}" || \
                        rlFail "KEM test result verification failed"
                    rlRun "popd"
                else
                    rlLogWarning "This is an old (< v11) version of jose that does not use meson"
                    rlRun "dnf install -y automake autoconf libtool" 0 "Extra deps to build using autotools"

                    rlRun "autoreconf -if"
                    rlRun "./configure"
                    rlRun "make"
                    rlRun "make check"
                    if [[ "${JOSE_REQUIRE_PQC_TESTS,,}" =~ ^(1|yes|true)$ ]]; then
                        rlFail "PQC KEM test verification requires a Meson-based jose build"
                    fi
                fi
            rlRun "popd"
        else
            rlRun "meson test --no-rebuild --print-errorlogs -C \"${BUILD_DIR}\"" 0 \
                "Running upstream tests from the configured jose build"
            python3 "${KEM_RESULTS_SCRIPT}" "${BUILD_DIR}/meson-logs/testlog.json" "${JOSE_REQUIRE_PQC_TESTS}" || \
                rlFail "KEM test result verification failed"
        fi
    rlPhaseEnd

    rlPhaseStartCleanup
        if [[ -z "${JOSE_BUILD_DIR}" ]]; then
            rlRun "rm -rf /root/rpmbuild" 0 "Removing rpmbuild directory"
            if [ -e backup ]; then
                rlRun "rlFileRestore" 0 "Restore previous rpmbuild directory"
            fi

        fi

        rlRun "popd"
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
