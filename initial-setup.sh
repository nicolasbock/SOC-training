#!/bin/bash

set -x
set -u

: ${volume_size:=400}

zypper --non-interactive install python-xml libvirt libvirt-python qemu-x86 \
    vim vim-data vim-plugin-colorschemes

systemctl enable libvirtd.service
systemctl start libvirtd.service

dd if=/dev/zero of=/mkcloud.volume bs=1G count=0 seek=${volume_size}
losetup -f /mkcloud.volume
pvcreate /dev/loop0
vgcreate cloud /dev/loop0
sed -i \
    -e 's:"a/.*/:"r|/dev/mapper/cloud-|", "r|/dev/cloud/|", "r|/dev/disk/by-id/|", \0:' \
    /etc/lvm/lvm.conf
systemctl restart lvm2-lvmetad.service

mkdir -p ~/cloud.d
cat > ~/cloud.d/cloudrc.host <<EOF
export mkcloudhostid=p
export vcloudname=v${mkcloudhostid}
EOF

mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat >> ~/.ssh/config <<EOF
Host 192.168.*
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
EOF
