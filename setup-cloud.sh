#!/bin/bash
#
# set tw=0

set -e
set -u

. cloud-functions.sh

if [[ $# -eq 0 ]]; then
    echo "missing cloud config"
    exit 1
else
    CLOUD_CONFIG="$1"
    shift
fi
if [[ -f ${CLOUD_CONFIG} ]]; then
    set -x
    source ${CLOUD_CONFIG}
    if [[ ${debug_setup} != 1 ]]; then
        set +x
    fi
else
    echo "missing ${CLOUD_CONFIG}"
    exit 1
fi

log_dir_default=/var/log/cloud/$cloud
[[ $UID != 0 ]] && log_dir_default="./log"
: ${log_dir:=$log_dir_default}
mkdir -p "$log_dir"
log_file=$log_dir/`date -Iseconds`.log
exec >  >(exec tee -ia $log_file)
exec 2> >(exec tee -ia $log_file >&2)

PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

if [[ ${update_repos} = 1 ]]; then
    ./update-repos.sh
fi

cleanup_nodes() {
    remove_admin ${cloud}

    local i

    for i in $(seq ${NODES}); do
        remove_node ${cloud} ${i}
    done
}

cleanup_networks() {
    local BRIDGE_DEV=$(virsh net-info ${cloud}-public \
        | grep Bridge | awk '{print $2}')

    if [[ -n $BRIDGE_DEV ]]; then
        ip link set ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} down
        ip link delete ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID}
    fi

    BRIDGE_DEV=$(virsh net-info ${cloud}-admin \
        | grep Bridge | awk '{print $2}')

    if [[ -n $BRIDGE_DEV ]]; then
        iptables \
            --delete INPUT -i ${BRIDGE_DEV} \
            --destination ${ADMIN_NETWORK}.0/24 \
            --jump ACCEPT || true
    fi

    # Delete and insert to make sure that rule is the first one.
    iptables \
        --delete FORWARD \
        --destination 192.168.0.0/16 \
        --jump ACCEPT || true

    iptables \
        --insert FORWARD 1 \
        --destination 192.168.0.0/16 \
        --jump ACCEPT

    if $(virsh net-info ${cloud}-admin > /dev/null 2>&1); then
        echo "Removing ${cloud}-admin"
        virsh net-destroy ${cloud}-admin || exit
    fi
    if $(virsh net-info ${cloud}-public > /dev/null 2>&1); then
        echo "Removing ${cloud}-public"
        virsh net-destroy ${cloud}-public || exit
    fi

    virsh net-list --all
    iptables --list INPUT --verbose --numeric --line-numbers
}

cleanup() {
    cleanup_nodes
    cleanup_networks
}

setup_networks() {
    cleanup_networks

    local NET_XML=$(mktemp)

    cat <<EOF > ${NET_XML}
<network>
  <name>${cloud}-admin</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <domain name="cloud.local"/>
  <ip address='${ADMIN_NETWORK}.1' netmask='255.255.255.0'>
  </ip>
</network>
EOF

    #    <dhcp>
    #      <host mac='${ADMIN_MAC}' name='${cloud}-admin' ip='${ADMIN_NETWORK}.10'/>
    #    </dhcp>

    cat ${NET_XML}

    virsh net-create ${NET_XML}
    #virsh net-start ${cloud}-admin

    rm -v ${NET_XML}

    local BRIDGE_DEV=$(get_bridge_dev ${cloud}-admin)
    local LAST=$(iptables --list INPUT --verbose --numeric --line-numbers \
        | grep ${BRIDGE_DEV} | tail -n1 | awk '{print $1}')
    iptables \
        --insert INPUT $((${LAST} + 1)) \
        --in-interface ${BRIDGE_DEV} \
        --destination ${ADMIN_NETWORK}.0/24 \
        --jump ACCEPT

    # Delete and insert to make sure that rule is the first one.
    #iptables \
    #    --delete FORWARD \
    #    --destination 192.168.0.0/16 \
    #    --jump ACCEPT || true

    #iptables \
    #    --insert FORWARD 1 \
    #    --destination 192.168.0.0/16 \
    #    --jump ACCEPT

    if [[ ${NETWORK_MODE} = "dual" ]]; then
        BRIDGE_DEV=${cloud}-public-br
        NET_XML=$(mktemp)

        cat <<EOF > ${NET_XML}
<network>
  <name>${cloud}-public</name>
  <forward mode='nat'>
  <nat>
    <port start='1024' end='65535'/>
  </nat>
  </forward>
  <bridge name='${BRIDGE_DEV}' stp='off' delay='0'/>
  <ip address='${PUBLIC_NETWORK_BRIDGE_IP}' netmask='255.255.255.0'>
  </ip>
</network>
EOF

        cat ${NET_XML}

        if $(virsh net-info ${cloud}-public > /dev/null); then
            virsh net-destroy ${cloud}-public
            virsh net-undefine ${cloud}-public
        fi

        virsh net-define ${NET_XML}
        virsh net-start ${cloud}-public

        rm -v ${NET_XML}
    fi

    #create_public_link ${BRIDGE_DEV} ${PUBLIC_NETWORK} ${PUBLIC_NETWORK_ID}

    virsh net-dumpxml ${cloud}-admin
    ip -d addr show ${BRIDGE_DEV}
    iptables --list INPUT --verbose --numeric --line-numbers
    iptables --list FORWARD --verbose --numeric --line-numbers
    virsh net-list --all
}

create_admin() {
    local HOSTS_ENTRY="${ADMIN_NETWORK}.10 ${cloud}-admin"
    if $(grep --quiet ${ADMIN_NETWORK}.10 /etc/hosts); then
        sed -i -e "s/${ADMIN_NETWORK}.10.*$/${HOSTS_ENTRY}/" /etc/hosts
    else
        bash -c "echo ${HOSTS_ENTRY} >> /etc/hosts"
    fi

    remove_admin ${cloud}

    if [[ ${rebuild_base} = 1 ]]; then
        create_vol ${cloud}-admin.qcow2 ${ADMIN_DISK_SIZE}
    else
        if [[ ${ADMIN_BASE_URL} ]]; then
            rsync --compress --progress --inplace --archive --verbose \
                ${ADMIN_BASE_URL} /tmp/
        else
            clone_vol ${ADMIN_BASE_POOL} ${ADMIN_BASE_IMAGE} \
                ${pool} ${cloud}-admin.qcow2
        fi
    fi
    virsh vol-info ${cloud}-admin.qcow2 --pool ${pool}

    local CLOUDCD=
    if [[ ${want_cloud_pool} = 0 ]]; then
        CLOUDCD=--disk device=cdrom,path=${CD2}
    fi

    local NETWORK="network=${cloud}-admin"
    if [[ ${ADMIN_MAC} ]]; then
        NETWORK="${NETWORK},mac=${ADMIN_MAC}"
    fi
    virt-install \
        --os-variant sles12sp1 \
        --cpu mode=host-passthrough \
        --name ${cloud}-admin \
        --memory ${ADMIN_MEMORY} \
        --check path_in_use=off \
        --disk vol=${pool}/${cloud}-admin.qcow2 \
        --disk device=cdrom,path=${CD1} \
        ${CLOUDCD} \
        --network ${NETWORK} \
        --boot ${ADMIN_BOOT} \
        --noautoconsole

    virsh destroy ${cloud}-admin
}

prepare_admin() {
    local snapshot_name="first_boot"

    if [[ ! ($(virsh domstate ${cloud}-admin) =~ "off") ]]; then
        shutdown_node ${cloud}-admin
    fi

    if [[ ${rebuild_base} = 1 ]]; then
        virsh vol-delete ${ADMIN_BASE_IMAGE} --pool ${pool}
        clone_vol ${pool} ${cloud}-admin.qcow2 \
            ${ADMIN_BASE_POOL} ${ADMIN_BASE_IMAGE} || exit
    fi

    ssh-keygen -R ${cloud}-admin
    ssh-keygen -R ${ADMIN_NETWORK}.10

    inject_ssh_key ${cloud}-admin.qcow2
    fix_admin_network ${cloud}-admin.qcow2
    start_admin

    # Make sure we have the host ssh key.
    on_admin "uptime"

    copy_to_admin suse-bashrc ${CLOUDUSER}@${cloud}-admin:.bashrc || exit
    copy_to_admin vimrc ${CLOUDUSER}@${cloud}-admin:.vimrc || exit
    on_admin "mkdir -p ~/.vim/{backup,swap,undo}" || exit

    if [[ ${CLOUDUSER} != root ]]; then
        while ! $(on_admin "sudo --list" | grep --quiet "NOPASSWD"); do
            echo "please fix your sudo setup"
            on_admin_interactive "sudo visudo" || exit
        done
    fi

    # Remove old repos.
    while [[ $(on_admin "sudo zypper repos | grep ^[0-9] | wc -l") -gt 0 ]]; do
        on_admin "sudo zypper removerepo 1"
    done

    on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SLE12-${SLESVERSION}-HA-Pool              SLE12-${SLESVERSION}-HA-Pool"
    on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SLE12-${SLESVERSION}-HA-Updates           SLE12-${SLESVERSION}-HA-Updates"
    #on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SLES11-SP3-Pool                SLES11-SP3-Pool"
    #on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SLES11-SP3-Updates             SLES11-SP3-Updates"

    on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SLES12-${SLESVERSION}-Pool    SLES12-${SLESVERSION}-Pool"
    on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SLES12-${SLESVERSION}-Updates SLES12-${SLESVERSION}-Updates"

    #on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SUSE-OpenStack-Cloud-5-Pool    SUSE-OpenStack-Cloud-5-Pool"
    #on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SUSE-OpenStack-Cloud-5-Updates SUSE-OpenStack-Cloud-5-Updates"
    #on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SUSE-OpenStack-Cloud-6-Pool    SUSE-OpenStack-Cloud-6-Pool"
    #on_admin "sudo zypper addrepo --refresh http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SUSE-OpenStack-Cloud-6-Updates SUSE-OpenStack-Cloud-6-Updates"

    on_admin "sudo zypper repos --uri"
    on_admin_interactive "sudo zypper refresh"
    on_admin_interactive "sudo zypper update --no-confirm"
    on_admin_interactive "sudo zypper patch --no-confirm"

    #TMP=$(mktemp)
    #cat > ${TMP} <<EOF
    #set -x
    #set -u
    #sed -i -e "s:BOOTPROTO='.*':BOOTPROTO='static':" /etc/sysconfig/network/ifcfg-eth0
    #sed -i -e "s:^IPADDR='.*':IPADDR='${ADMIN_NETWORK}.10/24':" /etc/sysconfig/network/ifcfg-eth0
    #echo ${cloud}-admin.cloud.local > /etc/hostname
    #echo search cloud.local > /etc/resolv.conf
    #echo nameserver ${ADMIN_NETWORK}.1 >> /etc/resolv.conf
    #echo ${ADMIN_NETWORK}.10 ${cloud}-admin.cloud.local ${cloud}-admin >> /etc/hosts
    #EOF
    #scp ${TMP} ${CLOUDUSER}@${cloud}-admin:fix-network.sh
    #on_admin "sudo bash ./fix-network.sh"

    #set +x
    #echo "Please make sure the network is correctly configure"
    #on_admin_interactive
    #set -x

    shutdown_node ${cloud}-admin
    if $(virsh snapshot-info --snapshotname "${snapshot_name}" ${cloud}-admin > /dev/null); then
        virsh snapshot-delete ${cloud}-admin --snapshotname "${snapshot_name}"
    fi
    virsh snapshot-create-as ${cloud}-admin \
        --name "${snapshot_name}" \
        --description "The admin node is installed and somewhat configured."

    start_admin

    if [[ ${want_cloud_pool} = 1 ]]; then
        on_admin "sudo zypper addrepo --refresh \
            http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Pool \
            SUSE-OpenStack-Cloud-${CLOUDVERSION}-Pool"
        on_admin "sudo zypper addrepo --refresh \
            http://${ADMIN_NETWORK}.1/suse/repos/x86_64/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Updates \
            SUSE-OpenStack-Cloud-${CLOUDVERSION}-Updates"
    else
        on_admin "sudo zypper addrepo --refresh cd:/?devices=/dev/sr1 SOC${CLOUDVERSION}"
    fi

    on_admin_interactive "sudo zypper update --no-confirm"
    on_admin_interactive "sudo zypper patch --no-confirm"
    on_admin_interactive "sudo zypper install --type pattern \
        --auto-agree-with-licenses --no-confirm cloud_admin"

    case ${SLESVERSION} in
        SP1)
            LOCALSLESVERSION=12.1
            ;;
        SP2)
            LOCALSLESVERSION=12.2
            ;;
        *)
            echo "unknown SLES version"
            exit 1
            ;;
    esac

    if [[ ${mount_srv} = 1 ]]; then
        on_admin "sudo bash -c 'echo /dev/sr0 \
            /srv/tftpboot/suse-12.2/x86_64/install iso9660 ro 0 0 >> /etc/fstab'"
        on_admin "sudo mkdir -p \
            /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/Cloud"
        if [[ ${want_cloud_pool} = 1 ]]; then
            on_admin "sudo bash -c 'echo ${ADMIN_NETWORK}.1:/mnt/cloud/mirror/suse/repos/x86_64/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Pool \
                /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/Cloud nfs ro 0 0 >> /etc/fstab'"
        else
            on_admin "sudo bash -c 'echo /dev/sr1 \
                /srv/tftpboot/suse-12.2/x86_64/repos/Cloud iso9660 ro 0 0 >> /etc/fstab'"
        fi
    else
        on_admin "grep --quiet /mnt /proc/mounts && sudo umount /mnt"
        on_admin "sudo mount /dev/sr0 /mnt" || exit
        on_admin "sudo rsync -av --delete-after \
            /mnt/ /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/install/" || exit
        on_admin "sudo umount /mnt" || exit

        on_admin "grep --quiet /mnt /proc/mounts && sudo umount /mnt"
        on_admin "sudo mount /dev/sr1 /mnt" || exit
        on_admin "sudo rsync -av --delete-after /mnt/ \
            /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/Cloud/" || exit
        on_admin "sudo umount /mnt" || exit
    fi

    on_admin "sudo mkdir -p /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SLE12-${SLESVERSION}-HA-Pool" || exit
    on_admin "sudo bash -c 'echo ${ADMIN_NETWORK}.1:/mnt/cloud/mirror/suse/repos/x86_64/SLE12-${SLESVERSION}-HA-Pool \
        /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SLE12-${SLESVERSION}-HA-Pool nfs ro 0 0 >> /etc/fstab'"
    on_admin "sudo mkdir -p /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SLE12-${SLESVERSION}-HA-Updates" || exit
    on_admin "sudo bash -c 'echo ${ADMIN_NETWORK}.1:/mnt/cloud/mirror/suse/repos/x86_64/SLE12-${SLESVERSION}-HA-Updates \
        /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SLE12-${SLESVERSION}-HA-Updates nfs ro 0 0 >> /etc/fstab'"

    on_admin "sudo mkdir -p /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SLES12-${SLESVERSION}-Pool" || exit
    on_admin "sudo bash -c 'echo ${ADMIN_NETWORK}.1:/mnt/cloud/mirror/suse/repos/x86_64/SLES12-${SLESVERSION}-Pool \
        /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SLES12-${SLESVERSION}-Pool nfs ro 0 0 >> /etc/fstab'"
    on_admin "sudo mkdir -p /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SLES12-${SLESVERSION}-Updates" || exit
    on_admin "sudo bash -c 'echo ${ADMIN_NETWORK}.1:/mnt/cloud/mirror/suse/repos/x86_64/SLES12-${SLESVERSION}-Updates \
        /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SLES12-${SLESVERSION}-Updates nfs ro 0 0 >> /etc/fstab'"
    #on_admin "sudo rsync -av --delete-after rsync://${ADMIN_NETWORK}.1/cloud/repos/x86_64/SLES12-${SLESVERSION}-Pool /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/"    || exit
    #on_admin "sudo rsync -av --delete-after rsync://${ADMIN_NETWORK}.1/cloud/repos/x86_64/SLES12-${SLESVERSION}-Updates /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/" || exit

    if [[ ${want_cloud_pool} = 1 ]]; then
        on_admin "sudo mkdir -p /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Pool" || exit
        on_admin "sudo bash -c 'echo ${ADMIN_NETWORK}.1:/mnt/cloud/mirror/suse/repos/x86_64/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Pool \
            /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Pool nfs ro 0 0 >> /etc/fstab'"
        on_admin "sudo mkdir -p /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Updates" || exit
        on_admin "sudo bash -c 'echo ${ADMIN_NETWORK}.1:/mnt/cloud/mirror/suse/repos/x86_64/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Updates \
            /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Updates nfs ro 0 0 >> /etc/fstab'"
        #on_admin "sudo rsync -av --delete-after rsync://${ADMIN_NETWORK}.1/cloud/repos/x86_64/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Pool /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/"    || exit
        #on_admin "sudo rsync -av --delete-after rsync://${ADMIN_NETWORK}.1/cloud/repos/x86_64/SUSE-OpenStack-Cloud-${CLOUDVERSION}-Updates /srv/tftpboot/suse-${LOCALSLESVERSION}/x86_64/repos/" || exit
    fi

    on_admin "sudo mount -a -v"
    on_admin "df -h"
    on_admin "cat /etc/fstab"

    #[[ -f network.json ]] && copy_to_admin network.json ${CLOUDUSER}@${cloud}-admin:/etc/crowbar/

    local TMP=$(mktemp)

    # We potentially need the script file as a normal user.
    chmod 644 ${TMP}

    cat > ${TMP} <<EOF
sed -i \
    -e 's/"conduit": "bmc",$/& "router": "192.168.124.1",/' \
    -e 's/"mode": ".*"/"mode": "${NETWORK_MODE}"/' \
    -e "s:192.168.124:${ADMIN_NETWORK}:g" \
    -e "s:192.168.126:${PUBLIC_NETWORK}:g" \
    -e "s/ 300/ ${PUBLIC_NETWORK_ID}/g" \
    /etc/crowbar/network.json
EOF
    copy_to_admin ${TMP} ${CLOUDUSER}@${cloud}-admin:fix-network-json.sh
    rm -v ${TMP}
    on_admin "sudo bash fix-network-json.sh"

    case ${CLOUDVERSION} in
        6)
            on_admin "sudo systemctl start crowbar"
            ;;
        7)
            on_admin "sudo systemctl start crowbar-init.service"
            sleep 10
            on_admin "crowbarctl database create"
            ;;
        *)
            echo "unknown CLOUDVERSION"
            exit 1
    esac

    crowbar_api=http://${cloud}-admin:80
    crowbar_api_installer_path=/installer/installer
    crowbar_api_request POST $crowbar_api $crowbar_api_installer_path/start.json

    install_successful=0
    for i in $(seq 100); do
        if $(on_admin "sudo cat /var/log/crowbar/install.log" \
            | grep --quiet 'Admin node deployed'); then
            install_successful=1
            break
        fi
        on_admin "timeout 20s sudo tail -f /var/log/crowbar/install.log" || true
    done

    if [[ ${install_successful} -ne 1 ]]; then
        echo "failed to install crowbar"
        exit 1
    fi

    ntp_proposal

    wait_for_ssh ${cloud}-admin
    shutdown_node ${cloud}-admin
    virsh snapshot-create-as ${cloud}-admin \
        --name 'fresh_crowbar' \
        --description "Crowbar is freshly installed."

    start_admin
    wait_for_ssh ${cloud}-admin
    wait_for_crowbar
}

create_nodes() {
    local NETWORK=""
    local i

    for i in $(seq ${NICS}); do
        NETWORK+="--network network=${cloud}-admin "
    done

    wait_for_crowbar

    for i in $(seq ${NODES}); do
        remove_node ${cloud} ${i}

        clone_vol ${ADMIN_BASE_POOL} ${ADMIN_BASE_IMAGE} \
            ${pool} ${cloud}-node-${i}-1.qcow2 || exit

        create_vol ${cloud}-node-${i}-2.qcow2 ${NODES_DISK_SIZE}

        virt-install \
            --os-variant sles12sp1 \
            --cpu mode=host-passthrough \
            --name ${cloud}-node-${i} \
            --memory ${NODES_MEMORY} \
            --check path_in_use=off \
            --disk vol=${pool}/${cloud}-node-${i}-1.qcow2 \
            --disk vol=${pool}/${cloud}-node-${i}-2.qcow2 \
            ${NETWORK} \
            --boot network,hd,menu=on \
            --noautoconsole

        on_admin "timeout 2m sudo tail -f /var/log/crowbar/production.log" || true
    done

    for i in $(seq ${NODES}); do
        local MAC=$(virsh dumpxml ${cloud}-node-${i} | grep "mac address" | head -n1 | sed -e "s/^.*'\(.*\)'.*/\1/")
        local CROWBAR_NAME=d${MAC//:/-}
        for counter in $(seq 500); do
            if $(on_admin "crowbarctl node list" | grep ${CROWBAR_NAME} | grep --quiet pending); then
                break
            fi
            on_admin "timeout 15s sudo tail -f /var/log/crowbar/production.log" || true
        done
        on_admin "crowbarctl node rename ${CROWBAR_NAME} ${cloud}-node-${i}"
        on_admin "crowbarctl node allocate ${cloud}-node-${i}"
    done

    for i in $(seq ${NODES}); do
        local MAC=$(virsh dumpxml ${cloud}-node-${i} | grep "mac address" | head -n1 | sed -e "s/^.*'\(.*\)'.*/\1/")
        local CROWBAR_NAME=d${MAC//:/-}
        for counter in $(seq 500); do
            if $(on_admin "crowbarctl node list" | grep ${CROWBAR_NAME} | grep --quiet ready); then
                break
            fi
            on_admin "timeout 15s sudo tail -f /var/log/crowbar/production.log" || true
        done
    done
}

create_nodes_fast() {
    local NETWORK=""
    local i

    for i in $(seq ${NICS}); do
        NETWORK+="--network network=${cloud}-admin "
    done

    # The last network is for administrative tasks from the KVM host.
    NETWORK+="--network network=default"

    wait_for_crowbar

    for i in $(seq ${NODES}); do
        remove_node ${cloud} ${i}

        clone_vol ${ADMIN_BASE_POOL} ${ADMIN_BASE_IMAGE} \
            ${pool} ${cloud}-node-${i}-1.qcow2 || exit

        inject_ssh_key ${cloud}-node-${i}-1.qcow2

        create_vol ${cloud}-node-${i}-2.qcow2 ${NODES_DISK_SIZE}

        virt-install \
            --os-variant sles12sp1 \
            --cpu mode=host-passthrough \
            --name ${cloud}-node-${i} \
            --memory ${NODES_MEMORY} \
            --check path_in_use=off \
            --disk vol=${pool}/${cloud}-node-${i}-1.qcow2 \
            --disk vol=${pool}/${cloud}-node-${i}-2.qcow2 \
            ${NETWORK} \
            --boot hd,network,menu=on \
            --noautoconsole

        on_admin "timeout 30s sudo tail -f /var/log/crowbar/production.log" || true
    done

    #for i in $(seq ${NODES}); do
    #    on_node ${cloud}-node-${i} "sudo /root/register.sh"
    #done

    for i in $(seq ${NODES}); do
        local MAC=$(virsh dumpxml ${cloud}-node-${i} | grep "mac address" | head -n1 | sed -e "s/^.*'\(.*\)'.*/\1/")
        local CROWBAR_NAME=d${MAC//:/-}
        for counter in $(seq 200); do
            if $(on_admin "crowbarctl node list" | grep --quiet ${CROWBAR_NAME}); then
                break
            fi
            on_admin "timeout 30s sudo tail -f /var/log/crowbar/production.log" || true
        done
        on_admin "crowbarctl node rename ${CROWBAR_NAME} ${cloud}-node-${i}"
    done
}

register_nodes() {
    local snapshot_name="fresh_node"

    wait_for_ssh ${cloud}-admin
    wait_for_crowbar
    wait_for_nodes

    for i in $(seq ${NODES}); do
        virsh shutdown ${cloud}-node-${i}
    done
    virsh shutdown ${cloud}-admin

    for i in $(seq ${NODES}); do
        wait_for_domstate ${cloud}-node-${i} off

        if $(virsh snapshot-info --snapshotname "${snapshot_name}" ${cloud}-node-${i} > /dev/null); then
            virsh snapshot-delete ${cloud}-node-${i} --snapshotname "${snapshot_name}"
        fi

        virsh snapshot-create-as ${cloud}-node-${i} \
            --name "${snapshot_name}" \
            --description "Nodes are freshly allocated."
    done

    wait_for_domstate ${cloud}-admin off
    if $(virsh snapshot-info --snapshotname "${snapshot_name}" ${cloud}-admin > /dev/null); then
        virsh snapshot-delete ${cloud}-admin --snapshotname "${snapshot_name}"
    fi
    virsh snapshot-create-as ${cloud}-admin \
        --name "${snapshot_name}" \
        --description "Nodes are freshly allocated."

    start_admin
    wait_for_crowbar

    start_nodes
    wait_for_nodes
}

register_nodes_fast() {
    local snapshot_name="fresh_node"

    wait_for_ssh ${cloud}-admin
    wait_for_crowbar
    wait_for_nodes

    for i in $(seq ${NODES}); do
        virsh shutdown ${cloud}-node-${i}
    done
    virsh shutdown ${cloud}-admin

    for i in $(seq ${NODES}); do
        wait_for_domstate ${cloud}-node-${i} off

        local TMP=$(mktemp domain-XXXXXX.xml)
        virsh dumpxml --inactive --security-info ${cloud}-node-${i} > ${TMP}

        # Change boot order.
        local TMP2=$(mktemp domain-XXXXXX.xml)
        sed -e "s/<boot dev='hd'/<boot dev='1'/" \
            -e "s/<boot dev='network'/<boot dev='2'/" \
            ${TMP} > ${TMP2}
        sed -i \
            -e "s/<boot dev='1'/<boot dev='network'/" \
            -e "s/<boot dev='2'/<boot dev='hd'/" \
            ${TMP2}

        virsh define ${TMP2}

        rm -v ${TMP} ${TMP2}
        if $(virsh snapshot-info --snapshotname "${snapshot_name}" ${cloud}-node-${i} > /dev/null); then
            virsh snapshot-delete ${cloud}-node-${i} --snapshotname "${snapshot_name}"
        fi

        virsh snapshot-create-as ${cloud}-node-${i} \
            --name "${snapshot_name}" \
            --description "Nodes are freshly allocated."
    done

    wait_for_domstate ${cloud}-admin off
    if $(virsh snapshot-info --snapshotname "${snapshot_name}" ${cloud}-admin > /dev/null); then
        virsh snapshot-delete ${cloud}-admin --snapshotname "${snapshot_name}"
    fi
    virsh snapshot-create-as ${cloud}-admin \
        --name "${snapshot_name}" \
        --description "Nodes are freshly allocated."

    start_admin
    wait_for_crowbar

    start_nodes
    wait_for_nodes
}

assign_roles() {
    for i in $(seq ${NODES}); do
        local MAC=$(virsh dumpxml ${cloud}-node-${i} | grep "mac address" | head -n1 | sed -e "s/^.*'\(.*\)'.*/\1/")
        local CROWBAR_NAME=d${MAC//:/-}
        if [[ ${i} -eq 1 ]]; then
            on_admin "crowbarctl node rename ${CROWBAR_NAME} controller"
            on_admin "crowbarctl node role ${CROWBAR_NAME} controller"
        elif [[ ${i} -eq 2 ]]; then
            on_admin "crowbarctl node rename ${CROWBAR_NAME} network"
            on_admin "crowbarctl node role ${CROWBAR_NAME} network"
        elif [[ ${i} -eq 3 ]]; then
            on_admin "crowbarctl node rename ${CROWBAR_NAME} storage"
            on_admin "crowbarctl node role ${CROWBAR_NAME} storage"
        elif [[ ${i} -gt 3 ]]; then
            on_admin "crowbarctl node rename ${CROWBAR_NAME} compute-$((${i} - 3))"
            on_admin "crowbarctl node role ${CROWBAR_NAME} compute"
        fi
    done
}

restart_cluster() {
    shutdown_cluster

    setup_networks

    start_admin
    wait_for_crowbar

    start_nodes
    wait_for_nodes
}

apply_proposal() {
    database_proposal
    rabbitmq_proposal
    keystone_proposal
    glance_proposal
    cinder_proposal
    neutron_proposal
    nova_proposal
    horizon_proposal
    heat_proposal
    magnum_proposal
}

plain() {
    cleanup
    setup_networks
    create_admin
    prepare_admin
    create_nodes
    register_nodes
    assign_roles
    apply_proposal
}

help() {
    cat <<EOF
Usage:

Known commands:
help
cleanup
cleanup_nodes
cleanup_networks
setup_networks
create_admin
prepare_admin
create_nodes
create_nodes_fast
register_nodes
register_nodes_fast
assign_roles
apply_proposal
shutdown_cluster
restart_cluster
suspend_cluster
resume_cluster
database_proposal
rabbitmq_proposal
keystone_proposal
glance_proposal
cinder_proposal
neutron_proposal
nova_proposal
horizon_proposal
heat_proposal
magnum_proposal
plain
EOF
}

while [[ $# -gt 0 ]]; do
    ${1}
    shift
done
