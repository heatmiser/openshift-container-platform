#!/bin/bash
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3 RETURN
exec 1>/var/log/deployOpenShift_cri-o.out 2>&1

echo $(date) " - Starting OpenShift w/ CRI-O Deploy Script"

set -e

curruser=$(ps -o user= -p $$ | awk '{print $1}')
echo "Executing script as user: $curruser"
echo "args: $*"

export SUDOUSER=$1
export PASSWORD="$2"
export MASTER=$3
export MASTERPUBLICIPHOSTNAME=$4
export MASTERPUBLICIPADDRESS=$5
export INFRA=$6
export NODE=$7
export NODECOUNT=$8
export INFRACOUNT=$9
export MASTERCOUNT=${10}
export ROUTING=${11}
export REGISTRYSA=${12}
export ACCOUNTKEY="${13}"
export METRICS=${14}
export LOGGING=${15}
export TENANTID=${16}
export SUBSCRIPTIONID=${17}
export AADCLIENTID=${18}
export AADCLIENTSECRET="${19}"
export RESOURCEGROUP=${20}
export LOCATION=${21}
export COCKPIT=${22}
export AZURE=${23}
export STORAGEKIND=${24}
export CRS=${25}
export CRSAPP=${26}
export CRSAPPCOUNT=${27}
export CRSREG=${28}
export CRSREGCOUNT=${29}
export CRSDISKCOUNT=${30}

export BASTION=$(hostname)

# function to create incremental disk device names
function DiskDev () {
    local Rest Letters=defghijklmnopqrstuvwxyz
    Rest=${Letters#*$1}
    echo /dev/sd${Rest:$1:1}
}

# Determine if Commercial Azure or Azure Government
CLOUD=$( curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-04-02&format=text" | cut -c 1-2 )
export CLOUD=${CLOUD^^}

printf -v MASTERLOOP "%02d" $((MASTERCOUNT - 1))
export MASTERLOOP
printf -v INFRALOOP "%02d" $((INFRACOUNT - 1))
export INFRALOOP
printf -v NODELOOP "%02d" $((NODECOUNT - 1))
export NODELOOP
printf -v CRSAPPLOOP "%02d" $((CRSAPPCOUNT - 1))
export CRSAPPLOOP
printf -v CRSREGLOOP "%02d" $((CRSREGCOUNT - 1))
export CRSREGLOOP

# Provide current variables if needed for troubleshooting
#set -o posix ; set
echo "Command line args: $@"

# In openshift-ansible 3.10.0-0.16.0, the openshift_version setting was refactored...
# Which changes the CRI-O container image variable name, breaking how it is pulled from RH registry
# This modification fixes it
echo $(date) " - openshift_version setting refactoring fix applied for ansible fact l_crio_image"
cat >> /usr/share/ansible/openshift-ansible/playbooks/init/basic_facts.yml <<EOAYF

- name: Set correct CRI-O location
  hosts: all
  gather_facts: false
  tasks:
  - set_fact:
      l_crio_image: "registry.access.redhat.com/openshift3/cri-o:v3.9"
EOAYF

echo $(date) " - Configuring SSH ControlPath to use shorter path name"

sed -i -e "s/^# control_path = %(directory)s\/%%h-%%r/control_path = %(directory)s\/%%h-%%r/" /etc/ansible/ansible.cfg
sed -i -e "s/^#host_key_checking = False/host_key_checking = False/" /etc/ansible/ansible.cfg
sed -i -e "s/^#pty=False/pty=False/" /etc/ansible/ansible.cfg

# Create Ansible Playbooks for Post Installation tasks
echo $(date) " - Create Ansible Playbooks for Post Installation tasks"

# Run on all masters - Create Initial OpenShift User on all Masters
# Filename: addocpuser.yaml

# Run on only MASTER-00 - Make initial OpenShift User a Cluster Admin
# Filename: assignclusteradminrights.yaml

# Run on all nodes - Set Root password on all nodes
# Filename: assignrootpassword.yaml

# Run on MASTER-00 node - configure registry to use Azure Storage
# Create docker registry config based on Commercial Azure or Azure Government

if [[ $CLOUD == "US" ]]
then
  DOCKERREGISTRYYAML=dockerregistrygov.yaml
  export CLOUDNAME="AzureUSGovernmentCloud"
else
  DOCKERREGISTRYYAML=dockerregistrypublic.yaml
  export CLOUDNAME="AzurePublicCloud"

fi

# Create Master nodes grouping
echo $(date) " - Creating Master nodes grouping"

for (( c=0; c<$MASTERCOUNT; c++ ))
do
  printf -v hostnum "%02d" $c
  mastergroup="$mastergroup
$MASTER-$hostnum openshift_node_labels=\"{'region': 'master', 'zone': 'default'}\" openshift_hostname=$MASTER-$hostnum"
done

# Create Infra nodes grouping 
echo $(date) " - Creating Infra nodes grouping"

for (( c=0; c<$INFRACOUNT; c++ ))
do
  printf -v hostnum "%02d" $c
  infragroup="$infragroup
$INFRA-$hostnum openshift_node_labels=\"{'region': 'infra', 'zone': 'default'}\" openshift_hostname=$INFRA-$hostnum"
done

# Create Nodes grouping
echo $(date) " - Creating Nodes grouping"

for (( c=0; c<$NODECOUNT; c++ ))
do
  printf -v hostnum "%02d" $c
  nodegroup="$nodegroup
$NODE-$hostnum openshift_node_labels=\"{'region': 'app', 'zone': 'default'}\" openshift_hostname=$NODE-$hostnum"
done

# Create gluster disk device list
currentdisk=$(DiskDev 0)
devicelist="\"$currentdisk\""
for (( c=1; c<$CRSDISKCOUNT; c++ ))
do
  currentdisk=$(DiskDev $c)
  devicelist="$devicelist, \"$currentdisk\""
done

# Create Gluster App & Reg Nodes groupings
if [[ $CRS == "true" ]]
then
    echo $(date) " - Creating CRS Apps cluster grouping"

    for (( c=0; c<$CRSAPPCOUNT; c++ ))
    do
      printf -v hostnum "%02d" $c
      crsappgroup="$crsappgroup
$CRSAPP-$hostnum glusterfs_devices='[ $devicelist ]'"
    done

    for (( c=0; c<$CRSREGCOUNT; c++ ))
    do
      printf -v hostnum "%02d" $c
      crsreggroup="$crsreggroup
$CRSREG-$hostnum glusterfs_devices='[ $devicelist ]'"
    done
fi

# Cloning Ansible playbook repository
(cd /home/$SUDOUSER && git clone https://github.com/heatmiser/openshift-container-platform-playbooks.git)
if [ -d /home/${SUDOUSER}/openshift-container-platform-playbooks ]
then
  echo " - Retrieved playbooks successfully"
else
  echo " - Retrieval of playbooks failed"
  exit 99
fi

# Setting the default openshift_cloudprovider_kind if Azure enabled
if [[ $AZURE == "true" ]]
then
	export CLOUDKIND="openshift_cloudprovider_kind=azure"
fi

# Create Ansible Hosts File
echo $(date) " - Create Ansible Hosts file"

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
etcd
master00
EOF
if [[ $CRS == "true" ]]
then
cat >> /etc/ansible/hosts <<EOF
glusterfs
glusterfs_registry
EOF
fi
cat >> /etc/ansible/hosts <<EOF
new_nodes

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=true
deployment_type=openshift-enterprise
openshift_release=v3.9
docker_udev_workaround=True
openshift_use_dnsmasq=true
openshift_master_default_subdomain=$ROUTING
openshift_override_hostname_check=true
osm_use_cockpit=${COCKPIT}
os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'
openshift_master_api_port=443
openshift_master_console_port=443
osm_default_node_selector='region=app'
openshift_disable_check=memory_availability,docker_image_availability,docker_storage
$CLOUDKIND

# Enable cri-o
openshift_use_crio=true
#openshift_crio_enable_docker_gc=true
#oreg_url=registry.access.redhat.com/openshift3/ose-${component}:${version}
openshift_crio_systemcontainer_image_override=registry.access.redhat.com/openshift3/cri-o:v3.9

# default selectors for router and registry services
openshift_router_selector='region=infra'
openshift_registry_selector='region=infra'

# Deploy Service Catalog
openshift_enable_service_catalog=false

# template_service_broker_install=false
template_service_broker_selector={"region":"infra"}

# Type of clustering being used by OCP
openshift_master_cluster_method=native

# Addresses for connecting to the OpenShift master nodes
openshift_master_cluster_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# Setup metrics
openshift_metrics_install_metrics=false
openshift_metrics_start_cluster=true
openshift_metrics_hawkular_nodeselector={"region":"infra"}
openshift_metrics_cassandra_nodeselector={"region":"infra"}
openshift_metrics_heapster_nodeselector={"region":"infra"}
openshift_hosted_metrics_public_url=https://metrics.$ROUTING/hawkular/metrics

# Setup logging
openshift_logging_install_logging=false
openshift_logging_fluentd_nodeselector={"logging":"true"}
openshift_logging_es_nodeselector={"region":"infra"}
openshift_logging_kibana_nodeselector={"region":"infra"}
openshift_logging_curator_nodeselector={"region":"infra"}
openshift_master_logging_public_url=https://kibana.$ROUTING
openshift_logging_master_public_url=https://$MASTERPUBLICIPHOSTNAME:443

# host group for masters
[masters]
$MASTER-[00:${MASTERLOOP}]

# host group for etcd
[etcd]
$MASTER-[00:${MASTERLOOP}] 

[master00]
$MASTER-00

# host group for nodes
[nodes]
$mastergroup
$infragroup
$nodegroup

EOF
if [[ $CRS == "true" ]]
then
cat >> /etc/ansible/hosts <<EOF
[glusterfs]
$crsappgroup

[glusterfs_registry]
$crsreggroup
EOF
fi
cat >> /etc/ansible/hosts <<EOF

# host group for adding new nodes
[new_nodes]
EOF

# Run a loop playbook to ensure DNS Hostname resolution is working prior to continuing with script
echo $(date) " - Running DNS Hostname resolution check"
runuser -l $SUDOUSER -c "ansible-playbook ~/openshift-container-platform-playbooks/check-dns-host-name-resolution.yaml"
echo $(date) " - DNS Hostname resolution check complete"

DOMAIN=`domainname -d`

# Create /etc/origin/cloudprovider/azure.conf on all hosts if Azure is enabled
if [[ $AZURE == "true" ]]
then
	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/create-azure-conf.yaml"
	if [ $? -eq 0 ]
	then
		echo $(date) " - Creation of Cloud Provider Config (azure.conf) completed on all nodes successfully"
	else
		echo $(date) " - Creation of Cloud Provider Config (azure.conf) completed on all nodes failed to complete"
		exit 13
	fi
fi

# Setup NetworkManager to manage eth0
runuser -l $SUDOUSER -c "ansible-playbook -f 10 /usr/share/ansible/openshift-ansible/playbooks/openshift-node/network_manager.yml"

# Configure resolv.conf on all hosts through NetworkManager
echo $(date) " - Setting up NetworkManager on eth0"
runuser -l $SUDOUSER -c "ansible all -f 10 -b -m service -a \"name=NetworkManager state=restarted\""
sleep 5
runuser -l $SUDOUSER -c "ansible all -f 10 -b -m command -a \"nmcli con modify eth0 ipv4.dns-search $DOMAIN\""
runuser -l $SUDOUSER -c "ansible all -f 10 -b -m command -a \"nmcli device reapply eth0\""
sleep 5
runuser -l $SUDOUSER -c "ansible all -f 10 -b -m service -a \"name=network state=restarted\""

# Updating all hosts
echo $(date) " - Updating rpms on all hosts to latest release"
runuser -l $SUDOUSER -c "ansible all -f 10 -b -m yum -a \"name=* state=latest\""

# Install Ansible on all hosts
echo $(date) " - Install ansible on all hosts with dependancies"
runuser -l $SUDOUSER -c "ansible all -f 10 -b -m yum -a \"name=ansible state=latest\""

# Initiating installation of OpenShift Container Platform using Ansible Playbook
echo $(date) " - Running Prerequisites via Ansible Playbook"
runuser -l $SUDOUSER -c "ansible-playbook -f 10 /usr/share/ansible/openshift-ansible/playbooks/prerequisites.yml"

# Initiating installation of OpenShift Container Platform using Ansible Playbook
echo $(date) " - Installing OpenShift Container Platform via Ansible Playbook"
runuser -l $SUDOUSER -c "ansible-playbook -f 10 /usr/share/ansible/openshift-ansible/playbooks/deploy_cluster.yml"
if [ $? -eq 0 ]
then
   echo $(date) " - OpenShift Cluster installed successfully"
else
   echo $(date) " - OpenShift Cluster failed to install"
   exit 6
fi

echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

# Deploying Registry
echo $(date) " - Registry automatically deployed to infra nodes"

# Deploying Router
echo $(date) " - Router automaticaly deployed to infra nodes"

echo $(date) " - Re-enabling requiretty"

sed -i -e "s/# Defaults    requiretty/Defaults    requiretty/" /etc/sudoers

# Install OpenShift Atomic Client

cd /root
mkdir .kube
runuser ${SUDOUSER} -c "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SUDOUSER}@${MASTER}-00:~/.kube/config /tmp/kube-config"
cp /tmp/kube-config /root/.kube/config
mkdir /home/${SUDOUSER}/.kube
cp /tmp/kube-config /home/${SUDOUSER}/.kube/config
chown --recursive ${SUDOUSER} /home/${SUDOUSER}/.kube
rm -f /tmp/kube-config
yum -y install atomic-openshift-clients

# Adding user to OpenShift authentication file
echo $(date) " - Adding OpenShift user"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/addocpuser.yaml"

# Assigning cluster admin rights to OpenShift user
echo $(date) " - Assigning cluster admin rights to user"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/assignclusteradminrights.yaml"

if [[ $COCKPIT == "true" ]]
then

# Setting password for root if Cockpit is enabled
echo $(date) " - Assigning password for root, which is used to login to Cockpit"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/assignrootpassword.yaml"
fi

# Configure Docker Registry to use Azure Storage Account
echo $(date) " - Configuring Docker Registry to use Azure Storage Account"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/$DOCKERREGISTRYYAML"

if [[ $AZURE == "true" ]]
then

	# Create Storage Classes
	echo $(date) " - Creating Storage Classes"

	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/configurestorageclass.yaml"

	echo $(date) " - Sleep for 120"
	sleep 120

	# Execute setup-azure-master and setup-azure-node playbooks to configure Azure Cloud Provider
	echo $(date) " - Configuring OpenShift Cloud Provider to be Azure"

	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/setup-azure-master.yaml"

	if [ $? -eq 0 ]
	then
	    echo $(date) " - Cloud Provider setup of master config on Master Nodes completed successfully"
	else
	    echo $(date) " - Cloud Provider setup of master config on Master Nodes failed to completed"
	    exit 7
	fi

	echo $(date) " - Sleep for 60"
	sleep 60

	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/setup-azure-node-master.yaml"

	if [ $? -eq 0 ]
	then
	    echo $(date) " - Cloud Provider setup of node config on Master Nodes completed successfully"
	else
	    echo $(date) " - Cloud Provider setup of node config on Master Nodes failed to completed"
	    exit 8
	fi

	echo $(date) " - Sleep for 60"
	sleep 60

	runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/setup-azure-node.yaml"

	if [ $? -eq 0 ]
	then
	    echo $(date) " - Cloud Provider setup of node config on App Nodes completed successfully"
	else
	    echo $(date) " - Cloud Provider setup of node config on App Nodes failed to completed"
	    exit 9
	fi

	echo $(date) " - Sleep for 120"
	sleep 120

	echo $(date) " - Rebooting cluster to complete installation"
	runuser -l $SUDOUSER -c  "oc label --overwrite nodes $MASTER-00 openshift-infra=apiserver"
	runuser -l $SUDOUSER -c  "oc label --overwrite nodes --all logging-infra-fluentd=true logging=true"
	runuser -l $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/reboot-master.yaml"
	runuser -l $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/reboot-nodes.yaml"
	sleep 10

	# Installing Service Catalog, Ansible Service Broker and Template Service Broker
	
	echo $(date) "- Installing Service Catalog, Ansible Service Broker and Template Service Broker"
	runuser -l $SUDOUSER -c "ansible-playbook -f 10 /usr/share/ansible/openshift-ansible/playbooks/openshift-service-catalog/config.yml"
	echo $(date) "- Service Catalog, Ansible Service Broker and Template Service Broker installed successfully"

	# End of Azure specific section
fi 

# Configure Metrics

if [ $METRICS == "true" ]
then
	sleep 30
	echo $(date) "- Deploying Metrics"
	if [ $AZURE == "true" ]
	then
		runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/openshift-metrics/config.yml -e openshift_metrics_install_metrics=True -e openshift_metrics_cassandra_storage_type=dynamic"
	else
		runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/openshift-metrics/config.yml -e openshift_metrics_install_metrics=True"
	fi
	if [ $? -eq 0 ]
	then
	    echo $(date) " - Metrics configuration completed successfully"
	else
	    echo $(date) " - Metrics configuration failed"
	    exit 11
	fi
fi

# Configure Logging

if [ $LOGGING == "true" ]
then
	sleep 60
	echo $(date) "- Deploying Logging"
	if [ $AZURE == "true" ]
	then
		runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/openshift-logging/config.yml -e openshift_logging_install_logging=True -e openshift_logging_es_pvc_dynamic=true"
	else
		runuser -l $SUDOUSER -c "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/openshift-logging/config.yml -e openshift_logging_install_logging=True"
	fi
	if [ $? -eq 0 ]
	then
	    echo $(date) " - Logging configuration completed successfully"
	else
	    echo $(date) " - Logging configuration failed"
	    exit 12
	fi
fi

# Delete yaml files
echo $(date) " - Deleting unecessary files"
rm -rf /home/${SUDOUSER}/openshift-container-platform-playbooks

echo $(date) " - Sleep for 30"

sleep 30

echo $(date) " - Script complete"
