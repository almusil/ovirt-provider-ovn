#!/bin/bash -xe

DISTVER="$(rpm --eval "%dist"|cut -c2-4)"
PACKAGER=""
if [[ "${DISTVER}" == "el7" ]]; then
    PACKAGER=yum
    # el7 repos do not have the driver package, which is only released
    # for el8
    RPMS="exported-artifacts/ovirt-provider-ovn-[!driver]*.noarch.rpm"
else
    PACKAGER=dnf
    RPMS="exported-artifacts/ovirt-provider-ovn-*.noarch.rpm"
fi


mkdir -p exported-artifacts

mkdir -p "`rpm --eval %_topdir`" "`rpm --eval %_sourcedir`"
make rpm

cp ovirt-provider-ovn-*.tar.gz exported-artifacts/
cp ~/rpmbuild/RPMS/noarch/ovirt-provider-ovn-*.noarch.rpm exported-artifacts/
cp ~/rpmbuild/SRPMS/ovirt-provider-ovn-*.src.rpm exported-artifacts/

${PACKAGER} -y install $RPMS
