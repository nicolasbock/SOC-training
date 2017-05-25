#!/bin/bash
#
# set tw=0

set -e
set -u

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
    ml2_type_drivers:
    - gre
    - vlan
    - vxlan
    ml2_type_drivers_default_provider_network: vxlan
    ml2_type_drivers_default_tenant_network: vxlan
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
    virsh shutdown ${cloud}-admin || true
    for i in $(seq ${NODES}); do
        virsh shutdown ${cloud}-node-${i} || true
    done
    for i in $(seq ${NODES}); do
        wait_for_domstate ${cloud}-node-${i} off
    done
    wait_for_domstate ${cloud}-admin off
    cleanup_networks
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
        ip link set ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} down
        ip link delete ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID}
    fi

    if [[ -n $BRIDGE_DEV ]]; then
        iptables \
            --delete INPUT -i ${BRIDGE_DEV} \
            --destination ${ADMIN_NETWORK}.0/24 \
            --jump ACCEPT || true
    fi

    iptables --table nat --delete POSTROUTING \
        -s ${PUBLIC_NETWORK}.0/24 \
        ! -d ${PUBLIC_NETWORK}.0/24 -j MASQUERADE || true

    # Delete and insert to make sure that rule is the first one.
    iptables \
        --delete FORWARD \
        --destination 192.168.0.0/16 \
        --jump ACCEPT || true

    iptables --delete FORWARD --destination ${PUBLIC_NETWORK}.0/24 \
        --out-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} -m conntrack \
        --ctstate RELATED,ESTABLISHED --jump ACCEPT || true
    iptables --delete FORWARD --source ${PUBLIC_NETWORK}.0/24 \
        --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} --jump ACCEPT || true

    iptables --delete INPUT --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        --protocol udp -m udp --dport 53 --jump ACCEPT || true
    iptables --delete INPUT --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        --protocol tcp -m tcp --dport 53 --jump ACCEPT || true
    iptables --delete INPUT --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        --protocol udp -m udp --dport 67 --jump ACCEPT || true
    iptables --delete INPUT --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        --protocol tcp -m tcp --dport 67 --jump ACCEPT || true

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
    iptables --list FORWARD --verbose --numeric --line-numbers
    iptables --table nat --list POSTROUTING --verbose --numeric --line-numbers
}

cleanup() {
    cleanup_nodes
    cleanup_networks
}

create_networks() {
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

    ip link add link ${BRIDGE_DEV} \
        name ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        type vlan id ${PUBLIC_NETWORK_ID} || exit
    ip addr add ${PUBLIC_NETWORK}.1/24 \
        brd ${PUBLIC_NETWORK}.255 \
        dev ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} || exit
    ip link set ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} up || exit

    # Delete and insert to make sure that rule is the first one.
    iptables \
        --delete FORWARD \
        --destination 192.168.0.0/16 \
        --jump ACCEPT || true

    iptables \
        --insert FORWARD 1 \
        --destination 192.168.0.0/16 \
        --jump ACCEPT

    iptables --insert FORWARD 1 --destination ${PUBLIC_NETWORK}.0/24 \
        --out-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} -m conntrack \
        --ctstate RELATED,ESTABLISHED --jump ACCEPT
    iptables --insert FORWARD 1 --source ${PUBLIC_NETWORK}.0/24 \
        --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} --jump ACCEPT

    iptables --insert INPUT 1 --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        --protocol udp -m udp --dport 53 --jump ACCEPT
    iptables --insert INPUT 1 --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        --protocol tcp -m tcp --dport 53 --jump ACCEPT
    iptables --insert INPUT 1 --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        --protocol udp -m udp --dport 67 --jump ACCEPT
    iptables --insert INPUT 1 --in-interface ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID} \
        --protocol tcp -m tcp --dport 67 --jump ACCEPT

    iptables --table nat --insert POSTROUTING 1 \
        -s ${PUBLIC_NETWORK}.0/24 \
        ! -d ${PUBLIC_NETWORK}.0/24 -j MASQUERADE

    virsh net-dumpxml ${cloud}-admin
    ip -d addr show ${BRIDGE_DEV}
    ip -d addr show ${BRIDGE_DEV}-nic
    ip -d addr show ${BRIDGE_DEV}.${PUBLIC_NETWORK_ID}
    iptables --list INPUT --verbose --numeric --line-numbers
    iptables --list FORWARD --verbose --numeric --line-numbers
    iptables --table nat --list POSTROUTING --verbose --numeric --line-numbers
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
    copy_to_admin screenrc ${CLOUDUSER}@${cloud}-admin:.screenrc || exit
    copy_to_admin start-screen-session.sh ${CLOUDUSER}@${cloud}-admin: || exit
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

    create_networks

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
    create_networks
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
create_networks
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

if [[ $# -eq 0 ]]; then
    help
fi

while [[ $# -gt 0 ]]; do
    ${1}
    shift
done
