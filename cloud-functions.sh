# vim: tw=0

set -u

on_admin() {
    if [[ $# -eq 0 ]]; then
        cmd=
    else
        cmd=$1
    fi
    local PREFIX

    # We are running all of this under 'sudo', and want to execute some
    # functions as a normal user.
    if [[ ${SUDO_USER} ]]; then
        PREFIX="sudo -u ${SUDO_USER}"
    fi
    ${PREFIX} ssh -o StrictHostKeyChecking=no ${CLOUDUSER}@${cloud}-admin "${cmd}"
}

on_admin_interactive() {
    if [[ $# -eq 0 ]]; then
        cmd=
    else
        cmd=$1
    fi
    local PREFIX

    # We are running all of this under 'sudo', and want to execute some
    # functions as a normal user.
    if [[ ${SUDO_USER} ]]; then
        PREFIX="sudo -u ${SUDO_USER}"
    fi
    ${PREFIX} ssh -t -o StrictHostKeyChecking=no ${CLOUDUSER}@${cloud}-admin "${cmd}"
}

on_node() {
    local node=${1}
    shift
    if [[ $# -eq 0 ]]; then
        cmd=
    else
        cmd=$1
    fi
    local PREFIX

    local ip=$(virsh domifaddr ${node})

    # We are running all of this under 'sudo', and want to execute some
    # functions as a normal user.
    if [[ ${SUDO_USER} ]]; then
        PREFIX="sudo -u ${SUDO_USER}"
    fi
    ${PREFIX} ssh -o StrictHostKeyChecking=no ${CLOUDUSER}@${node} "${cmd}"
}

copy_to_admin() {
    local PREFIX
    if [[ ${SUDO_USER} ]]; then
        PREFIX="sudo -u ${SUDO_USER}"
    fi
    ${PREFIX} scp "${@}"
}

wait_for_ssh() {
    local node=$1
    echo "waiting for ssh on ${node} to be available"
    local i
    for i in $(seq 200); do
        if $(netcat -z ${node} 22); then
            break
        fi
        sleep 5
    done
}

wait_for_crowbar() {
    local i
    for i in $(seq 100); do
        if $(on_admin "crowbarctl node list --plain" | grep --quiet admin); then
            return
        fi
        on_admin "timeout 20s sudo tail -f /var/log/crowbar/production.log" || true
    done
    echo "timed out while waiting for crowbar"
    false
}

wait_for_nodes() {
    local NS=($(on_admin "crowbarctl node list --plain" | grep -v admin | awk '{print $1}'))
    echo "found ${#NS[@]} nodes"

    if [[ ${#NS[@]} -ne ${NODES} ]]; then
        echo "could not find all nodes"
        exit 1
    fi

    local i
    for (( i = 0; i < ${#NS[@]}; i++ )); do
        local node_ready=0
        local j
        for j in $(seq 1000); do
            if $(on_admin "crowbar machines show ${NS[${i}]} state | grep -q '^ready$'"); then
                node_ready=1
                break
            fi
            on_admin "timeout 10s sudo tail -f /var/log/crowbar/production.log" || true
        done
        if [[ ${node_ready} -ne 1 ]]; then
            echo "node ${NS[${i}]} did not transition to ready"
            exit 1
        fi
    done
}

rename_node() {
    for i in $(seq ${NODES}); do
        on_admin "crowbarctl node rename ${NS[$((${i} - 1))]} ${cloud}-node-${i}"
    done
}

open_ssh_master() {
    ssh -N $1
}

wait_for_domstate() {
    local i
    for i in $(seq 200); do
        if $(virsh domstate ${1} | grep --quiet ${2}); then
            break
        fi
        sleep 5
    done
}

create_vol() {
    local name=$1
    local size=$2

    if $(virsh vol-info ${name} --pool ${pool} > /dev/null); then
        virsh vol-delete ${name} --pool ${pool}
    fi
    virsh vol-create-as \
        ${pool} \
        ${name} \
        $(( ${size} * 1024 * 1024 * 1024 )) \
        --format qcow2 || exit
}

# parameters
#  1:  method  GET|POST
#  2:  api     schema://hostname.tld
#  3:  apipath /path/to/request
#  4:  curlopts options to curl command (like -d"something")
#  5+: headers additional headers
crowbar_api_request() {
    local method=${1:-GET}
    local api=${2:-$crowbar_api}
    local api_path=${3:-/}
    local curl_opts=${4:-}
    shift || true
    shift || true
    shift || true
    shift || true
    local outfile=crowbar-api-request.txt
    rm -f $outfile
    local http_code=`curl --max-time 300 -X $method $curl_opts "${@/#/-H}" \
        -s -o $outfile -w '%{http_code}' $api$api_path`
    if [[ $http_code = 000 ]]; then
        echo "Cannot reach $api$api_path: http code 000"
        return 1
    fi
    if ! [[ $http_code =~ [23].. ]]; then
        cat $outfile
        echo "Request to $api$api_path returned http code: $http_code"
        return 1
    else
        return 0
    fi
}

create_public_link() {
    local BRIDGE_DEV=$1
    local PUBLIC_NETWORK=$2
    local PUBLIC_NETWORK_ID=$3

    ip link add link ${BRIDGE_DEV} \
        name ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        type vlan id ${PUBLIC_NETWORK_ID} || exit
    ip addr add ${PUBLIC_NETWORK}.1/24 \
        brd ${PUBLIC_NETWORK}.255 \
        dev ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} || exit
    ip link set ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} up || exit
}

get_bridge_dev() {
    local name=$1
    local BRIDGE_DEV=$(virsh net-info ${name} | grep Bridge: | awk '{print $2}')
    if [[ $? -ne 0 ]]; then
        echo "can not lookup bridge device"
        exit 1
    fi
    echo ${BRIDGE_DEV}
}

remove_admin() {
    if $(virsh dominfo ${1}-admin > /dev/null); then
        virsh destroy ${1}-admin || true
        local s
        for s in $(virsh snapshot-list ${1}-admin | tail -n+3 | awk '{print $1}'); do
            virsh snapshot-delete ${1}-admin \
                --snapshotname ${s} || true
        done
        virsh undefine ${1}-admin --managed-save || exit
    fi

    if $(virsh vol-info ${1}-admin.qcow2 --pool ${pool} > /dev/null); then
        virsh vol-delete ${1}-admin.qcow2 --pool ${pool} || exit
    fi
}

remove_node() {
    if $(virsh dominfo ${1}-node-${2} > /dev/null); then
        virsh destroy ${1}-node-${2} || true
        local s
        for s in $(virsh snapshot-list ${1}-node-${2} | tail -n+3 | awk '{print $1}'); do
            virsh snapshot-delete ${1}-node-${2} \
                --snapshotname ${s}
        done
        virsh undefine ${1}-node-${2} --managed-save || exit
    fi

    local i
    for i in $(seq 2); do
        if $(virsh vol-info ${1}-node-${2}-${i}.qcow2 --pool ${pool} > /dev/null); then
            virsh vol-delete ${1}-node-${2}-${i}.qcow2 --pool ${pool} || exit
        fi
    done
}

start_admin() {
    virsh start ${cloud}-admin
    if $(virsh domstate ${cloud}-admin | grep --quiet paused); then
        virsh resume ${cloud}-admin
    fi
    wait_for_ssh ${cloud}-admin
}

start_nodes() {
    local i
    for i in $(seq ${NODES}); do
        virsh start ${cloud}-node-${i}
        if $(virsh domstate ${cloud}-node-${i} | grep --quiet paused); then
            virsh resume ${cloud}-node-${i}
        fi
    done
}

ntp_proposal() {
    on_admin "cat > ntp.yml" <<EOF
---
proposals:
- barclamp: ntp
  attributes:
    external_servers:
    - ${ADMIN_NETWORK}.1
    - 0.pool.ntp.org
    - 1.pool.ntp.org
    - 2.pool.ntp.org
    - 3.pool.ntp.org
  deployment:
    elements:
      ntp-server:
      - ${cloud}-admin.cloud.local
EOF
    on_admin "crowbar_batch import ntp.yml"
    on_admin "crowbarctl proposal commit ntp default"
}

database_proposal() {
    on_admin "cat > database.yml" <<EOF
---
proposals:
- barclamp: database
  attributes:
  deployment:
    elements:
      database-server:
      - "@@controller@@"
EOF
    on_admin "crowbar_batch import database.yml"
    on_admin "crowbarctl proposal commit database default"
}

rabbitmq_proposal() {
    on_admin "cat > rabbitmq.yml" <<EOF
---
proposals:
- barclamp: rabbitmq
  attributes:
  deployment:
    elements:
      rabbitmq-server:
      - "@@controller@@"
EOF
    on_admin "crowbar_batch import rabbitmq.yml"
    on_admin "crowbarctl proposal commit rabbitmq default"
}

keystone_proposal() {
    on_admin "cat > keystone.yml" <<EOF
---
proposals:
- barclamp: keystone
  attributes:
  deployment:
    elements:
      keystone-server:
      - "@@controller@@"
EOF
    on_admin "crowbar_batch import keystone.yml"
    on_admin "crowbarctl proposal commit keystone default"
}

glance_proposal() {
    on_admin "cat > glance.yml" <<EOF
---
proposals:
- barclamp: glance
  attributes:
  deployment:
    elements:
      glance-server:
      - "@@controller@@"
EOF
    on_admin "crowbar_batch import glance.yml"
    on_admin "crowbarctl proposal commit glance default"
}

cinder_proposal() {
    on_admin "cat > cinder.yml" <<EOF
---
proposals:
- barclamp: cinder
  attributes:
  deployment:
    elements:
      cinder-controller:
      - "@@controller@@"
      cinder-volume:
      - "@@storage@@"
EOF
    on_admin "crowbar_batch import cinder.yml"
    on_admin "crowbarctl proposal commit cinder default"
}

neutron_proposal() {
    on_admin "cat > neutron.yml" <<EOF
---
proposals:
- barclamp: neutron
  attributes:
    service_password: Av0U2kpUsya4
    rabbitmq_instance: default
    keystone_instance: default
    database_instance: default
    db:
      password: nksIwPCltukz
  deployment:
    elements:
      neutron-server:
      - "@@controller@@"
      neutron-network:
      - "@@network@@"
EOF
    on_admin "crowbar_batch import neutron.yml"
    on_admin "crowbarctl proposal commit neutron default"
}

nova_proposal() {
    on_admin "cat > nova.yml" <<EOF
---
proposals:
- barclamp: nova
  attributes:
    service_password: kyx1NUvT7btB
    neutron_metadata_proxy_shared_secret: cmaQ58uICiYM
    database_instance: default
    rabbitmq_instance: default
    keystone_instance: default
    glance_instance: default
    cinder_instance: default
    neutron_instance: default
    itxt_instance: ''
    ec2-api:
      db:
        password: KlaFOmT5Xfli
    db:
      password: rS6hgfPiNOs8
    api_db:
      password: s1WUui6Y5Sck
  deployment:
    elements:
      nova-controller:
      - "@@controller@@"
      nova-compute-kvm:
      - "@@compute-1@@"
      - "@@compute-2@@"
      nova-compute-qemu: []
      nova-compute-xen: []
EOF
    on_admin "crowbar_batch import nova.yml"
    on_admin "crowbarctl proposal commit nova default"
}

horizon_proposal() {
    on_admin "cat > horizon.yml" <<EOF
---
proposals:
- barclamp: horizon
  attributes:
    keystone_instance: default
    database_instance: default
    db:
      password: FdSNXkmeQpk9
  deployment:
    elements:
      horizon-server:
      - "@@controller@@"
EOF
    on_admin "crowbar_batch import horizon.yml"
    on_admin "crowbarctl proposal commit horizon default"
}

heat_proposal() {
    on_admin "cat > heat.yml" <<EOF
---
proposals:
- barclamp: heat
  attributes:
    rabbitmq_instance: default
    database_instance: default
    stack_domain_admin_password: EUNYe4Aqxyyo
    keystone_instance: default
    service_password: 2Cgcq0xamQQu
    auth_encryption_key: QzA8uox8FEtd5QzXjmtP04oSdpAqpu0GGfv3
    db:
      password: jMHEBocXgccR
  deployment:
    elements:
      heat-server:
      - "@@controller@@"
EOF
    on_admin "crowbar_batch import heat.yml"
    on_admin "crowbarctl proposal commit heat default"
}

magnum_proposal() {
    on_admin "cat > magnum.yml" <<EOF
---
proposals:
- barclamp: magnum
  attributes:
    keystone_instance: default
    database_instance: default
    glance_instance: default
    nova_instance: default
    heat_instance: default
    neutron_instance: default
    rabbitmq_instance: default
    service_password: jXzMczBqcQTV
    trustee:
      domain_admin_password: 81pZbToJFIXc
    db:
      password: RrOjwpsx7T5E
  deployment:
    elements:
      magnum-server:
      - "@@controller@@"
EOF
    on_admin "crowbar_batch import magnum.yml"
    on_admin "crowbarctl proposal commit magnum default"
}

mount_disk() {
    local DISKNAME=$1
    local MOUNTPOINT=$(mktemp -d)
    local VOLPATH=$(virsh vol-path --pool ${pool} ${DISKNAME})

    modprobe nbd max_part=8 nbds_max=8 1>&2

    local NBD=nbd2

    umount /dev/${NBD}p2 1>&2

    if $(ls /dev/${NBD}p* > /dev/null); then
        qemu-nbd --disconnect /dev/${NBD} 1>&2 || exit
    fi

    local PID=$(ps auxw | grep qemu-nbd | grep ${NBD} | awk '{print $2}')
    if [[ ${PID} ]]; then
        kill ${PID}
    fi

    if $(ls /dev/${NBD}p* > /dev/null); then
        echo "could not disconnect nbd"
        exit 1
    fi

    local i
    for i in $(seq 120); do
        qemu-nbd --connect /dev/${NBD} "${VOLPATH}" 1>&2
        sleep 2
        if $(ls /dev/${NBD}p* > /dev/null); then
            break
        fi
        qemu-nbd --disconnect /dev/${NBD} 1>&2 || exit

        local PID=$(ps auxw | grep qemu-nbd | grep ${NBD} | awk '{print $2}')
        if [[ ${PID} ]]; then
            kill ${PID}
        fi
    done

    if ! $(ls /dev/${NBD}p* > /dev/null); then
        echo "could not locally mount admin disk"
        exit 1
    fi
    mount /dev/${NBD}p2 ${MOUNTPOINT} 1>&2 || exit
    if ! $(grep --quiet ${NBD}p2 /proc/mounts); then
        echo "mount failed"
        exit 1
    fi

    echo ${MOUNTPOINT}
}

umount_disk() {
    local MOUNTPOINT=$1
    local NBD=nbd2

    umount ${MOUNTPOINT} || exit

    if $(grep --quiet ${NBD} /proc/mounts); then
        echo "umount failed"
        exit 1
    fi

    qemu-nbd --disconnect /dev/${NBD} || exit
    rmdir -v ${MOUNTPOINT}
}

inject_ssh_key() {
    local DISKNAME=$1
    local MOUNTPOINT=$(mount_disk ${DISKNAME})

    local CLOUDHOME
    if [[ ${CLOUDUSER} != root ]]; then
        CLOUDHOME=${MOUNTPOINT}/home/${CLOUDUSER}
    else
        CLOUDHOME=${MOUNTPOINT}/root
    fi

    local SSHDIR=${CLOUDHOME}/.ssh
    mkdir -p ${SSHDIR} || exit
    chmod 700 ${SSHDIR} || exit
    touch ${SSHDIR}/authorized_keys
    if [[ -f "${SSHKEY}" ]]; then
        if ! $(grep --quiet $(awk '{print($2)}' "${SSHKEY}") ${SSHDIR}/authorized_keys); then
            cat >> "${SSHDIR}/authorized_keys" < "${SSHKEY}" || exit
        fi
    fi
    sed -i -e "s/^${CLOUDUSER}.*/${CLOUDUSER} ALL=(ALL) NOPASSWD: ALL/" ${MOUNTPOINT}/etc/sudoers
    if ! $(grep --quiet "^${CLOUDUSER}" ${MOUNTPOINT}/etc/sudoers); then
        cat >> "${MOUNTPOINT}/etc/sudoers" <<EOF
${CLOUDUSER} ALL=(ALL) NOPASSWD: ALL
EOF
    fi

    if [[ ${CLOUDUSER} != root ]]; then
        local USERGROUP=$(grep ${CLOUDUSER} ${MOUNTPOINT}/etc/passwd \
            | awk -F: '{printf("%s:%s\n", $3, $4);}')
        if [[ -z ${USERGROUP} ]]; then
            echo "Could not read user:group information"
            exit
        fi
        chown -R ${USERGROUP} ${CLOUDHOME}/.ssh || exit
    fi

    umount_disk ${MOUNTPOINT}
}

fix_admin_network() {
    local DISKNAME=$1
    local MOUNTPOINT=$(mount_disk ${DISKNAME})

    cat > ${MOUNTPOINT}/etc/sysconfig/network/ifcfg-eth0 <<EOF
BOOTPROTO='static'
IPADDR='${ADMIN_NETWORK}.10/24'
STARTMODE='auto'
EOF
    cat > ${MOUNTPOINT}/etc/sysconfig/network/routes <<EOF
default 10.0.0.1 - eth0
EOF
    echo ${cloud}-admin.cloud.local > ${MOUNTPOINT}/etc/hostname
    cat > ${MOUNTPOINT}/etc/resolv.conf <<EOF
search cloud.local
nameserver ${ADMIN_NETWORK}.1
EOF
    cat >> ${MOUNTPOINT}/etc/hosts <<EOF
${ADMIN_NETWORK}.10 ${cloud}-admin.cloud.local ${cloud}-admin
EOF

    umount_disk ${MOUNTPOINT}
}

crowbar_register_node() {
    cat <<EOF | on_node ${1} tee register.sh
#!/bin/bash

set -x

PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

admin_ip="${ADMIN_NETWORK}.10"

export PATH="\$PATH:/sbin:/usr/sbin/"

for count in \$(seq 100); do
    wget http://\${admin_ip}:8091/suse-12.2/x86_64/crowbar_register || true
    [[ -f crowbar_register ]] && break
    if [ \$count -ge 90 ]; then
        echo "Giving up on fetching crowbar_register..." 1>&2
        false
    fi
    sleep 10
done

while true; do
    zypper repos || break
    zypper --non-interactive removerepo 1
    sleep 2
done
zypper addrepo --refresh http://\${admin_ip}:8091/suse-12.2/x86_64/install SOC7
zypper refresh
zypper update --no-confirm
zypper patch --no-confirm

# To trick crowbar_register check for "screen". It should be safe
# to run without screen here, as crowbar_register won't pull the network
# from eth0 because we patched the network cookbook accordingly.
export STY="dummy"

chmod a+x crowbar_register
./crowbar_register --force --gpg-auto-import-keys --no-gpg-checks

# We don't want to run this again on reboot.
systemctl disable register.service
EOF
    on_node ${1} chmod 755 register.sh
    on_node ${1} ./register.sh
}

inject_crowbar_register() {
    local DISKNAME=$1
    local MOUNTPOINT=$(mount_disk ${DISKNAME})

    cat > ${MOUNTPOINT}/root/register.sh <<EOF
#!/bin/bash

set -x

PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

admin_ip="${ADMIN_NETWORK}.10"

export PATH="\$PATH:/sbin:/usr/sbin/"

for count in \$(seq 100); do
    wget http://\${admin_ip}:8091/suse-12.2/x86_64/crowbar_register || true
    [[ -f crowbar_register ]] && break
    if [ \$count -ge 90 ]; then
        echo "Giving up on fetching crowbar_register..." 1>&2
        false
    fi
    sleep 10
done

while true; do
    zypper repos || break
    zypper --non-interactive removerepo 1
    sleep 2
done
zypper addrepo --refresh http://\${admin_ip}:8091/suse-12.2/x86_64/install SOC7
zypper refresh
zypper update --no-confirm
zypper patch --no-confirm

# To trick crowbar_register check for "screen". It should be safe
# to run without screen here, as crowbar_register won't pull the network
# from eth0 because we patched the network cookbook accordingly.
export STY="dummy"

chmod a+x crowbar_register
./crowbar_register --force --gpg-auto-import-keys --no-gpg-checks

# We don't want to run this again on reboot.
systemctl disable register.service
EOF
    chmod 755 ${MOUNTPOINT}/root/register.sh

    cat > ${MOUNTPOINT}/etc/systemd/system/register.service <<EOF
[Unit]
Description=Register this node

[Service]
Type=oneshot
ExecStart=/usr/bin/sleep 60
ExecStart=/root/register.sh

[Install]
WantedBy=multi-user.target
EOF
    ln -s \
        ../register.service \
        ${MOUNTPOINT}/etc/systemd/system/multi-user.target.wants/register.service

    umount_disk ${MOUNTPOINT}
}

clone_vol() {
    local from_pool=$1
    local from_vol=$2
    local to_pool=$3
    local to_vol=$4

    local TMP=$(mktemp vol-XXXXXX.xml)
    cat > ${TMP} <<EOF
<volume type='file'>
  <name>${to_vol}</name>
  <target>
    <format type='qcow2'/>
  </target>
</volume>
EOF

    virsh vol-create-from ${to_pool} ${TMP} \
        --inputpool ${from_pool} ${from_vol} || exit

    rm -v ${TMP}
}

shutdown_node() {
    local dom=${1}
    virsh shutdown ${dom} || true
    wait_for_domstate ${dom} off
}

shutdown_cluster() {
    local i
    for i in $(seq ${NODES}); do
        shutdown_node ${cloud}-node-${i}
    done
    shutdown_node ${cloud}-admin
}

suspend_cluster() {
    local i
    for i in $(seq ${NODES}); do
        virsh suspend ${cloud}-node-${i}
    done
    virsh suspend ${cloud}-admin
}

resume_cluster() {
    local i
    for i in $(seq ${NODES}); do
        virsh resume ${cloud}-node-${i}
    done
    virsh resume ${cloud}-admin
}
