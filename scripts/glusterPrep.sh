#!/bin/bash
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3 RETURN
exec 1>/var/log/glusterPrep.out 2>&1

echo $(date) " - Starting Gluster Node Prep Script"

set -e

curruser=$(ps -o user= -p $$ | awk '{print $1}')
echo "Executing script as user: $curruser"
echo "args: $*"

USERNAME_ORG=$1
PASSWORD_ACT_KEY="$2"
POOL_ID=$3

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
    --enable="rhel-7-server-ansible-2.4-rpms" \
    --enable="rhel-7-fast-datapath-rpms"

# Install base packages and update system to latest packages
echo $(date) " - Install base packages and update system to latest packages"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct
yum -y install cloud-utils-growpart.noarch
yum -y update --exclude=WALinuxAgent

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

optimize_tcp_network_settings() {
    # optimize network TCP settings
if [ "$1" -eq 1 ]; then
    local sysctlfile=/etc/sysctl.d/60-tcptune.conf
    if [ ! -e $sysctlfile ] || [ ! -s $sysctlfile ]; then
cat > $sysctlfile << EOF
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=30000
net.ipv4.tcp_max_syn_backlog=80960
net.ipv4.tcp_mem=16777216 16777216 16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_abort_on_overflow=1
net.ipv4.route.flush=1
EOF
    fi
    sysctl -p
fi  
}

optimize_tcp_network_settings

echo $(date) " - Script Complete"
