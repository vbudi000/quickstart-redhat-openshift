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

6. Prepare the file `/opt/registry/certs/domain.crt` for importing later in the OpenShift nodes and image load machine. Load the domain.crt file to the S3 bucket.

Now retrieve and load the images (if you have sufficient storage, you can use the same machine)

1. Prepare a machine with more than 60G free disk with access to the target registry. As `root`, copy `/opt/registry/certs/domain.crt` to `/etc/pki/ca-trust/source/anchors/` and run:

  ```
  update-ca-trust
  ```

2. Collect docker images from `registry.redhat.io`

  ```
  bash quickstart-redhat-openshift/script/docker_pull.txt
  ```

3. Save the images to a tar file to be transported for the disconnected installation. The files created can be loaded to the S3 bucket: ose3-images.tar, ose3-optional-images.tar and ose3-builder-images.tar

  ```
  bash quickstart-redhat-openshift/script/docker_save.txt
  ```

4. Save and load the docker registry image into the S3 bucket:

  ```
  docker pull registry:2
  docker save registry.tar registry
  ```

In the private registry, perform the following (potentially run the setyum.sh above):

1. Copy the images from S3 bucket:

  ```
  curl https://<bucket>.s3.amazonaws.com/registry.tar -o registry.tar
  curl https://<bucket>.s3.amazonaws.com/ose3-images.tar -o ose3-images.tar
  curl https://<bucket>.s3.amazonaws.com/ose3-optional-images.tar -o ose3-optional-images.tar
  curl https://<bucket>.s3.amazonaws.com/ose3-builder-images.tar -o ose3-builder-images.tar
  ```

2. Load the images in the private registry:

  ```
  yum install -y docker
  systemctl enable docker
  systemctl start docker
  docker load -i registry.tar
  docker load -i ose3-images.tar
  docker load -i ose3-builder-images.tar
  docker load -i ose3-optional-images.tar
  ```

3. Tag the images to the target registry (note the repo here is called `newrepo:5000` it should be changed):

  ```
  sed -i 's/newrepo:5000/<repoip:port>/g' quickstart-redhat-openshift/script/docker_tag.txt
  bash quickstart-redhat-openshift/script/docker_tag.txt
  ```

4. Prepare the private registry:

  - Edit `/etc/pki/tls/openssl.cnf` and add in the `[ v3_ca ]` section (change the repo IP):

    ```
    subjectAltName = IP:10.10.20.78
    ```

  - Generate a self-signed certificate:

    ```
    mkdir -p /opt/registry/{certs,data}
    cd /opt/registry/certs
    openssl req -newkey rsa:4096 -nodes -sha256 -keyout domain.key -x509 -days 365 -out domain.crt
    ```

  - Run the registry server:

    ```
    systemctl start docker
    docker run --name registry -p 5000:5000 -v /opt/registry/data:/var/lib/registry -v /opt/registry/certs:/certs -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key registry  &
    ```

4. Set up access to the target registry:

  ```
  cp domain.crt /etc/pki/ca-trust/source/anchors/
  update-ca-trust
  systemctl restart docker
  ```

5. Push out to store the images (again, note to change `newrepo:5000`):

  ```
  sed -i 's/newrepo:5000/<repoip:port>/g' quickstart-redhat-openshift/script/docker_push.txt
  bash quickstart-redhat-openshift/script/docker_push.txt
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
