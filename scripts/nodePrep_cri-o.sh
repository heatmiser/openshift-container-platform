#!/bin/bash
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3 RETURN
exec 1>/var/log/nodePrep_cri-o.out 2>&1

echo $(date) " - Starting Infra / Node Prep Script"

set -e

curruser=$(ps -o user= -p $$ | awk '{print $1}')
echo "Executing script as user: $curruser"
echo "args: $*"

USERNAME_ORG=$1
PASSWORD_ACT_KEY="$2"
POOL_ID=$3
STORAGE_ADDON_POOL_ID=$4

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

if [ "$POOL_ID" == "null" ]
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

if [ "$STORAGE_ADDON_POOL_ID" != "null" ]
then
    # Attach Container Storage Add-On for OpenShift Container Platform pool ID	
    echo $(date) " - Attach Container Storage Add-On pool ID"	
	
    subscription-manager attach --pool=$STORAGE_ADDON_POOL_ID > attach-cntr-storage-pool.log	
    if [ $? -eq 0 ]	
    then	
        echo "Pool attached successfully"	
    else	
        evaluate=$( cut -f 2-5 -d ' ' attach-cntr-storage-pool.log )	
        if [[ $evaluate == "unit has already had" ]]	
            then	
                echo "Pool $STORAGE_ADDON_POOL_ID was already attached and was not attached again."	
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

# Install base packages and update system to latest packages
echo $(date) " - Install base packages and update system to latest packages"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct
yum -y install cloud-utils-growpart.noarch
yum -y install ansible
yum -y update glusterfs-fuse
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

# Enable and start Docker services

systemctl enable docker
systemctl start docker

echo $(date) " - Script Complete"

