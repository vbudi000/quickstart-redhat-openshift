#!/bin/bash -e

source ${P}

#Attach to Subscription pool

yum clean all
rm -rf /var/cache/yum
satellite_server=
mkdir /etc/yum.repos.d/disabled
mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/disabled
cat <<EOF > /etc/yum.repos.d/ose.repo
[rhel-7-server-rpms]
name=rhel-7-server-rpms
baseurl=http://${satellite_server}/repos/rhel-7-server-rpms
enabled=1
gpgcheck=0
[rhel-7-server-extras-rpms]
name=rhel-7-server-extras-rpms
baseurl=http://${satellite_server}/repos/rhel-7-server-extras-rpms
enabled=1
gpgcheck=0
[rhel-7-server-ansible-2.6-rpms]
name=rhel-7-server-ansible-2.6-rpms
baseurl=http://${satellite_server}/repos/rhel-7-server-ansible-2.6-rpms
enabled=1
gpgcheck=0
[rhel-7-server-ose-3.11-rpms]
name=rhel-7-server-ose-3.11-rpms
baseurl=http://${satellite_server}/repos/rhel-7-server-ose-3.11-rpms
enabled=1
gpgcheck=0
EOF

