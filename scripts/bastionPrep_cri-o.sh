#!/bin/bash
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3 RETURN
exec 1>/var/log/bastionPrep_cri-o.out 2>&1

echo $(date) " - Starting Bastion Prep Script"

set -e

curruser=$(ps -o user= -p $$ | awk '{print $1}')
echo "Executing script as user: $curruser"
echo "args: $*"

USERNAME_ORG=$1
PASSWORD_ACT_KEY="$2"
POOL_ID=$3
PRIVATEKEY=$4
SUDOUSER=$5

# Provide current variables if needed for troubleshooting
#set -o posix ; set
echo "Command line args: $@"

# Generate private keys for use by Ansible
echo $(date) " - Generating Private keys for use by Ansible for OpenShift Installation"

runuser -l $SUDOUSER -c "echo \"$PRIVATEKEY\" > ~/.ssh/id_rsa"
runuser -l $SUDOUSER -c "chmod 600 ~/.ssh/id_rsa*"

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

if [ $POOL_ID == "null" ]
then
   echo "Subscribed successfully via Organization ID / Activation Key, no pool attachment necessary."
else
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
fi

# Disable all repositories and enable only the required ones
echo $(date) " - Disabling all repositories and enabling only the required repos"

subscription-manager repos --disable="*"

subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.9-rpms" \
    --enable="rhel-7-server-ansible-2.4-rpms" \
    --enable="rhel-7-fast-datapath-rpms" \
    --enable="rh-gluster-3-client-for-rhel-7-server-rpms"

# Update system to latest packages
echo $(date) " - Update system to latest packages"
yum -y update --exclude=WALinuxAgent
echo $(date) " - System update complete"

# Install base packages and update system to latest packages
echo $(date) " - Install base packages"
yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion httpd-tools kexec-tools sos psacct tmux
yum -y install ansible
yum -y update glusterfs-fuse
echo $(date) " - Base package insallation complete"

# Excluders for OpenShift
yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder
atomic-openshift-excluder unexclude
yum -y install cloud-utils-growpart.noarch

# Grow Root File System
echo $(date) " - Grow Root FS"

rootdev=`findmnt --target / -o SOURCE -n`
rootdrivename=`lsblk -no pkname $rootdev`
rootdrive="/dev/"$rootdrivename
name=`lsblk  $rootdev -o NAME | tail -1`
part_number=${name#*${rootdrivename}}

# if growpart fails, it will exit.
# we capture stderr because on success of dry-run, it writes to stderr what it would do.
set +e
gpout=$(growpart --dry-run $rootdrive $part_number -u on 2>&1)
ret=$?
# if growpart would change something, --dry-run will write something like
#  CHANGE: partition=1 start=2048 old: size=1024000 end=1026048 new: size=2089192,end=2091240
# newer versions of growpart will exit
#   0: with 'CHANGE:*' in output on changed
#   1: with 'NOCHANGE:*' in output on no-change-necessary
#   2: error occurred
case "$ret:$gpout" in
	0:CHANGE:*) gpout=$(growpart "${rootdisk}" "${partnum}" -u on 2>&1);;
	[01]:NOCHANGE:*) echo "growpart '$rootdrive'" "${gpout}";;
	*) echo "not sure what happened...";;
esac

set -e
xfsout=""
case "$gpout" in
	CHANGED:*) echo "xfs_growfs: $rootdev"; xfsout=$(xfs_growfs $rootdev);;
    	NOCHANGE:*) echo "xfs_growfs skipped";;
		*) echo "GROWROOT: unexpected output: ${out}"
esac

echo $xfsout

# Install Docker
echo $(date) " - Installing Docker"
yum -y install docker

sed -i -e "s#^OPTIONS='--selinux-enabled'#OPTIONS='--selinux-enabled --insecure-registry 172.30.0.0/16'#" /etc/sysconfig/docker

# Create logical volume for containers
echo $(date) " - Creating logical volume for containers overlay fs"

if [ -b /dev/vda ] ; then
    CONTAINERVG=$( parted -m /dev/vda print all 2>/dev/null | grep unknown | grep /dev/vd | cut -d':' -f1 )
elif [ -b /dev/sda ] ; then
    CONTAINERVG=$( parted -m /dev/sda print all 2>/dev/null | grep unknown | grep /dev/sd | cut -d':' -f1 )
fi

echo "STORAGE_DRIVER=overlay2" > /etc/sysconfig/docker-storage-setup
echo "DEVS=${CONTAINERVG}" >> /etc/sysconfig/docker-storage-setup
echo "VG=containersvg" >> /etc/sysconfig/docker-storage-setup
echo "CONTAINER_ROOT_LV_NAME=containerslv" >> /etc/sysconfig/docker-storage-setup
echo "CONTAINER_ROOT_LV_SIZE=100%FREE" >> /etc/sysconfig/docker-storage-setup
echo "CONTAINER_ROOT_LV_MOUNT_PATH=/var/lib/containers" >> /etc/sysconfig/docker-storage-setup
container-storage-setup
if [ $? -eq 0 ]
then
   echo "Containers logical volume created successfully"
else
   echo "Error creating logical volume for containers overlay fs"
   exit 5
fi

# Install podman, buildah, skopeo
yum -y install podman buildah skopeo
wget https://raw.githubusercontent.com/heatmiser/openshift-container-platform/release-3.9/conf/libpod.conf -O /etc/containers/libpod.conf

# Install OpenShift utilities
echo $(date) " - Installing OpenShift utilities"

yum -y install atomic-openshift-utils
echo $(date) " - OpenShift utilities insallation complete"

# Installing Azure CLI
# From https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-yum
echo $(date) " - Installing Azure CLI"
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo sh -c 'echo -e "[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'
sudo yum install -y azure-cli
echo $(date) " - Azure CLI insallation complete"

# Configure DNS so it always has the domain name
echo $(date) " - Adding DOMAIN to search for resolv.conf"
echo "DOMAIN=`domainname -d`" >> /etc/sysconfig/network-scripts/ifcfg-eth0

# Run Ansible Playbook to update ansible.cfg file

echo $(date) " - Updating ansible.cfg file"
wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 5 https://raw.githubusercontent.com/heatmiser/openshift-container-platform-playbooks/master/updateansiblecfg.yaml
ansible-playbook -f 10 ./updateansiblecfg.yaml

echo $(date) " - Script Complete"
