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

rlJournalStart
    rlPhaseStartSetup
        rlAssertRpm "jose" || rlDie
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        if [ -d /root/rpmbuild ]; then
            rlRun "rlFileBackup /root/rpmbuild" 0 "Backup rpmbuild directory"
            touch backup
        fi
    rlPhaseEnd

    rlPhaseStartTest
        rlRun "rlFetchSrcForInstalled jose"
        rlRun "rpm -Uvh *.src.rpm" 0 "Install jose source rpm"

        # Enabling buildroot/CRB so that we can have the build dependencies.
        for r in rhel-buildroot rhel-CRB rhel-CRB-latest beaker-CRB; do
            ! dnf config-manager --set-enabled "${r}"
        done

        if rlIsRHEL '>=10'; then
           # due jansson-devel missing package for rhel-10-beta
           rlRun "dnf builddep -y jose* --skip-broken --nobest" 0 "Install jose build dependencies"
        else
            rlRun "dnf builddep -y jose*" 0 "Install jose build dependencies"
        fi

        # Preparing source and applying existing patches.
        rlRun "SPEC=/root/rpmbuild/SPECS/jose.spec"
        rlRun "SRCDIR=/root/rpmbuild/SOURCES"

        rlRun "rm -rf jose-*"
        rlRun "tar xf ${SRCDIR}/jose-*.tar.*" 0 "Unpacking jose source"
        rlRun "pushd jose-*"
            for p in $(grep ^Patch "${SPEC}" | awk '{ print$2 }'); do
                rlRun "patch -p1 < ${SRCDIR}/${p}" 0 "Applying patch ${p}"
            done

            rlRun "mkdir build"
            rlRun "pushd build"
                rlRun "meson .."
                rlRun "meson test" 0 "Running upstream test suite"
            rlRun "popd"
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "rm -rf /root/rpmbuild" 0 "Removing rpmbuild directory"
        if [ -e backup ]; then
            rlRun "rlFileRestore" 0 "Restore previous rpmbuild directory"
        fi

        rlRun "popd"
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalPrintText
rlJournalEnd
