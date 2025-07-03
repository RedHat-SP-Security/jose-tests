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

IS_IMAGE_MODE=0

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm "jose" || rlDie
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"

        [ -e /run/ostree-booted ] && IS_IMAGE_MODE=1

        # Ensure rpmbuild directories exist
        rlRun "mkdir -p /root/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}" 0 "Creating rpmbuild directories"

        if [ -d /root/rpmbuild ]; then
            rlRun "rlFileBackup --clean /root/rpmbuild" 0 "Backup rpmbuild directory"
            touch backup
        fi
    rlPhaseEnd

    rlPhaseStartTest
        if [ "$IS_IMAGE_MODE" -eq 0 ]; then
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
        else
            rlLog "Image mode detected."
            rlLog "Attempting to locate and copy jose source and spec file."

            JOSE_SOURCE_TARBALL=$(find / -name "jose-*.tar.*" -print -quit 2>/dev/null) 
            JOSE_SPEC_FILE=$(find / -name "jose.spec" -print -quit 2>/dev/null) 

            if [ -z "$JOSE_SOURCE_TARBALL" ]; then
                rlDie "In Image mode, jose source tarball not found. Please ensure it's pre-installed or copied to a known location in the image."
            else
                rlRun "cp \"$JOSE_SOURCE_TARBALL\" /root/rpmbuild/SOURCES/" 0 "Copying jose source tarball to rpmbuild"
            fi

            if [ -z "$JOSE_SPEC_FILE" ]; then
                rlDie "In Image mode, jose.spec not found. Please ensure it's pre-installed or copied to a known location in the image."
            else
                rlRun "cp \"$JOSE_SPEC_FILE\" /root/rpmbuild/SPECS/" 0 "Copying jose.spec to rpmbuild"
            fi

            rlLog "Image mode: assuming build dependencies are preinstalled."
        fi

        # Preparing source and applying existing patches.
        rlRun "SPEC=/root/rpmbuild/SPECS/jose.spec"
        rlRun "SRCDIR=/root/rpmbuild/SOURCES"

        rlRun "rm -rf jose-*"
        rlRun "tar xf ${SRCDIR}/jose-*.tar.*" 0 "Unpacking jose source"
        rlRun "pushd jose-*"
            # Loop for patches should be fine as long as SPEC is found
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
                    rlRun "meson setup .."
                    rlRun "ninja"
                    rlRun "meson test" 0 "Running upstream test suite"
                rlRun "popd"
            else
                rlLogWarning "This is an old (< v11) version of jose that does not use meson"
                if [ "$IS_IMAGE_MODE" -eq 0 ]; then
                    rlRun "dnf install -y automake autoconf libtool" 0 "Extra deps to build using autotools"
                else
                    rlLog "Image mode: assuming autotools deps are preinstalled"
                fi
                rlRun "autoreconf -if"
                rlRun "./configure"
                rlRun "make"
                rlRun "make check"
            fi
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartCleanup
        # The rlFileBackup/Restore handles /root/rpmbuild correctly.
        rlRun "rm -rf /root/rpmbuild" 0 "Removing rpmbuild directory"
        if [ -e backup ]; then
            rlRun "rlFileRestore" 0 "Restore previous rpmbuild directory"
        fi

        # Added a check for directory stack before popd to avoid errors if pushd failed previously
        if [ "$(dirs -p | wc -l)" -gt 1 ]; then # Check if there's more than just the current directory in stack
            rlRun "popd"
        else
            rlLog "Directory stack is empty, skipping popd."
        fi
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd