# Air-gapped installation

This document describes the air-gapped installation of RedHat OpenShift 3.11 QuickStart in AWS.

The overall process includes:

1. Preparation of air-gapped resources

  - Setting up S3 bucket to host installation artifacts
  - Setting up Docker registry to host installation container images
  - Setting up networking resources in AWS

2. Running the CloudFormation file to deploy OpenShift 3.11

## Setting up S3 bucket

Create an S3 bucket and block public access, you will have to refine the permission later. You must also set the bucket to be accessible as a website. The polcy setting for the S3 bucket should allow access for the airgapped VPC such as:

```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": "*",
            "Action": [
                "s3:GetObject",
                "s3:GetObjectVersion"
            ],
            "Resource": "arn:aws:s3:::ocp311-airgapped/*",
            "Condition": {
                "StringEquals": {
                    "aws:sourceVpc": "vpc-02020c3d47db35497"
                }
            }
        }
    ]
}
```

Collect the following to load into the S3 bucket:

- The yum repository:

  ``` shell
  subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.11-rpms" \
    --enable="rhel-7-server-ansible-2.6-rpms"
  yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
  yum -y install yum-utils createrepo
  mkdir /repos
  for repo in \
    rhel-7-server-rpms \
    rhel-7-server-extras-rpms \
    rhel-7-server-ansible-2.6-rpms \
    rhel-7-server-ose-3.11-rpms \
    rhel-7-fast-datapath-rpms \
    epel
    do
      reposync --gpgcheck -lm --repoid=${repo} --download_path=/repos
      createrepo -v /repos/${repo} -o /repos/${repo}
    done  
  ```
  All files in the `/repos` directory must be loaded into the S3 bucket in `/repos`.

- Mirror of `https://github.com/vbudi000/quickstart-redhat-openshift` and `https://github.vom/vbudi000/quickstart-linux-utilities`

- PIP installation images; as this is airgapped, you must download and stage the python libraries.

  1. Get get-pip.py: `curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py` and uploaded to the bucket

  2. Create the following tar files and uploaded to the bucket; the listing after the filename indicates the requirement file that must be created.
    - awscli.tar.gz
      ```
      boto3
      awscli
      ```
    - pip.tar.gz
      ```
      pip
      wheel
      setuptools
      ```
    - linux/awslogs.tar.gz
      ```
      awscli-cwlogs==1.4.6
      virtualenv
      ```
    - linux/cfn.tar.gz
      ```
      https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz
      ```

  To create the tar files, do the following (req.txt is the content listed after the files above):

  1. `mkdir tmp;pip wheel -r req.txt -w tmp`
  2. `cd tmp; tar -xf ../<fn>.tar.gz *;cd ..; rm -rf tmp`

- Files for quickstart utilities

  - linux/aws-cfn-bootstrap-latest.tar.gz (from https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz)
  - linux/awslogs-agent-setup.py (copy from https://github.com/vbudi000/quickstart-redhat-openshift/scripts/awslogs-agent-setup.py)
  - linux/epel-release-latest-7.noarch.rpm (from https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm)
  - linux/setyum.sh (note change the `satellite_server` parameter)
    ``` bash
    #!/bin/bash -e

    yum clean all
    rm -rf /var/cache/yum
    satellite_server=ocp311-airgapped.s3.amazonaws.com
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
    [rhel-7-fast-datapath-rpms]
    name=rhel-7-fast-datapath-rpms
    baseurl=http://${satellite_server}/repos/rhel-7-fast-datapath-rpms
    enabled=1
    gpgcheck=0
    [epel]
    name=epel
    baseurl=http://${satellite_server}/repos/epel
    enabled=1
    gpgcheck=0
    EOF
    ```

- Docker images tars (see next unit)

- Docker certificate file (`linux/domain.crt` - see next unit)



## Setting up Docker registry

Here I am following the steps in:

- [Disconnected install](https://docs.openshift.com/container-platform/3.11/install/disconnected_install.html)
- [Setting up registry](https://docs.openshift.com/container-platform/4.2/installing/installing_restricted_networks/installing-restricted-networks-preparations.html)

The actual steps:

Preparing a docker registry in a public space to create the repository:

1. Prepare a machine with 30GB disk storage

2. Prepare the directories:

  ```
  mkdir -p /opt/registry/{certs,data}
  ```

3. Install docker

  ```
  yum install -y docker
  ```

4. Create a certificate for the registry to use in `/opt/registry/certs`; for self-signed certificate, use the following steps:

  - Edit `/etc/pki/tls/openssl.cnf` and add in the `[ v3_ca ]` section (change the repo IP):

  ```
  subjectAltName = IP:10.10.20.78
  ```

  - Generate a self-signed certificate:

  ```
  cd /opt/registry/certs
  openssl req -newkey rsa:4096 -nodes -sha256 -keyout domain.key -x509 -days 365 -out domain.crt
  ```

5. Run the registry server:

  ```
  systemctl start docker
  docker run --name registry -p 5000:5000 -v /opt/registry/data:/var/lib/registry -v /opt/registry/certs:/certs -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt      -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key registry  &
  ```

6. Prepare the file `/opt/registry/certs/domain.crt` for importing later in the OpenShift nodes and image load machine. Load the domain.crt file to the S3 bucket.

Now retrieve and load the images (if you have sufficient storage, you can use the same machine)

1. Prepare a machine with more than 60G free disk with access to the target registry. As `root`, copy `/opt/registry/certs/domain.crt` to `/etc/pki/ca-trust/source/anchors/` and run:

  ```
  update-ca-trust
  ```

2. Collect docker images from `registry.redhat.io`

  ```
  docker pull registry.redhat.io/openshift3/apb-base:v3.11.154
  docker pull registry.redhat.io/openshift3/apb-tools:v3.11.154
  docker pull registry.redhat.io/openshift3/automation-broker-apb:v3.11.154
  docker pull registry.redhat.io/openshift3/csi-attacher:v3.11.154
  docker pull registry.redhat.io/openshift3/csi-driver-registrar:v3.11.154
  docker pull registry.redhat.io/openshift3/csi-livenessprobe:v3.11.154
  docker pull registry.redhat.io/openshift3/csi-provisioner:v3.11.154
  docker pull registry.redhat.io/openshift3/grafana:v3.11.154
  docker pull registry.redhat.io/openshift3/local-storage-provisioner:v3.11.154
  docker pull registry.redhat.io/openshift3/manila-provisioner:v3.11.154
  docker pull registry.redhat.io/openshift3/mariadb-apb:v3.11.154
  docker pull registry.redhat.io/openshift3/mediawiki:v3.11.154
  docker pull registry.redhat.io/openshift3/mediawiki-apb:v3.11.154
  docker pull registry.redhat.io/openshift3/mysql-apb:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-ansible-service-broker:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-cli:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-cluster-autoscaler:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-cluster-capacity:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-cluster-monitoring-operator:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-console:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-configmap-reloader:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-control-plane:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-deployer:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-descheduler:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-docker-builder:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-docker-registry:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-efs-provisioner:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-egress-dns-proxy:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-egress-http-proxy:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-egress-router:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-haproxy-router:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-hyperkube:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-hypershift:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-keepalived-ipfailover:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-kube-rbac-proxy:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-kube-state-metrics:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-metrics-server:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-node:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-node-problem-detector:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-operator-lifecycle-manager:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-ovn-kubernetes:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-pod:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-prometheus-config-reloader:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-prometheus-operator:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-recycler:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-service-catalog:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-template-service-broker:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-tests:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-web-console:v3.11.154
  docker pull registry.redhat.io/openshift3/postgresql-apb:v3.11.154
  docker pull registry.redhat.io/openshift3/registry-console:v3.11.154
  docker pull registry.redhat.io/openshift3/snapshot-controller:v3.11.154
  docker pull registry.redhat.io/openshift3/snapshot-provisioner:v3.11.154
  docker pull registry.redhat.io/rhel7/etcd:3.2.22

  docker pull registry.redhat.io/openshift3/ose-efs-provisioner:v3.11.154

  docker pull registry.redhat.io/openshift3/metrics-cassandra:v3.11.154
  docker pull registry.redhat.io/openshift3/metrics-hawkular-metrics:v3.11.154
  docker pull registry.redhat.io/openshift3/metrics-hawkular-openshift-agent:v3.11.154
  docker pull registry.redhat.io/openshift3/metrics-heapster:v3.11.154
  docker pull registry.redhat.io/openshift3/metrics-schema-installer:v3.11.154
  docker pull registry.redhat.io/openshift3/oauth-proxy:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-logging-curator5:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-logging-elasticsearch5:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-logging-eventrouter:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-logging-fluentd:v3.11.154
  docker pull registry.redhat.io/openshift3/ose-logging-kibana5:v3.11.154
  docker pull registry.redhat.io/openshift3/prometheus:v3.11.154
  docker pull registry.redhat.io/openshift3/prometheus-alertmanager:v3.11.154
  docker pull registry.redhat.io/openshift3/prometheus-node-exporter:v3.11.154
  docker pull registry.redhat.io/cloudforms46/cfme-openshift-postgresql
  docker pull registry.redhat.io/cloudforms46/cfme-openshift-memcached
  docker pull registry.redhat.io/cloudforms46/cfme-openshift-app-ui
  docker pull registry.redhat.io/cloudforms46/cfme-openshift-app
  docker pull registry.redhat.io/cloudforms46/cfme-openshift-embedded-ansible
  docker pull registry.redhat.io/cloudforms46/cfme-openshift-httpd
  docker pull registry.redhat.io/cloudforms46/cfme-httpd-configmap-generator
  docker pull registry.redhat.io/rhgs3/rhgs-server-rhel7
  docker pull registry.redhat.io/rhgs3/rhgs-volmanager-rhel7
  docker pull registry.redhat.io/rhgs3/rhgs-gluster-block-prov-rhel7
  docker pull registry.redhat.io/rhgs3/rhgs-s3-server-rhel7

  docker pull registry.redhat.io/jboss-amq-6/amq63-openshift:1.4
  docker pull registry.redhat.io/jboss-datagrid-7/datagrid71-openshift:1.3
  docker pull registry.redhat.io/jboss-datagrid-7/datagrid71-client-openshift:1.0
  docker pull registry.redhat.io/jboss-datavirt-6/datavirt63-openshift:1.4
  docker pull registry.redhat.io/jboss-datavirt-6/datavirt63-driver-openshift:1.1
  docker pull registry.redhat.io/jboss-decisionserver-6/decisionserver64-openshift:v3.11.154
  docker pull registry.redhat.io/jboss-processserver-6/processserver64-openshift:1.6
  docker pull registry.redhat.io/jboss-eap-6/eap64-openshift:1.9
  docker pull registry.redhat.io/jboss-eap-7/eap71-openshift:1.4
  docker pull registry.redhat.io/jboss-webserver-3/webserver31-tomcat7-openshift:1.4
  docker pull registry.redhat.io/jboss-webserver-3/webserver31-tomcat8-openshift:1.4
  docker pull registry.redhat.io/openshift3/jenkins-2-rhel7:v3.11.154
  docker pull registry.redhat.io/openshift3/jenkins-agent-maven-35-rhel7:v3.11.154
  docker pull registry.redhat.io/openshift3/jenkins-agent-nodejs-8-rhel7:v3.11.154
  docker pull registry.redhat.io/openshift3/jenkins-slave-base-rhel7:v3.11.154
  docker pull registry.redhat.io/openshift3/jenkins-slave-maven-rhel7:v3.11.154
  docker pull registry.redhat.io/openshift3/jenkins-slave-nodejs-rhel7:v3.11.154
  docker pull registry.redhat.io/rhscl/mongodb-32-rhel7:3.2
  docker pull registry.redhat.io/rhscl/mysql-57-rhel7:5.7
  docker pull registry.redhat.io/rhscl/perl-524-rhel7:5.24
  docker pull registry.redhat.io/rhscl/php-56-rhel7:5.6
  docker pull registry.redhat.io/rhscl/postgresql-95-rhel7:9.5
  docker pull registry.redhat.io/rhscl/python-35-rhel7:3.5
  docker pull registry.redhat.io/redhat-sso-7/sso70-openshift:1.4
  docker pull registry.redhat.io/rhscl/ruby-24-rhel7:2.4
  docker pull registry.redhat.io/redhat-openjdk-18/openjdk18-openshift:1.7
  docker pull registry.redhat.io/redhat-sso-7/sso71-openshift:1.3
  docker pull registry.redhat.io/rhscl/nodejs-6-rhel7:6
  docker pull registry.redhat.io/rhscl/mariadb-101-rhel7:10.1
  ```

3. Tag the images to the target registry (note the repo here is called `newrepo:5000` it should be changed):

  ```
  docker tag registry.redhat.io/openshift3/apb-base:v3.11.154 newrepo:5000/openshift3/apb-base:v3.11
  docker tag registry.redhat.io/openshift3/apb-base:v3.11.154 newrepo:5000/openshift3/apb-base:v3.11.154
  docker tag registry.redhat.io/openshift3/apb-tools:v3.11.154 newrepo:5000/openshift3/apb-tools:v3.11
  docker tag registry.redhat.io/openshift3/apb-tools:v3.11.154 newrepo:5000/openshift3/apb-tools:v3.11.154
  docker tag registry.redhat.io/openshift3/automation-broker-apb:v3.11.154 newrepo:5000/openshift3/automation-broker-apb:v3.11
  docker tag registry.redhat.io/openshift3/automation-broker-apb:v3.11.154 newrepo:5000/openshift3/automation-broker-apb:v3.11.154
  docker tag registry.redhat.io/openshift3/csi-attacher:v3.11.154 newrepo:5000/openshift3/csi-attacher:v3.11
  docker tag registry.redhat.io/openshift3/csi-attacher:v3.11.154 newrepo:5000/openshift3/csi-attacher:v3.11.154
  docker tag registry.redhat.io/openshift3/csi-driver-registrar:v3.11.154 newrepo:5000/openshift3/csi-driver-registrar:v3.11
  docker tag registry.redhat.io/openshift3/csi-driver-registrar:v3.11.154 newrepo:5000/openshift3/csi-driver-registrar:v3.11.154
  docker tag registry.redhat.io/openshift3/csi-livenessprobe:v3.11.154 newrepo:5000/openshift3/csi-livenessprobe:v3.11
  docker tag registry.redhat.io/openshift3/csi-livenessprobe:v3.11.154 newrepo:5000/openshift3/csi-livenessprobe:v3.11.154
  docker tag registry.redhat.io/openshift3/csi-provisioner:v3.11.154 newrepo:5000/openshift3/csi-provisioner:v3.11
  docker tag registry.redhat.io/openshift3/csi-provisioner:v3.11.154 newrepo:5000/openshift3/csi-provisioner:v3.11.154
  docker tag registry.redhat.io/openshift3/grafana:v3.11.154 newrepo:5000/openshift3/grafana:v3.11
  docker tag registry.redhat.io/openshift3/grafana:v3.11.154 newrepo:5000/openshift3/grafana:v3.11.154
  docker tag registry.redhat.io/openshift3/local-storage-provisioner:v3.11.154 newrepo:5000/openshift3/local-storage-provisioner:v3.11
  docker tag registry.redhat.io/openshift3/local-storage-provisioner:v3.11.154 newrepo:5000/openshift3/local-storage-provisioner:v3.11.154
  docker tag registry.redhat.io/openshift3/manila-provisioner:v3.11.154 newrepo:5000/openshift3/manila-provisioner:v3.11
  docker tag registry.redhat.io/openshift3/manila-provisioner:v3.11.154 newrepo:5000/openshift3/manila-provisioner:v3.11.154
  docker tag registry.redhat.io/openshift3/mariadb-apb:v3.11.154 newrepo:5000/openshift3/mariadb-apb:v3.11
  docker tag registry.redhat.io/openshift3/mariadb-apb:v3.11.154 newrepo:5000/openshift3/mariadb-apb:v3.11.154
  docker tag registry.redhat.io/openshift3/mediawiki:v3.11.154 newrepo:5000/openshift3/mediawiki:v3.11
  docker tag registry.redhat.io/openshift3/mediawiki:v3.11.154 newrepo:5000/openshift3/mediawiki:v3.11.154
  docker tag registry.redhat.io/openshift3/mediawiki-apb:v3.11.154 newrepo:5000/openshift3/mediawiki-apb:v3.11
  docker tag registry.redhat.io/openshift3/mediawiki-apb:v3.11.154 newrepo:5000/openshift3/mediawiki-apb:v3.11.154
  docker tag registry.redhat.io/openshift3/mysql-apb:v3.11.154 newrepo:5000/openshift3/mysql-apb:v3.11
  docker tag registry.redhat.io/openshift3/mysql-apb:v3.11.154 newrepo:5000/openshift3/mysql-apb:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-ansible-service-broker:v3.11.154 newrepo:5000/openshift3/ose-ansible-service-broker:v3.11
  docker tag registry.redhat.io/openshift3/ose-ansible-service-broker:v3.11.154 newrepo:5000/openshift3/ose-ansible-service-broker:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-cli:v3.11.154 newrepo:5000/openshift3/ose-cli:v3.11
  docker tag registry.redhat.io/openshift3/ose-cli:v3.11.154 newrepo:5000/openshift3/ose-cli:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-cluster-autoscaler:v3.11.154 newrepo:5000/openshift3/ose-cluster-autoscaler:v3.11
  docker tag registry.redhat.io/openshift3/ose-cluster-autoscaler:v3.11.154 newrepo:5000/openshift3/ose-cluster-autoscaler:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-cluster-capacity:v3.11.154 newrepo:5000/openshift3/ose-cluster-capacity:v3.11
  docker tag registry.redhat.io/openshift3/ose-cluster-capacity:v3.11.154 newrepo:5000/openshift3/ose-cluster-capacity:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-cluster-monitoring-operator:v3.11.154 newrepo:5000/openshift3/ose-cluster-monitoring-operator:v3.11
  docker tag registry.redhat.io/openshift3/ose-cluster-monitoring-operator:v3.11.154 newrepo:5000/openshift3/ose-cluster-monitoring-operator:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-console:v3.11.154 newrepo:5000/openshift3/ose-console:v3.11
  docker tag registry.redhat.io/openshift3/ose-console:v3.11.154 newrepo:5000/openshift3/ose-console:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-configmap-reloader:v3.11.154 newrepo:5000/openshift3/ose-configmap-reloader:v3.11
  docker tag registry.redhat.io/openshift3/ose-configmap-reloader:v3.11.154 newrepo:5000/openshift3/ose-configmap-reloader:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-control-plane:v3.11.154 newrepo:5000/openshift3/ose-control-plane:v3.11
  docker tag registry.redhat.io/openshift3/ose-control-plane:v3.11.154 newrepo:5000/openshift3/ose-control-plane:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-deployer:v3.11.154 newrepo:5000/openshift3/ose-deployer:v3.11
  docker tag registry.redhat.io/openshift3/ose-deployer:v3.11.154 newrepo:5000/openshift3/ose-deployer:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-descheduler:v3.11.154 newrepo:5000/openshift3/ose-descheduler:v3.11
  docker tag registry.redhat.io/openshift3/ose-descheduler:v3.11.154 newrepo:5000/openshift3/ose-descheduler:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-docker-builder:v3.11.154 newrepo:5000/openshift3/ose-docker-builder:v3.11
  docker tag registry.redhat.io/openshift3/ose-docker-builder:v3.11.154 newrepo:5000/openshift3/ose-docker-builder:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-docker-registry:v3.11.154 newrepo:5000/openshift3/ose-docker-registry:v3.11
  docker tag registry.redhat.io/openshift3/ose-docker-registry:v3.11.154 newrepo:5000/openshift3/ose-docker-registry:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-efs-provisioner:v3.11.154 newrepo:5000/openshift3/ose-efs-provisioner:v3.11
  docker tag registry.redhat.io/openshift3/ose-efs-provisioner:v3.11.154 newrepo:5000/openshift3/ose-efs-provisioner:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-egress-dns-proxy:v3.11.154 newrepo:5000/openshift3/ose-egress-dns-proxy:v3.11
  docker tag registry.redhat.io/openshift3/ose-egress-dns-proxy:v3.11.154 newrepo:5000/openshift3/ose-egress-dns-proxy:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-egress-http-proxy:v3.11.154 newrepo:5000/openshift3/ose-egress-http-proxy:v3.11
  docker tag registry.redhat.io/openshift3/ose-egress-http-proxy:v3.11.154 newrepo:5000/openshift3/ose-egress-http-proxy:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-egress-router:v3.11.154 newrepo:5000/openshift3/ose-egress-router:v3.11
  docker tag registry.redhat.io/openshift3/ose-egress-router:v3.11.154 newrepo:5000/openshift3/ose-egress-router:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-haproxy-router:v3.11.154 newrepo:5000/openshift3/ose-haproxy-router:v3.11
  docker tag registry.redhat.io/openshift3/ose-haproxy-router:v3.11.154 newrepo:5000/openshift3/ose-haproxy-router:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-hyperkube:v3.11.154 newrepo:5000/openshift3/ose-hyperkube:v3.11
  docker tag registry.redhat.io/openshift3/ose-hyperkube:v3.11.154 newrepo:5000/openshift3/ose-hyperkube:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-hypershift:v3.11.154 newrepo:5000/openshift3/ose-hypershift:v3.11
  docker tag registry.redhat.io/openshift3/ose-hypershift:v3.11.154 newrepo:5000/openshift3/ose-hypershift:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-keepalived-ipfailover:v3.11.154 newrepo:5000/openshift3/ose-keepalived-ipfailover:v3.11
  docker tag registry.redhat.io/openshift3/ose-keepalived-ipfailover:v3.11.154 newrepo:5000/openshift3/ose-keepalived-ipfailover:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-kube-rbac-proxy:v3.11.154 newrepo:5000/openshift3/ose-kube-rbac-proxy:v3.11
  docker tag registry.redhat.io/openshift3/ose-kube-rbac-proxy:v3.11.154 newrepo:5000/openshift3/ose-kube-rbac-proxy:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-kube-state-metrics:v3.11.154 newrepo:5000/openshift3/ose-kube-state-metrics:v3.11
  docker tag registry.redhat.io/openshift3/ose-kube-state-metrics:v3.11.154 newrepo:5000/openshift3/ose-kube-state-metrics:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-metrics-server:v3.11.154 newrepo:5000/openshift3/ose-metrics-server:v3.11
  docker tag registry.redhat.io/openshift3/ose-metrics-server:v3.11.154 newrepo:5000/openshift3/ose-metrics-server:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-node:v3.11.154 newrepo:5000/openshift3/ose-node:v3.11
  docker tag registry.redhat.io/openshift3/ose-node:v3.11.154 newrepo:5000/openshift3/ose-node:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-node-problem-detector:v3.11.154 newrepo:5000/openshift3/ose-node-problem-detector:v3.11
  docker tag registry.redhat.io/openshift3/ose-node-problem-detector:v3.11.154 newrepo:5000/openshift3/ose-node-problem-detector:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-operator-lifecycle-manager:v3.11.154 newrepo:5000/openshift3/ose-operator-lifecycle-manager:v3.11
  docker tag registry.redhat.io/openshift3/ose-operator-lifecycle-manager:v3.11.154 newrepo:5000/openshift3/ose-operator-lifecycle-manager:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-ovn-kubernetes:v3.11.154 newrepo:5000/openshift3/ose-ovn-kubernetes:v3.11
  docker tag registry.redhat.io/openshift3/ose-ovn-kubernetes:v3.11.154 newrepo:5000/openshift3/ose-ovn-kubernetes:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-pod:v3.11.154 newrepo:5000/openshift3/ose-pod:v3.11
  docker tag registry.redhat.io/openshift3/ose-pod:v3.11.154 newrepo:5000/openshift3/ose-pod:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-prometheus-config-reloader:v3.11.154 newrepo:5000/openshift3/ose-prometheus-config-reloader:v3.11
  docker tag registry.redhat.io/openshift3/ose-prometheus-config-reloader:v3.11.154 newrepo:5000/openshift3/ose-prometheus-config-reloader:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-prometheus-operator:v3.11.154 newrepo:5000/openshift3/ose-prometheus-operator:v3.11
  docker tag registry.redhat.io/openshift3/ose-prometheus-operator:v3.11.154 newrepo:5000/openshift3/ose-prometheus-operator:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-recycler:v3.11.154 newrepo:5000/openshift3/ose-recycler:v3.11
  docker tag registry.redhat.io/openshift3/ose-recycler:v3.11.154 newrepo:5000/openshift3/ose-recycler:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-service-catalog:v3.11.154 newrepo:5000/openshift3/ose-service-catalog:v3.11
  docker tag registry.redhat.io/openshift3/ose-service-catalog:v3.11.154 newrepo:5000/openshift3/ose-service-catalog:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-template-service-broker:v3.11.154 newrepo:5000/openshift3/ose-template-service-broker:v3.11
  docker tag registry.redhat.io/openshift3/ose-template-service-broker:v3.11.154 newrepo:5000/openshift3/ose-template-service-broker:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-tests:v3.11.154 newrepo:5000/openshift3/ose-tests:v3.11
  docker tag registry.redhat.io/openshift3/ose-tests:v3.11.154 newrepo:5000/openshift3/ose-tests:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-web-console:v3.11.154 newrepo:5000/openshift3/ose-web-console:v3.11
  docker tag registry.redhat.io/openshift3/ose-web-console:v3.11.154 newrepo:5000/openshift3/ose-web-console:v3.11.154
  docker tag registry.redhat.io/openshift3/postgresql-apb:v3.11.154 newrepo:5000/openshift3/postgresql-apb:v3.11
  docker tag registry.redhat.io/openshift3/postgresql-apb:v3.11.154 newrepo:5000/openshift3/postgresql-apb:v3.11.154
  docker tag registry.redhat.io/openshift3/registry-console:v3.11.154 newrepo:5000/openshift3/registry-console:v3.11
  docker tag registry.redhat.io/openshift3/registry-console:v3.11.154 newrepo:5000/openshift3/registry-console:v3.11.154
  docker tag registry.redhat.io/openshift3/snapshot-controller:v3.11.154 newrepo:5000/openshift3/snapshot-controller:v3.11
  docker tag registry.redhat.io/openshift3/snapshot-controller:v3.11.154 newrepo:5000/openshift3/snapshot-controller:v3.11.154
  docker tag registry.redhat.io/openshift3/snapshot-provisioner:v3.11.154 newrepo:5000/openshift3/snapshot-provisioner:v3.11
  docker tag registry.redhat.io/openshift3/snapshot-provisioner:v3.11.154 newrepo:5000/openshift3/snapshot-provisioner:v3.11.154
  docker tag registry.redhat.io/rhel7/etcd:3.2.22 newrepo:5000/rhel7/etcd:3.2.22
  docker tag registry.redhat.io/openshift3/ose-efs-provisioner:v3.11.154 newrepo:5000/openshift3/ose-efs-provisioner:v3.11
  docker tag registry.redhat.io/openshift3/ose-efs-provisioner:v3.11.154 newrepo:5000/openshift3/ose-efs-provisioner:v3.11.154
  docker tag registry.redhat.io/openshift3/metrics-cassandra:v3.11.154 newrepo:5000/openshift3/metrics-cassandra:v3.11
  docker tag registry.redhat.io/openshift3/metrics-cassandra:v3.11.154 newrepo:5000/openshift3/metrics-cassandra:v3.11.154
  docker tag registry.redhat.io/openshift3/metrics-hawkular-metrics:v3.11.154 newrepo:5000/openshift3/metrics-hawkular-metrics:v3.11
  docker tag registry.redhat.io/openshift3/metrics-hawkular-metrics:v3.11.154 newrepo:5000/openshift3/metrics-hawkular-metrics:v3.11.154
  docker tag registry.redhat.io/openshift3/metrics-hawkular-openshift-agent:v3.11.154 newrepo:5000/openshift3/metrics-hawkular-openshift-agent:v3.11
  docker tag registry.redhat.io/openshift3/metrics-hawkular-openshift-agent:v3.11.154 newrepo:5000/openshift3/metrics-hawkular-openshift-agent:v3.11.154
  docker tag registry.redhat.io/openshift3/metrics-heapster:v3.11.154 newrepo:5000/openshift3/metrics-heapster:v3.11
  docker tag registry.redhat.io/openshift3/metrics-heapster:v3.11.154 newrepo:5000/openshift3/metrics-heapster:v3.11.154
  docker tag registry.redhat.io/openshift3/metrics-schema-installer:v3.11.154 newrepo:5000/openshift3/metrics-schema-installer:v3.11
  docker tag registry.redhat.io/openshift3/metrics-schema-installer:v3.11.154 newrepo:5000/openshift3/metrics-schema-installer:v3.11.154
  docker tag registry.redhat.io/openshift3/oauth-proxy:v3.11.154 newrepo:5000/openshift3/oauth-proxy:v3.11
  docker tag registry.redhat.io/openshift3/oauth-proxy:v3.11.154 newrepo:5000/openshift3/oauth-proxy:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-logging-curator5:v3.11.154 newrepo:5000/openshift3/ose-logging-curator5:v3.11
  docker tag registry.redhat.io/openshift3/ose-logging-curator5:v3.11.154 newrepo:5000/openshift3/ose-logging-curator5:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-logging-elasticsearch5:v3.11.154 newrepo:5000/openshift3/ose-logging-elasticsearch5:v3.11
  docker tag registry.redhat.io/openshift3/ose-logging-elasticsearch5:v3.11.154 newrepo:5000/openshift3/ose-logging-elasticsearch5:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-logging-eventrouter:v3.11.154 newrepo:5000/openshift3/ose-logging-eventrouter:v3.11
  docker tag registry.redhat.io/openshift3/ose-logging-eventrouter:v3.11.154 newrepo:5000/openshift3/ose-logging-eventrouter:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-logging-fluentd:v3.11.154 newrepo:5000/openshift3/ose-logging-fluentd:v3.11
  docker tag registry.redhat.io/openshift3/ose-logging-fluentd:v3.11.154 newrepo:5000/openshift3/ose-logging-fluentd:v3.11.154
  docker tag registry.redhat.io/openshift3/ose-logging-kibana5:v3.11.154 newrepo:5000/openshift3/ose-logging-kibana5:v3.11
  docker tag registry.redhat.io/openshift3/ose-logging-kibana5:v3.11.154 newrepo:5000/openshift3/ose-logging-kibana5:v3.11.154
  docker tag registry.redhat.io/openshift3/prometheus:v3.11.154 newrepo:5000/openshift3/prometheus:v3.11
  docker tag registry.redhat.io/openshift3/prometheus:v3.11.154 newrepo:5000/openshift3/prometheus:v3.11.154
  docker tag registry.redhat.io/openshift3/prometheus-alertmanager:v3.11.154 newrepo:5000/openshift3/prometheus-alertmanager:v3.11
  docker tag registry.redhat.io/openshift3/prometheus-alertmanager:v3.11.154 newrepo:5000/openshift3/prometheus-alertmanager:v3.11.154
  docker tag registry.redhat.io/openshift3/prometheus-node-exporter:v3.11.154 newrepo:5000/openshift3/prometheus-node-exporter:v3.11
  docker tag registry.redhat.io/openshift3/prometheus-node-exporter:v3.11.154 newrepo:5000/openshift3/prometheus-node-exporter:v3.11.154
  docker tag registry.redhat.io/cloudforms46/cfme-openshift-postgresql newrepo:5000/cloudforms46/cfme-openshift-postgresql
  docker tag registry.redhat.io/cloudforms46/cfme-openshift-memcached newrepo:5000/cloudforms46/cfme-openshift-memcached
  docker tag registry.redhat.io/cloudforms46/cfme-openshift-app-ui newrepo:5000/cloudforms46/cfme-openshift-app-ui
  docker tag registry.redhat.io/cloudforms46/cfme-openshift-app newrepo:5000/cloudforms46/cfme-openshift-app
  docker tag registry.redhat.io/cloudforms46/cfme-openshift-embedded-ansible newrepo:5000/cloudforms46/cfme-openshift-embedded-ansible
  docker tag registry.redhat.io/cloudforms46/cfme-openshift-httpd newrepo:5000/cloudforms46/cfme-openshift-httpd
  docker tag registry.redhat.io/cloudforms46/cfme-httpd-configmap-generator newrepo:5000/cloudforms46/cfme-httpd-configmap-generator
  docker tag registry.redhat.io/rhgs3/rhgs-server-rhel7 newrepo:5000/rhgs3/rhgs-server-rhel7
  docker tag registry.redhat.io/rhgs3/rhgs-volmanager-rhel7 newrepo:5000/rhgs3/rhgs-volmanager-rhel7
  docker tag registry.redhat.io/rhgs3/rhgs-gluster-block-prov-rhel7 newrepo:5000/rhgs3/rhgs-gluster-block-prov-rhel7
  docker tag registry.redhat.io/rhgs3/rhgs-s3-server-rhel7 newrepo:5000/rhgs3/rhgs-s3-server-rhel7
  docker tag registry.redhat.io/jboss-amq-6/amq63-openshift:1.4 newrepo:5000/jboss-amq-6/amq63-openshift:1.4
  docker tag registry.redhat.io/jboss-datagrid-7/datagrid71-openshift:1.3 newrepo:5000/jboss-datagrid-7/datagrid71-openshift:1.3
  docker tag registry.redhat.io/jboss-datagrid-7/datagrid71-client-openshift:1.0 newrepo:5000/jboss-datagrid-7/datagrid71-client-openshift:1.0
  docker tag registry.redhat.io/jboss-datavirt-6/datavirt63-openshift:1.4 newrepo:5000/jboss-datavirt-6/datavirt63-openshift:1.4
  docker tag registry.redhat.io/jboss-datavirt-6/datavirt63-driver-openshift:1.1 newrepo:5000/jboss-datavirt-6/datavirt63-driver-openshift:1.1
  docker tag registry.redhat.io/jboss-decisionserver-6/decisionserver64-openshift:v3.11.154 newrepo:5000/jboss-decisionserver-6/decisionserver64-openshift:v3.11
  docker tag registry.redhat.io/jboss-decisionserver-6/decisionserver64-openshift:v3.11.154 newrepo:5000/jboss-decisionserver-6/decisionserver64-openshift:v3.11.154
  docker tag registry.redhat.io/jboss-processserver-6/processserver64-openshift:1.6 newrepo:5000/jboss-processserver-6/processserver64-openshift:1.6
  docker tag registry.redhat.io/jboss-eap-6/eap64-openshift:1.9 newrepo:5000/jboss-eap-6/eap64-openshift:1.9
  docker tag registry.redhat.io/jboss-eap-7/eap71-openshift:1.4 newrepo:5000/jboss-eap-7/eap71-openshift:1.4
  docker tag registry.redhat.io/jboss-webserver-3/webserver31-tomcat7-openshift:1.4 newrepo:5000/jboss-webserver-3/webserver31-tomcat7-openshift:1.4
  docker tag registry.redhat.io/jboss-webserver-3/webserver31-tomcat8-openshift:1.4 newrepo:5000/jboss-webserver-3/webserver31-tomcat8-openshift:1.4
  docker tag registry.redhat.io/openshift3/jenkins-2-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-2-rhel7:v3.11
  docker tag registry.redhat.io/openshift3/jenkins-2-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-2-rhel7:v3.11.154
  docker tag registry.redhat.io/openshift3/jenkins-agent-maven-35-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-agent-maven-35-rhel7:v3.11
  docker tag registry.redhat.io/openshift3/jenkins-agent-maven-35-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-agent-maven-35-rhel7:v3.11.154
  docker tag registry.redhat.io/openshift3/jenkins-agent-nodejs-8-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-agent-nodejs-8-rhel7:v3.11
  docker tag registry.redhat.io/openshift3/jenkins-agent-nodejs-8-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-agent-nodejs-8-rhel7:v3.11.154
  docker tag registry.redhat.io/openshift3/jenkins-slave-base-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-slave-base-rhel7:v3.11
  docker tag registry.redhat.io/openshift3/jenkins-slave-base-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-slave-base-rhel7:v3.11.154
  docker tag registry.redhat.io/openshift3/jenkins-slave-maven-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-slave-maven-rhel7:v3.11
  docker tag registry.redhat.io/openshift3/jenkins-slave-maven-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-slave-maven-rhel7:v3.11.154
  docker tag registry.redhat.io/openshift3/jenkins-slave-nodejs-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-slave-nodejs-rhel7:v3.11
  docker tag registry.redhat.io/openshift3/jenkins-slave-nodejs-rhel7:v3.11.154 newrepo:5000/openshift3/jenkins-slave-nodejs-rhel7:v3.11.154
  docker tag registry.redhat.io/rhscl/mongodb-32-rhel7:3.2 newrepo:5000/rhscl/mongodb-32-rhel7:3.2
  docker tag registry.redhat.io/rhscl/mysql-57-rhel7:5.7 newrepo:5000/rhscl/mysql-57-rhel7:5.7
  docker tag registry.redhat.io/rhscl/perl-524-rhel7:5.24 newrepo:5000/rhscl/perl-524-rhel7:5.24
  docker tag registry.redhat.io/rhscl/php-56-rhel7:5.6 newrepo:5000/rhscl/php-56-rhel7:5.6
  docker tag registry.redhat.io/rhscl/postgresql-95-rhel7:9.5 newrepo:5000/rhscl/postgresql-95-rhel7:9.5
  docker tag registry.redhat.io/rhscl/python-35-rhel7:3.5 newrepo:5000/rhscl/python-35-rhel7:3.5
  docker tag registry.redhat.io/redhat-sso-7/sso70-openshift:1.4 newrepo:5000/redhat-sso-7/sso70-openshift:1.4
  docker tag registry.redhat.io/rhscl/ruby-24-rhel7:2.4 newrepo:5000/rhscl/ruby-24-rhel7:2.4
  docker tag registry.redhat.io/redhat-openjdk-18/openjdk18-openshift:1.7 newrepo:5000/redhat-openjdk-18/openjdk18-openshift:1.7
  docker tag registry.redhat.io/redhat-sso-7/sso71-openshift:1.3 newrepo:5000/redhat-sso-7/sso71-openshift:1.3
  docker tag registry.redhat.io/rhscl/nodejs-6-rhel7:6 newrepo:5000/rhscl/nodejs-6-rhel7:6
  docker tag registry.redhat.io/rhscl/mariadb-101-rhel7:10.1 newrepo:5000/rhscl/mariadb-101-rhel7:10.1
  ```

4. Set up access to the target registry:

  ```
  cp domain.crt /etc/pki/ca-trust/source/anchors/
  update-ca-trust
  systemctl restart docker
  docker login newrepo:5000 -u <user> -p <password>
  ```

5. Push out to store the images (again, note to change `newrepo:5000`):

  ```
  docker push newrepo:5000/openshift3/apb-base:v3.11
  docker push newrepo:5000/openshift3/apb-base:v3.11.154
  docker push newrepo:5000/openshift3/apb-tools:v3.11
  docker push newrepo:5000/openshift3/apb-tools:v3.11.154
  docker push newrepo:5000/openshift3/automation-broker-apb:v3.11
  docker push newrepo:5000/openshift3/automation-broker-apb:v3.11.154
  docker push newrepo:5000/openshift3/csi-attacher:v3.11
  docker push newrepo:5000/openshift3/csi-attacher:v3.11.154
  docker push newrepo:5000/openshift3/csi-driver-registrar:v3.11
  docker push newrepo:5000/openshift3/csi-driver-registrar:v3.11.154
  docker push newrepo:5000/openshift3/csi-livenessprobe:v3.11
  docker push newrepo:5000/openshift3/csi-livenessprobe:v3.11.154
  docker push newrepo:5000/openshift3/csi-provisioner:v3.11
  docker push newrepo:5000/openshift3/csi-provisioner:v3.11.154
  docker push newrepo:5000/openshift3/grafana:v3.11
  docker push newrepo:5000/openshift3/grafana:v3.11.154
  docker push newrepo:5000/openshift3/local-storage-provisioner:v3.11
  docker push newrepo:5000/openshift3/local-storage-provisioner:v3.11.154
  docker push newrepo:5000/openshift3/manila-provisioner:v3.11
  docker push newrepo:5000/openshift3/manila-provisioner:v3.11.154
  docker push newrepo:5000/openshift3/mariadb-apb:v3.11
  docker push newrepo:5000/openshift3/mariadb-apb:v3.11.154
  docker push newrepo:5000/openshift3/mediawiki:v3.11
  docker push newrepo:5000/openshift3/mediawiki:v3.11.154
  docker push newrepo:5000/openshift3/mediawiki-apb:v3.11
  docker push newrepo:5000/openshift3/mediawiki-apb:v3.11.154
  docker push newrepo:5000/openshift3/mysql-apb:v3.11
  docker push newrepo:5000/openshift3/mysql-apb:v3.11.154
  docker push newrepo:5000/openshift3/ose-ansible-service-broker:v3.11
  docker push newrepo:5000/openshift3/ose-ansible-service-broker:v3.11.154
  docker push newrepo:5000/openshift3/ose-cli:v3.11
  docker push newrepo:5000/openshift3/ose-cli:v3.11.154
  docker push newrepo:5000/openshift3/ose-cluster-autoscaler:v3.11
  docker push newrepo:5000/openshift3/ose-cluster-autoscaler:v3.11.154
  docker push newrepo:5000/openshift3/ose-cluster-capacity:v3.11
  docker push newrepo:5000/openshift3/ose-cluster-capacity:v3.11.154
  docker push newrepo:5000/openshift3/ose-cluster-monitoring-operator:v3.11
  docker push newrepo:5000/openshift3/ose-cluster-monitoring-operator:v3.11.154
  docker push newrepo:5000/openshift3/ose-console:v3.11
  docker push newrepo:5000/openshift3/ose-console:v3.11.154
  docker push newrepo:5000/openshift3/ose-configmap-reloader:v3.11
  docker push newrepo:5000/openshift3/ose-configmap-reloader:v3.11.154
  docker push newrepo:5000/openshift3/ose-control-plane:v3.11
  docker push newrepo:5000/openshift3/ose-control-plane:v3.11.154
  docker push newrepo:5000/openshift3/ose-deployer:v3.11
  docker push newrepo:5000/openshift3/ose-deployer:v3.11.154
  docker push newrepo:5000/openshift3/ose-descheduler:v3.11
  docker push newrepo:5000/openshift3/ose-descheduler:v3.11.154
  docker push newrepo:5000/openshift3/ose-docker-builder:v3.11
  docker push newrepo:5000/openshift3/ose-docker-builder:v3.11.154
  docker push newrepo:5000/openshift3/ose-docker-registry:v3.11
  docker push newrepo:5000/openshift3/ose-docker-registry:v3.11.154
  docker push newrepo:5000/openshift3/ose-efs-provisioner:v3.11
  docker push newrepo:5000/openshift3/ose-efs-provisioner:v3.11.154
  docker push newrepo:5000/openshift3/ose-egress-dns-proxy:v3.11
  docker push newrepo:5000/openshift3/ose-egress-dns-proxy:v3.11.154
  docker push newrepo:5000/openshift3/ose-egress-http-proxy:v3.11
  docker push newrepo:5000/openshift3/ose-egress-http-proxy:v3.11.154
  docker push newrepo:5000/openshift3/ose-egress-router:v3.11
  docker push newrepo:5000/openshift3/ose-egress-router:v3.11.154
  docker push newrepo:5000/openshift3/ose-haproxy-router:v3.11
  docker push newrepo:5000/openshift3/ose-haproxy-router:v3.11.154
  docker push newrepo:5000/openshift3/ose-hyperkube:v3.11
  docker push newrepo:5000/openshift3/ose-hyperkube:v3.11.154
  docker push newrepo:5000/openshift3/ose-hypershift:v3.11
  docker push newrepo:5000/openshift3/ose-hypershift:v3.11.154
  docker push newrepo:5000/openshift3/ose-keepalived-ipfailover:v3.11
  docker push newrepo:5000/openshift3/ose-keepalived-ipfailover:v3.11.154
  docker push newrepo:5000/openshift3/ose-kube-rbac-proxy:v3.11
  docker push newrepo:5000/openshift3/ose-kube-rbac-proxy:v3.11.154
  docker push newrepo:5000/openshift3/ose-kube-state-metrics:v3.11
  docker push newrepo:5000/openshift3/ose-kube-state-metrics:v3.11.154
  docker push newrepo:5000/openshift3/ose-metrics-server:v3.11
  docker push newrepo:5000/openshift3/ose-metrics-server:v3.11.154
  docker push newrepo:5000/openshift3/ose-node:v3.11
  docker push newrepo:5000/openshift3/ose-node:v3.11.154
  docker push newrepo:5000/openshift3/ose-node-problem-detector:v3.11
  docker push newrepo:5000/openshift3/ose-node-problem-detector:v3.11.154
  docker push newrepo:5000/openshift3/ose-operator-lifecycle-manager:v3.11
  docker push newrepo:5000/openshift3/ose-operator-lifecycle-manager:v3.11.154
  docker push newrepo:5000/openshift3/ose-ovn-kubernetes:v3.11
  docker push newrepo:5000/openshift3/ose-ovn-kubernetes:v3.11.154
  docker push newrepo:5000/openshift3/ose-pod:v3.11
  docker push newrepo:5000/openshift3/ose-pod:v3.11.154
  docker push newrepo:5000/openshift3/ose-prometheus-config-reloader:v3.11
  docker push newrepo:5000/openshift3/ose-prometheus-config-reloader:v3.11.154
  docker push newrepo:5000/openshift3/ose-prometheus-operator:v3.11
  docker push newrepo:5000/openshift3/ose-prometheus-operator:v3.11.154
  docker push newrepo:5000/openshift3/ose-recycler:v3.11
  docker push newrepo:5000/openshift3/ose-recycler:v3.11.154
  docker push newrepo:5000/openshift3/ose-service-catalog:v3.11
  docker push newrepo:5000/openshift3/ose-service-catalog:v3.11.154
  docker push newrepo:5000/openshift3/ose-template-service-broker:v3.11
  docker push newrepo:5000/openshift3/ose-template-service-broker:v3.11.154
  docker push newrepo:5000/openshift3/ose-tests:v3.11
  docker push newrepo:5000/openshift3/ose-tests:v3.11.154
  docker push newrepo:5000/openshift3/ose-web-console:v3.11
  docker push newrepo:5000/openshift3/ose-web-console:v3.11.154
  docker push newrepo:5000/openshift3/postgresql-apb:v3.11
  docker push newrepo:5000/openshift3/postgresql-apb:v3.11.154
  docker push newrepo:5000/openshift3/registry-console:v3.11
  docker push newrepo:5000/openshift3/registry-console:v3.11.154
  docker push newrepo:5000/openshift3/snapshot-controller:v3.11
  docker push newrepo:5000/openshift3/snapshot-controller:v3.11.154
  docker push newrepo:5000/openshift3/snapshot-provisioner:v3.11
  docker push newrepo:5000/openshift3/snapshot-provisioner:v3.11.154
  docker push newrepo:5000/rhel7/etcd:3.2.22
  docker push newrepo:5000/openshift3/ose-efs-provisioner:v3.11
  docker push newrepo:5000/openshift3/ose-efs-provisioner:v3.11.154
  docker push newrepo:5000/openshift3/metrics-cassandra:v3.11
  docker push newrepo:5000/openshift3/metrics-cassandra:v3.11.154
  docker push newrepo:5000/openshift3/metrics-hawkular-metrics:v3.11
  docker push newrepo:5000/openshift3/metrics-hawkular-metrics:v3.11.154
  docker push newrepo:5000/openshift3/metrics-hawkular-openshift-agent:v3.11
  docker push newrepo:5000/openshift3/metrics-hawkular-openshift-agent:v3.11.154
  docker push newrepo:5000/openshift3/metrics-heapster:v3.11
  docker push newrepo:5000/openshift3/metrics-heapster:v3.11.154
  docker push newrepo:5000/openshift3/metrics-schema-installer:v3.11
  docker push newrepo:5000/openshift3/metrics-schema-installer:v3.11.154
  docker push newrepo:5000/openshift3/oauth-proxy:v3.11
  docker push newrepo:5000/openshift3/oauth-proxy:v3.11.154
  docker push newrepo:5000/openshift3/ose-logging-curator5:v3.11
  docker push newrepo:5000/openshift3/ose-logging-curator5:v3.11.154
  docker push newrepo:5000/openshift3/ose-logging-elasticsearch5:v3.11
  docker push newrepo:5000/openshift3/ose-logging-elasticsearch5:v3.11.154
  docker push newrepo:5000/openshift3/ose-logging-eventrouter:v3.11
  docker push newrepo:5000/openshift3/ose-logging-eventrouter:v3.11.154
  docker push newrepo:5000/openshift3/ose-logging-fluentd:v3.11
  docker push newrepo:5000/openshift3/ose-logging-fluentd:v3.11.154
  docker push newrepo:5000/openshift3/ose-logging-kibana5:v3.11
  docker push newrepo:5000/openshift3/ose-logging-kibana5:v3.11.154
  docker push newrepo:5000/openshift3/prometheus:v3.11
  docker push newrepo:5000/openshift3/prometheus:v3.11.154
  docker push newrepo:5000/openshift3/prometheus-alertmanager:v3.11
  docker push newrepo:5000/openshift3/prometheus-alertmanager:v3.11.154
  docker push newrepo:5000/openshift3/prometheus-node-exporter:v3.11
  docker push newrepo:5000/openshift3/prometheus-node-exporter:v3.11.154
  docker push newrepo:5000/cloudforms46/cfme-openshift-postgresql
  docker push newrepo:5000/cloudforms46/cfme-openshift-memcached
  docker push newrepo:5000/cloudforms46/cfme-openshift-app-ui
  docker push newrepo:5000/cloudforms46/cfme-openshift-app
  docker push newrepo:5000/cloudforms46/cfme-openshift-embedded-ansible
  docker push newrepo:5000/cloudforms46/cfme-openshift-httpd
  docker push newrepo:5000/cloudforms46/cfme-httpd-configmap-generator
  docker push newrepo:5000/rhgs3/rhgs-server-rhel7
  docker push newrepo:5000/rhgs3/rhgs-volmanager-rhel7
  docker push newrepo:5000/rhgs3/rhgs-gluster-block-prov-rhel7
  docker push newrepo:5000/rhgs3/rhgs-s3-server-rhel7
  docker push newrepo:5000/jboss-amq-6/amq63-openshift:1.4
  docker push newrepo:5000/jboss-datagrid-7/datagrid71-openshift:1.3
  docker push newrepo:5000/jboss-datagrid-7/datagrid71-client-openshift:1.0
  docker push newrepo:5000/jboss-datavirt-6/datavirt63-openshift:1.4
  docker push newrepo:5000/jboss-datavirt-6/datavirt63-driver-openshift:1.1
  docker push newrepo:5000/jboss-decisionserver-6/decisionserver64-openshift:v3.11
  docker push newrepo:5000/jboss-decisionserver-6/decisionserver64-openshift:v3.11.154
  docker push newrepo:5000/jboss-processserver-6/processserver64-openshift:1.6
  docker push newrepo:5000/jboss-eap-6/eap64-openshift:1.9
  docker push newrepo:5000/jboss-eap-7/eap71-openshift:1.4
  docker push newrepo:5000/jboss-webserver-3/webserver31-tomcat7-openshift:1.4
  docker push newrepo:5000/jboss-webserver-3/webserver31-tomcat8-openshift:1.4
  docker push newrepo:5000/openshift3/jenkins-2-rhel7:v3.11
  docker push newrepo:5000/openshift3/jenkins-2-rhel7:v3.11.154
  docker push newrepo:5000/openshift3/jenkins-agent-maven-35-rhel7:v3.11
  docker push newrepo:5000/openshift3/jenkins-agent-maven-35-rhel7:v3.11.154
  docker push newrepo:5000/openshift3/jenkins-agent-nodejs-8-rhel7:v3.11
  docker push newrepo:5000/openshift3/jenkins-agent-nodejs-8-rhel7:v3.11.154
  docker push newrepo:5000/openshift3/jenkins-slave-base-rhel7:v3.11
  docker push newrepo:5000/openshift3/jenkins-slave-base-rhel7:v3.11.154
  docker push newrepo:5000/openshift3/jenkins-slave-maven-rhel7:v3.11
  docker push newrepo:5000/openshift3/jenkins-slave-maven-rhel7:v3.11.154
  docker push newrepo:5000/openshift3/jenkins-slave-nodejs-rhel7:v3.11
  docker push newrepo:5000/openshift3/jenkins-slave-nodejs-rhel7:v3.11.154
  docker push newrepo:5000/rhscl/mongodb-32-rhel7:3.2
  docker push newrepo:5000/rhscl/mysql-57-rhel7:5.7
  docker push newrepo:5000/rhscl/perl-524-rhel7:5.24
  docker push newrepo:5000/rhscl/php-56-rhel7:5.6
  docker push newrepo:5000/rhscl/postgresql-95-rhel7:9.5
  docker push newrepo:5000/rhscl/python-35-rhel7:3.5
  docker push newrepo:5000/redhat-sso-7/sso70-openshift:1.4
  docker push newrepo:5000/rhscl/ruby-24-rhel7:2.4
  docker push newrepo:5000/redhat-openjdk-18/openjdk18-openshift:1.7
  docker push newrepo:5000/redhat-sso-7/sso71-openshift:1.3
  docker push newrepo:5000/rhscl/nodejs-6-rhel7:6
  docker push newrepo:5000/rhscl/mariadb-101-rhel7:10.1
  ```


## Networking resources setup in AWS

For the networking resources, you must setup the following:

- VPC: create a VPC and store the id
- Subnet: create subnet(s) and store the id
- Security group: allow access to endpoints from the private PVC
- Route table: Set the default route table for the subnet(s) - this should also be associated with the s3 endpoint
- Endpoint: Create endpoints for AWS services, you must create endpoint for the following with enabled DNS and associated to all the related subnet (except for the S3):

  - com.amazonaws.<region>.s3
  - com.amazonaws.<region>.ec2
  - com.amazonaws.<region>.ssmmessages
  - com.amazonaws.<region>.autoscaling
  - com.amazonaws.<region>.cloudformation
  - com.amazonaws.<region>.ssm
  - com.amazonaws.<region>.secretsmanager


## Running the CloudFormation

The cloud stack must be loaded from an S3 bucket, so upload the `quickstart-redhat-openshift/templates/openshift.template` to the S3 Bucket.

Create a parameter file, you can edit the one in `quickstart-redhat-openshift/qs.json.sample` and substitute the values according to your environment. See the example below:

```
[
{"ParameterKey": "VPCID","ParameterValue": "vpc-02020c3d47db35497" },
{"ParameterKey": "VPCCIDR","ParameterValue": "10.10.0.0/16" },
{"ParameterKey": "PrivateSubnet1ID","ParameterValue": "subnet-0befa128cb682c6dc" },
{"ParameterKey": "PrivateSubnet2ID","ParameterValue": "subnet-0befa128cb682c6dc" },
{"ParameterKey": "PrivateSubnet3ID","ParameterValue": "subnet-0befa128cb682c6dc" },
{"ParameterKey": "RemoteAccessCIDR","ParameterValue": "0.0.0.0/0" },
{"ParameterKey": "ContainerAccessCIDR","ParameterValue": "0.0.0.0/0" },
{"ParameterKey": "DomainName","ParameterValue": "example.com" },
{"ParameterKey": "HostedZoneID","ParameterValue": "Z3D0ABCDABCDE" },
{"ParameterKey": "SubDomainPrefix","ParameterValue": "airgapped" },
{"ParameterKey": "KeyPairName","ParameterValue": "sshkey-us-east-1" },
{"ParameterKey": "AmiId","ParameterValue": "ami-0916c408cb02e310b" },
{"ParameterKey": "NumberOfAZs","ParameterValue": "1" },
{"ParameterKey": "NumberOfMaster","ParameterValue": "3" },
{"ParameterKey": "NumberOfEtcd","ParameterValue": "3" },
{"ParameterKey": "NumberOfNodes","ParameterValue": "3" },
{"ParameterKey": "MasterInstanceType","ParameterValue": "m4.xlarge" },
{"ParameterKey": "EtcdInstanceType","ParameterValue": "m4.xlarge" },
{"ParameterKey": "NodesInstanceType","ParameterValue": "m4.xlarge" },
{"ParameterKey": "OpenShiftAdminPassword","ParameterValue": "passw0rd" },
{"ParameterKey": "OpenshiftContainerPlatformVersion","ParameterValue": "3.11" },
{"ParameterKey": "AWSServiceBroker","ParameterValue": "Disabled" },
{"ParameterKey": "HawkularMetrics","ParameterValue": "Disabled" },
{"ParameterKey": "AnsibleFromGit","ParameterValue": "False" },
{"ParameterKey": "ClusterName","ParameterValue": "ocp311ag" },
{"ParameterKey": "GlusterFS","ParameterValue": "Disabled" },
{"ParameterKey": "AutomationBroker","ParameterValue": "Disabled" },
{"ParameterKey": "QSS3BucketName","ParameterValue": "airgapped" },
{"ParameterKey": "QSS3KeyPrefix","ParameterValue": "quickstart-redhat-openshift/" },
{"ParameterKey": "PrivateRegistry","ParameterValue": "10.10.20.78:5000" }
]
```
Notes:
- The subnet values are all the same here as only 1 subnet is UseDnsForACMValidation
- The AMI must use RHEL 7.7 or later
- PrivateRegistry refer to your registry in the airgapped network
- The example assumes the use of Route 53 as the DNS provider

Run the cloud formation (ocp311-airgapped is the S3 bucket name, to make sure that you can perform some debugging in case of failure, use `--disable-rollback`):

```
aws cloudformation create-stack --stack-name ocp311ag --template-url https://ocp311-airgapped.s3.amazonaws.com/openshift.template --parameters file://qs.json --capabilities CAPABILITY_IAM --disable-rollback
```
