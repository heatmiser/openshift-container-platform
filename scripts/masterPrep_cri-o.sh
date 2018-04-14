#!/bin/bash
echo $(date) " - Starting Master Prep Script"

set -e

curruser=$(ps -o user= -p $$ | awk '{print $1}')
echo "Executing script as user: $curruser"
echo "args: $*"

USERNAME_ORG=$1
PASSWORD_ACT_KEY="$2"
POOL_ID=$3
SUDOUSER=$4
LOCATION=$5
STORAGEACCOUNT=$6

# Provide current variables if needed for troubleshooting
#set -o posix ; set
echo "Command line args: $@"

# Remove RHUI

rm -f /etc/yum.repos.d/rh-cloud.repo
sleep 10

# Register Host with Cloud Access Subscription
echo $(date) " - Register host with Cloud Access Subscription"

subscription-manager register --username="$USERNAME_ORG" --password="$PASSWORD_ACT_KEY" || subscription-manager register --activationkey="$PASSWORD_ACT_KEY" --org="$USERNAME_ORG"

if [ $? -eq 0 ]
then
   echo "Subscribed successfully"
elif [ $? -eq 64 ]
then
   echo "This system is already registered."
else
   echo "Incorrect Username / Password or Organization ID / Activation Key specified"
   exit 3
fi

subscription-manager attach --pool=$POOL_ID > attach.log
if [ $? -eq 0 ]
then
   echo "Pool attached successfully"
else
   evaluate=$( cut -f 2-5 -d ' ' attach.log )
   if [[ $evaluate == "unit has already had" ]]
      then
         echo "Pool $POOL_ID was already attached and was not attached again."
	  else
         echo "Incorrect Pool ID or no entitlements available"
         exit 4
   fi
fi

# Disable all repositories and enable only the required ones
echo $(date) " - Disabling all repositories and enabling only the required repos"

subscription-manager repos --disable="*"

subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.9-rpms" \
    --enable="rhel-7-server-ansible-2.4-rpms" \
    --enable="rhel-7-fast-datapath-rpms" 

#subscription-manager release --set=7.4

# Install base packages and update system to latest packages
echo $(date) " - Install base packages and update system to latest packages"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion httpd-tools kexec-tools sos psacct
yum -y install cloud-utils-growpart.noarch
yum -y update --exclude=WALinuxAgent
yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder cri-o

atomic-openshift-excluder unexclude

# Grow Root File System
echo $(date) " - Grow Root FS"

rootdev=`findmnt --target / -o SOURCE -n`
rootdrivename=`lsblk -no pkname $rootdev`
rootdrive="/dev/"$rootdrivename
name=`lsblk  $rootdev -o NAME | tail -1`
part_number=${name#*${rootdrivename}}

growpart $rootdrive $part_number -u on
xfs_growfs $rootdev

# Install OpenShift utilities
echo $(date) " - Installing OpenShift utilities"
yum -y install atomic-openshift-utils

# Install Docker
echo $(date) " - Installing Docker"
yum -y install docker 

sed -i -e "s#^OPTIONS='--selinux-enabled'#OPTIONS='--selinux-enabled --insecure-registry 172.30.0.0/16'#" /etc/sysconfig/docker

# Create thin pool logical volume for containers
echo $(date) " - Creating thin pool logical volume for containers overlay fs"

CONTAINERVG=$( parted -m /dev/sda print all 2>/dev/null | grep unknown | grep /dev/sd | cut -d':' -f1 )

echo "STORAGE_DRIVER=overlay2" > /etc/sysconfig/docker-storage-setup
echo "DEVS=${CONTAINERVG}" >> /etc/sysconfig/docker-storage-setup
echo "VG=containersvg" >> /etc/sysconfig/docker-storage-setup
echo "CONTAINER_ROOT_LV_NAME=containerslv" >> /etc/sysconfig/docker-storage-setup
echo "CONTAINER_ROOT_LV_SIZE=100%FREE" >> /etc/sysconfig/docker-storage-setup
echo "CONTAINER_ROOT_LV_MOUNT_PATH=/var/lib/containers" >> /etc/sysconfig/docker-storage-setup
container-storage-setup
if [ $? -eq 0 ]
then
   echo "Containers thin pool logical volume created successfully"
else
   echo "Error creating logical volume for containers overlay fs"
   exit 5
fi

# Enable and start Docker services

#systemctl enable docker
#systemctl start docker

# Create Storage Class yml files on MASTER-00

if hostname -f|grep -- "-00" >/dev/null
then
cat <<EOF > /home/${SUDOUSER}/scunmanaged.yml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: generic
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/azure-disk
parameters:
  location: ${LOCATION}
  storageAccount: ${STORAGEACCOUNT}
EOF

cat <<EOF > /home/${SUDOUSER}/scmanaged.yml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: generic
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/azure-disk
parameters:
  kind: managed
  location: ${LOCATION}
  storageaccounttype: Premium_LRS
EOF
fi

echo $(date) " - Script Complete"