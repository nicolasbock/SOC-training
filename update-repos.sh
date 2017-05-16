#!/bin/bash

set -u
set -e
set -x

: ${LOCALDIR:=/mnt/cloud/mirror/suse}
: ${REPOSERVER:=clouddata.nue.suse.com}
: ${RSYNCOPTS:=--delete-after --partial --progress --archive --verbose \
    --compress --inplace --stats}
: ${DISTSERVER:=dist.nue.suse.com}
: ${WGETOPTS:=--timestamping --continue}

# Hopelessly out of date!
#: ${OBSSERVER:=rsync.opensuse.org}

# Another mirror (thanks to Dirk for pointing this one out)
: ${OBSSERVER:=ftp5.gwdg.de:/pub/opensuse}

update_repos() {
    declare -A REPOS
    REPOS=(
        ["images/x86_64/SLES12-SP1.qcow2"]="images/x86_64/"
        ["images/x86_64/SLES12-SP2.qcow2"]="images/x86_64/"
        ["repos/SLES11-SP3-Pool"]="repos/x86_64/"
        ["repos/SLES11-SP3-Updates"]="repos/x86_64/"
        ["repos/SUSE-Cloud-5-Pool"]="repos/x86_64/"
        ["repos/SUSE-Cloud-5-Updates"]="repos/x86_64/"
        ["repos/x86_64/SLE12-SP1-HA-Pool"]="repos/x86_64/"
        ["repos/x86_64/SLE12-SP1-HA-Updates"]="repos/x86_64/"
        ["repos/x86_64/SLE12-SP2-HA-Pool"]="repos/x86_64/"
        ["repos/x86_64/SLE12-SP2-HA-Updates"]="repos/x86_64/"
        ["repos/x86_64/SLES12-SP1-Pool"]="repos/x86_64/"
        ["repos/x86_64/SLES12-SP1-Updates"]="repos/x86_64/"
        ["repos/x86_64/SLES12-SP2-Pool"]="repos/x86_64/"
        ["repos/x86_64/SLES12-SP2-Updates"]="repos/x86_64/"
        ["repos/x86_64/SUSE-OpenStack-Cloud-6-Pool"]="repos/x86_64/"
        ["repos/x86_64/SUSE-OpenStack-Cloud-6-Updates"]="repos/x86_64/"
        ["repos/x86_64/SUSE-OpenStack-Cloud-7-Pool"]="repos/x86_64/"
        ["repos/x86_64/SUSE-OpenStack-Cloud-7-Updates"]="repos/x86_64/"
        ["suse-12.2"]="."
    )

    local r
    for r in "${!REPOS[@]}"; do
        [[ -d "${LOCALDIR}/${REPOS[$r]}" ]] || \
            mkdir -v -p "${LOCALDIR}/${REPOS[$r]}"
        echo "Syncing $r -> ${REPOS[$r]}"
        rsync ${RSYNCOPTS} \
            rsync://${REPOSERVER}/cloud/"${r}" \
            "${LOCALDIR}/${REPOS[$r]}" \
            || exit
    done
}

update_obs() {
    declare -A OBSREPOS
    for i in Newton Ocata Master; do
        OBSREPOS["repositories/Cloud:/OpenStack:/${i}/SLE_12_SP2"]="repositories/Cloud:/OpenStack:/${i}/"
    done

    for i in Newton Ocata; do
        OBSREPOS["repositories/Cloud:/OpenStack:/${i}:/Staging/SLE_12_SP2"]="repositories/Cloud:/OpenStack:/${i}:/Staging/"
    done

    local r
    for r in "${!OBSREPOS[@]}"; do
        echo "Syncing $r -> ${OBSREPOS[$r]}"
        [[ -d "${LOCALDIR}/${OBSREPOS[$r]}" ]] || \
            mkdir -v -p "${LOCALDIR}/${OBSREPOS[$r]}"
        rsync ${RSYNCOPTS} \
            rsync://${OBSSERVER}/"${r}" \
            "${LOCALDIR}/${OBSREPOS[$r]}" \
            || exit
    done
}

update_isos() {
    declare -a ISOS
    ISOS=(
        "install/SLE-12-SP1-Cloud6-GM/SUSE-OPENSTACK-CLOUD-6-x86_64-GM-DVD1.iso"
        "install/SLE-12-SP1-Server-GM/SLE-12-SP1-Server-DVD-x86_64-GM-DVD1.iso"
        "install/SLE-12-SP2-Cloud7-GM/SUSE-OPENSTACK-CLOUD-7-x86_64-GM-DVD1.iso"
        "install/SLE-12-SP2-Server-GM/SLE-12-SP2-Server-DVD-x86_64-GM-DVD1.iso"
    )

    [[ -d "${LOCALDIR}/iso" ]] || mkdir -v -p "$(dirname ${LOCALDIR}/iso)"

    local r
    for r in "${ISOS[@]}"; do
        echo "Syncing $r -> iso"
        wget ${WGETOPTS} \
            --directory-prefix="${LOCALDIR}/iso" \
            http://${DISTSERVER}/"${r}" \
            || exit
    done
}

update_cloud_isos() {
    declare -a CLOUDISOS
    CLOUDISOS=(
        "http://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img"
        "http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img"
        "http://download.cirros-cloud.net/0.3.5/cirros-0.3.5-x86_64-disk.img"
        "http://download.suse.de/ibs/home:/tbechtold:/Images/images/cleanvm-jeos-SLE12SP2.x86_64.qcow2"
    )

    local i
    for i in "${CLOUDISOS[@]}"; do
        wget ${WGETOPTS} \
            --directory-prefix="${LOCALDIR}/iso" \
            ${i} || exit
    done
}

monasca_hacks() {
    #rsync ${RSYNCOPTS} \
    #    rsync://${OBSSERVER}/buildservice-repos/home:/jgrassler:/monasca/SLE_12_SP2 \
    #    "${LOCALDIR}"/repositories/home:/jgrassler:/monasca/ \
    #    || exit

    [[ -d ${LOCALDIR}/repositories/home:/jgrassler: ]] \
        || mkdir -p ${LOCALDIR}/repositories/home:/jgrassler:
    wget --mirror --no-parent \
        --directory-prefix "${LOCALDIR}" \
        http://download.opensuse.org/repositories/home:/jgrassler:/monasca/SLE_12_SP2
    ln -sf \
        ${LOCALDIR}/download.opensuse.org/repositories/home:/jgrassler:/monasca \
        ${LOCALDIR}/repositories/home:/jgrassler:/monasca
#(cd $repodir; wget --mirror --no-parent http://download.opensuse.org/repositories/home:/jgrassler:/branches:/home:/jgrassler:/monasca/SLE_12_SP2/
}

update_repos
update_obs
update_isos
update_cloud_isos
#monasca_hacks
