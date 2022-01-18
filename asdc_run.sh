####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, August 2020
#
# - Provision a kubernetes cluster using OpenStack cluster orchestration engine
# - Create volumes for persistent storage
# - Launch a WebODM instance, a NodeODM instance per cluster node and other required services
# - Configure external load balancer with reserved floating ip and setup SSL
####################################################################################################


#TODO:
# - Better shared storage pool between nodes, nfs or similar

if [[ "$0" = "$BASH_SOURCE" ]]; then
    echo "Please source this script. Do not execute."
    exit 1
fi

#Load the settings, setup openstack and kubectl
source settings.env

####################################################################################################
echo --- Phase 1 : Cluster Launch
####################################################################################################

STATUS=''
function get_status()
{
  #Get the status of the running cluster
  STATUS=$(openstack coe cluster show $CLUSTER -f value -c status)
}

function cluster_check()
{
  #if [ "$STATUS" == $1 ]; then
  #Checks for desired status as sub-string,
  #eg: UPDATE_COMPLETE/CREATE_COMPLETE will match COMPLETE
  if [[ "$STATUS" == *"$1"* ]]; then
    return 0
  fi
  return 1
}

function cluster_launched()
{
  if cluster_check "COMPLETE" ; then
    return 0
  fi
  if cluster_check "CREATE_IN_PROGRESS"; then
    return 0
  fi
  return 1
}

function nodegroup_check()
{
  NSTATUS=$(openstack coe nodegroup show $CLUSTER cluster-nodes -f value -c status)
  if [[ "$NSTATUS" == *"$1"* ]]; then
    return 0
  fi
  return 1
}

function wait_for_pod()
{
  #Loop until pod is running
  #$1 = pod name
  until kubectl get pods --field-selector status.phase=Running | grep $1
  do
    echo "Waiting for pod to enter status=Running : $1"
    sleep 2
  done
  echo "Pod is running : $1"
}

#Use our config file from openstack magnum for kubectl
export KUBECONFIG=$(pwd)/secrets/kubeconfig

#If secrets/kubeconfig exists, then skip cluster build, remove it to re-create
if [ ! -s "${KUBECONFIG}" ] || ! grep "${CLUSTER}" ${KUBECONFIG};
then
  echo "Kubernetes config for $CLUSTER not found, preparing to create cluster"
  #DEBUG - delete the existing template to apply changes / edits
  #NOTE: This just fails when the cluster is running, so it's ok to run without checking here
  openstack coe cluster template delete $TEMPLATE;

  KUBE_TAG=v1.21.1
  FLANNEL_TAG=v0.14.0-amd64
  #KUBE_TAG=v1.17.11
  #FLANNEL_TAG=v0.12.0-amd64

  #Working labels for k8s 1.21.1 on fedora-coreos-32
  LABELS=container_infra_prefix=registry.rc.nectar.org.au/nectarmagnum/,kube_tag=$KUBE_TAG,flannel_tag=$FLANNEL_TAG,master_lb_floating_ip_enabled=true,docker_volume_type=standard,availability_zone=$ZONE,cinder_csi_enabled=true,ingress_controller=octavia

  #Current default labels from kubernetes-monash-02-v1.21.1
  #container_infra_prefix=registry.rc.nectar.org.au/nectarmagnum/,kube_tag=v1.21.1,flannel_tag=v0.14.0-amd64,master_lb_floating_ip_enabled=true,cinder_csi_enabled=true,docker_volume_type=standard,availability_zone=monash-02,ingress_controller=octavia

  #Creating the template
  echo "Using labels: $LABELS"
  if ! openstack coe cluster template show $TEMPLATE;
  then
    #See: https://docs.openstack.org/magnum/latest/user/
    echo "Creating cluster template: $TEMPLATE"

    #Tried calico for dns issues and slow image pulls, didn't resolve
    #NWDRIVER="calico"
    NWDRIVER="flannel"

    #Floating ip disabled, master-lb-enabled, master-lb-floating-ip enabled
    openstack coe cluster template create $TEMPLATE --image $IMAGE --keypair $KEYPAIR --external-network $NETWORK --floating-ip-disabled --master-lb-enabled --flavor $APP_FLAVOUR --master-flavor $MASTER_FLAVOUR --docker-volume-size $DOCKER_VOL_SIZE --docker-storage-driver overlay2 --network-driver $NWDRIVER --coe kubernetes --volume-driver cinder --coe kubernetes --labels $LABELS

    #Floating ip enabled (allows ssh into nodes but requires extra FIPs)
    #openstack coe cluster template create $TEMPLATE --image $IMAGE --keypair $KEYPAIR --external-network $NETWORK --dns-nameserver 8.8.8.8 --flavor $FLAVOUR --master-flavor $MASTER_FLAVOUR --docker-volume-size 25 --docker-storage-driver overlay2 --network-driver flannel --coe kubernetes --volume-driver cinder --coe kubernetes --labels $LABELS
  fi

  #List running stacks
  openstack stack list

  #Create the cluster, wait until complete
  get_status
  if ! cluster_check "CREATE_FAILED" && ! cluster_launched; then
    #Create the cluster from default template
    openstack coe cluster create --cluster-template $TEMPLATE --keypair $KEYPAIR --master-count 1 --node-count $APP_NODES $CLUSTER
    echo "Cluster create initiated..."
  fi

  #Wait until cluster complete
  until cluster_check "COMPLETE"
  do
    get_status
    printf "$STATUS "
    if cluster_check "CREATE_FAILED"; then
      echo "Cluster create failed!"
      heat stack-list -n
      echo "Use 'heat resource-list failedstackid'"
      echo "Then 'heat resource-show failedstackid resid' for more info"
      return 1
    fi
    sleep 2
  done
  echo ""

  #Wait for the load balancer to be provisioned
  STACK_ID=$(openstack coe cluster show $CLUSTER -f value -c stack_id)
  K_FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
  #Ping no longer responding
  #while ! timeout 0.2 ping -c 1 -n ${K_FLOATING_IP} &> /dev/null;
  while ! timeout 0.2 nc -zv ${K_FLOATING_IP} 6443 &> /dev/null;
  do
    echo "Waiting for master-lb to be assigned floating IP, current api_address = $K_FLOATING_IP"
    K_FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
    sleep 1
  done

  #Once the cluster is running, get params and the config for kubectl
  echo "Attempting to configure cluster";
  #Finally setup the environment and export kubernetes config
  : '
  STACK_ID=$(openstack coe cluster show $CLUSTER -f value -c stack_id)
  K_FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
  PORT_ID=$(openstack floating ip show $K_FLOATING_IP -c port_id -f value)

  #Open the port if not already done
  SG_ID=$(openstack security group show kubernetes-api -c id -f value)
  if ! openstack port show $PORT_ID -c security_group_ids -f value | grep $SG_ID
  then
    echo "SETTING PORT"
    #THIS STILL FAILS... DOESNT SEEM TO MATTER ANYWAY AS CAN ACCESS WITH IP???
    #ResourceNotFound: 404: Client Error for url: https://neutron.rc.nectar.org.au:9696/v2.0/ports/1cfcf6b5-cf52-476b-9598-01e49ffffce6, Security group bde2e01a-9c02-4e90-b9af-dcba62f47660 does not exist
    openstack port set --security-group kubernetes-api $PORT_ID
  else
    echo "PORT SET ALREADY"
  fi
  '

  #Setup node groups
  # https://docs.openstack.org/magnum/latest/user/#node-groups
  #(Will error if already created so ok to run again without check)
  openstack coe nodegroup create $CLUSTER cluster-nodes --flavor $CLUSTER_FLAVOUR --min-nodes $NODES --node-count $NODES --role cluster
  #Second cluster group? (once more hardware available)
  #openstack coe nodegroup create $CLUSTER cluster2-nodes --flavor $CLUSTER2_FLAVOUR --min-nodes $NODES --node-count $NODES --role cluster

  #Create the config
  openstack coe cluster config $CLUSTER
  mv config ${KUBECONFIG}
  chmod 600 ${KUBECONFIG}

  # DNS fails on newer kubernetes with fedora-coreos-32 image, need to restart flannel pods...
  # See: https://tutorials.rc.nectar.org.au/kubernetes/09-troubleshooting
  #Flannel
  kubectl -n kube-system delete pod -l app=flannel

  #Calico - reset pods to try and fix network issues?
  #kubectl get pods --all-namespaces -owide --show-labels
  #kubectl -n kube-system delete pod -l k8s-app=calico-node

else
  echo "${KUBECONFIG} exists for $CLUSTER, to force re-creation : rm ${KUBECONFIG}"
  #If config exists but cluster doesn't, remove config and exit here...
  if ! openstack coe cluster show $CLUSTER -f value -c status;
  then
    echo "Cluster doesn't exist, removing config, re-run to create"
    return 1;
  fi
fi;

#kubectl get all
#kubectl get all --all-namespaces
kubectl get nodes

####################################################################################################
echo --- Phase 2a : Deployment: Volumes and storage
####################################################################################################

function subst_template()
{
  #Use envsubst to apply variables to template .yaml files
  #$1 = filename.yaml

  #Runs envsubst but skips vars not defined in env https://unix.stackexchange.com/a/492778/17168
  cat templates/$1 | envsubst "$(env | cut -d= -f1 | sed -e 's/^/$/')" > yaml/$1
  echo "Applied env to template: templates/$1 => yaml/$1"
}

function apply_template()
{
  #Substitute env vars
  subst_template $1
  #Apply to cluster
  kubectl apply -f yaml/$1
}

### Create persistent cinder volumes

#Volume creation function
VOL_ID=''
#List of all volume names for faster checks
VOLS=$(openstack volume list -c Name -f value)
function create_volume()
{
  if ! echo "$VOLS" | grep -x "$2";
  then
    #Create volume, args size in gb, label
    echo "Creating Volume '$2' of size $1 gb"
    openstack volume create --availability-zone $ZONE --size $1 $2
  fi
  VOL_ID=$(openstack volume show $2 -f value -c id)
}

#Create volume for server/webapp
create_volume $WEBAPP_VOLUME_SIZE web-storage
export WEB_VOLUME_ID=$VOL_ID

#Create volume for db
create_volume $DB_VOLUME_SIZE db-storage
export DB_VOLUME_ID=$VOL_ID

#Apply the storage IDs to the persistent volumes and volume sizes to volumes/claims
if [ "$WEB_VOLUME_ID" ]; then
  apply_template webapp-volume.yaml
else
  echo "WEB_VOLUME_ID not set, aborting!"
  return 1
fi
if [ "$DB_VOLUME_ID" ]; then
  apply_template db-volume.yaml
else
  echo "DB_VOLUME_ID not set, aborting!"
  return 1
fi

# Create StorageClasses for dynamic provisioning
apply_template storage-classes.yaml

# Create the secret for accessing the cephfs shared data volume
kubectl create namespace jupyterhub
apply_template shared-data-cephfs-secret.yaml 

####################################################################################################
echo --- Phase 2b : Deployment: Tusd / Uppy
####################################################################################################

# This needs to go before the webapp setup,
# nginx proxy in webapp-worker requires host to be up

helm repo add skm https://charts.sagikazarmark.dev

#AWS S3 setup - required if tusd is to use object storage
#apply_template s3-secret.yaml

#Setup cinder volume provisioner
apply_template tusd-pvc.yaml

#Replace variables, then apply values to helm chart
subst_template tusd-values.yaml
helm install tusd --wait -f yaml/tusd-values.yaml skm/tusd

#NOTE: AWS stuff is not actually being used currently
#NOTE: unless connecting a dev instance on localhost, no need for LB and external IP

####################################################################################################
echo --- Phase 2c : Deployment: WebODM
####################################################################################################

#If domain already has certificate issued, copy to local dir as cert.pem & key.pem
#If not, will attempt to generate with letsencrypt later
echo "Checking for existing SSL cert..."
if [ ! -s "secrets/cert.pem" ] || [ ! -s "secrets/key.pem" ];
then
  echo " - Certs not found, generating once pod running"
  SSL_KEY_B64='""'
  SSL_CERT_B64='""'
else
  #(files exist and length > 0)
  echo " - Certs found, applying as ssl-secret.yaml for webapp"
  SSL_KEY_B64=$(base64 --wrap=0 secrets/key.pem)
  SSL_CERT_B64=$(base64 --wrap=0 secrets/cert.pem)
fi;
apply_template ssl-secret.yaml

#Deploy the server WebODM instance
apply_template db-service.yaml
apply_template db-deployment.yaml
apply_template broker-deployment.yaml
apply_template webapp-worker-pod.yaml
apply_template broker-service.yaml
apply_template webapp-service.yaml

#kubectl get pods --all-namespaces -owide
#kubectl get svc

#For debugging... log in to pod shell
#kubectl exec --stdin --tty webapp-worker -- /bin/bash

#Get output
#kubectl logs webapp-worker -c worker

#To specify alternate container in multi-container pod
#kubectl exec --stdin --tty webapp-worker -c worker -- /bin/bash

#When all is ready, start the web app (requires DNS resolution to hostname working for SSL cert)
#kubectl exec webapp-worker -c webapp -- /webodm/start.sh

# ####################################################################################################
echo --- Phase 3 : Deployment: Flux - Jupyterhub, cesium - Prepare configmaps and secrets for flux
# ####################################################################################################

# Base64 encoding for k8s secrets
export ASDC_SECRETS_BASE64=$(cat templates/asdc-secrets.tpl.yaml | envsubst | base64 -w 0)

apply_template jupyterhub-configmap.yaml
apply_template jupyterhub-secret.yaml

# Bootstrap flux.
#(Requires github personal access token with repo rights in GITHUB_TOKEN)

# Installs flux if it's not already present, using the configured live repo. This is idempotent.
flux bootstrap ${FLUX_LIVE_REPO_TYPE} --owner=${FLUX_LIVE_REPO_OWNER} --repository=${FLUX_LIVE_REPO} --team=${FLUX_LIVE_REPO_TEAM} --path=${FLUX_LIVE_REPO_PATH}

#Check
#kubectl -n jupyterhub describe hr jupyterhub
#Delete
#kubectl -n jupyterhub delete hr jupyterhub

#See/Suspend/resume
#flux get helmreleases -n jupyterhub
#flux suspend helmrelease jupyterhub -n jupyterhub
#flux resume helmrelease jupyterhub -n jupyterhub

#BUG: autohttps / proxy pods seem to fail to get letsencrypt cert on first boot, need to delete and let them run again

#Info...
#flux get all

####################################################################################################
echo --- Phase 4a : GPU cluster node taints
####################################################################################################

#Wait until nodegroup complete
until nodegroup_check "COMPLETE"
do
  printf "Nodegroup $NSTATUS "
  sleep 2
done

# All gpu cluster nodes need to be tainted to prevent other pods running on them!
#kubectl taint nodes $NODE key1=value1:NoSchedule
#kubectl taint nodes $NODE compute=compute-jobs-only:NoSchedule
for node in $(kubectl get nodes -l magnum.openstack.org/role=cluster -ojsonpath='{.items[*].metadata.name}'); 
do 
  #kubectl get pods -A -owide --field-selector spec.nodeName=$node;
  kubectl taint nodes $node compute=true:NoSchedule
done

####################################################################################################
echo --- Phase 4b : NVidia GPU Setup
####################################################################################################
# Apply our GPU driver installer/plugin container via daemonset
# this installs the nvidia drivers and device plugin in the node host os


#Using helm gpu-operator
helm repo add nvidia https://nvidia.github.io/gpu-operator
helm repo update

#Must match version in current build at https://github.com/AuScalableDroneCloud/nvidia-driver-build-fedora
NVIDIA_DRIVER=460.32.03
#NVIDIA_DRIVER=470.57.02 #Errors due to gcc version? Might need a newer coreos

# See for options: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/getting-started.html#chart-customization-options
# See default values here: https://github.com/NVIDIA/gpu-operator/blob/master/deployments/gpu-operator/values.yaml
# Enabling PodSecurityPolicies to fix crash in cuda-validator "PodSecurityPolicy: unable to admit pod"
#helm install gpu-operator --devel nvidia/gpu-operator --set driver.repository=ghcr.io/auscalabledronecloud,driver.version=$NVIDIA_DRIVER,psp.enabled=true --wait

subst_template gpu-operator-values.yaml
kubectl create namespace nvidia-gpu
helm install gpu-operator --devel --namespace nvidia-gpu --wait -f yaml/gpu-operator-values.yaml nvidia/gpu-operator

####################################################################################################
echo --- Phase 5a : Deployment: NodeODM
####################################################################################################

#Deploy processing nodes
function deploy_node()
{
  #Deploy NodeODM pod using name and volume ID
  #$1 = id#, $2 = type, $3 = image, $4 = port, $5 = gpus, $6 = optional args
  export NODE_NAME=$1
  export NODE_VOLUME_NAME=$1-storage
  export NODE_TYPE=$2
  export NODE_IMAGE=$3
  export NODE_PORT=$4
  export NODE_GPUS=$5
  export NODE_ARGS=$6
  if ! kubectl get pods | grep $NODE_NAME
  then
    echo ">>> NODE LAUNCH... " $NODE_NAME $NODE_PORT $NODE_IMAGE $NODE_TYPE $NODE_VOLUME_NAME $NODE_ARGS
    echo "Deploying $3 : $4 as $NODE_NAME"
    apply_template nodeodm.yaml
    apply_template node-pvc.yaml
    apply_template nodeodm-service.yaml
  fi
}

#Deploy clusterODM
export NODE_VOLUME_SIZE=1 #No volume storage necessary, so set as minimum
deploy_node clusterodm clusterodm opendronemap/clusterodm 3000 0 '["--public-address", "http://clusterodm:3000"]'

#Deploy NodeODM nodes
export NODE_VOLUME_SIZE=$NODE_VOLSIZE
for (( n=1; n<=$NODE_ODM; n++ ))
do
  #First $NODE_ODM_GPU nodes are configured to use gpu
  if [ "$n" -le "$NODE_ODM_GPU" ]; then 
    #For GPU Nodes use gpu nodeodm image and set NODE_GPUS > 0
    #(Note: we had to build our own image as public opendronemap/nodeodm:gpu doesn't seem to exist yet)
    #https://github.com/OpenDroneMap/NodeODM#using-gpu-acceleration-for-sift-processing-inside-nodeodm
    echo "Requesting CPU+GPU node"
    deploy_node nodeodm$n nodeodm ghcr.io/auscalabledronecloud/asdc-nodeodm-gpu 3000 1 ${ODM_FLAGS_GPU}
  else
    echo "Requesting CPU only node"
    deploy_node nodeodm$n nodeodm ghcr.io/auscalabledronecloud/asdc-nodeodm 3000 0 ${ODM_FLAGS}
  fi
done

#Deploy any additional nodes (MicMac)
for (( n=$NODE_ODM+1; n<=$NODE_ODM+$NODE_MICMAC; n++ ))
do
  deploy_node nodemicmac$n nodemicmac dronemapper/node-micmac 3000 0
done

echo ${NODE_VOL_IDS[@]}
# Iterate the loop to read and print each array element
#for value in "${NODE_VOL_IDS[@]}"
#do
#  echo $value
#done

####################################################################################################
echo --- Phase 5b : Apps: ClusterODM
####################################################################################################

# Need to add all the running NodeODM instances to ClusterODM list via telnet interface

for (( n=1; n<=$NODE_ODM; n++ ))
do
  #Wait until node running
  wait_for_pod nodeodm$n
  #Fix the tmp path storage issue (writes to ./tmp in /var/www, need to use volume or fills ethemeral storage of docker image/node)
  echo kubectl exec nodeodm$n -- bash -c "if ! [ -L /var/www/tmp ] ; then rmdir /var/www/tmp; mkdir /var/www/data/tmp; ln -s /var/www/data/tmp /var/www/tmp; fi"
  kubectl exec nodeodm$n -- bash -c "if ! [ -L /var/www/tmp ] ; then rmdir /var/www/tmp; mkdir /var/www/data/tmp; ln -s /var/www/data/tmp /var/www/tmp; fi"
done

#Wait until clusterodm running
wait_for_pod clusterodm

#Get current list of running nodes
CODM_LIST=$(kubectl exec clusterodm -- bash -c "(sleep 1; echo 'NODE LIST'; sleep 1;) | telnet localhost 8080")

#Adding nodes to cluster via telnet interface - create the script
CLUSTER_NODES='(sleep 1; '
for (( n=1; n<=$NODE_ODM; n++ ))
do
  NODE_NAME=nodeodm$n
  if ! echo "$CODM_LIST" | grep "$NODE_NAME";
  then
    CLUSTER_NODES+="echo 'NODE ADD $NODE_NAME 3000'; sleep 1;"
  fi
done
CLUSTER_NODES+=') | telnet localhost 8080'

#If no nodes need adding, can skip this
if echo "$CLUSTER_NODES" | grep "node";
then
  #Exec command to set cluster nodes
  #(TODO: a better way would be for each node to add itself to the cluster on spinning up)
  echo $CLUSTER_NODES
  kubectl exec clusterodm -- bash -c "$CLUSTER_NODES"
  kubectl exec clusterodm -- bash -c "(sleep 1; echo 'NODE LIST'; sleep 1;) | telnet localhost 8080"
fi

####################################################################################################
echo --- Phase 5c : Deployment: Metashape
####################################################################################################

#Apply the secrets
#TODO: move secrets to secrets/secret.env and these to ./templates
kubectl apply -f metashape/dronedrive_secret.yaml

if [ "$NODE_METASHAPE" -gt "0" ]; then
  #Setup the cifs/smb volume mount - this has problems, keeps restarting
  # - Install csi plugin
  curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/install-driver.sh | bash -s master --
  # - Create persistent volume and claim
  kubectl apply -f metashape/csi-pv.yaml -f metashape/csi-pvc.yaml

  #Launch metashape server and load balancer service
  #(NOTE: we had to launch these in a separate VM on monash-02 instead
  # as monash-01 to monash-02 network is really broken right now
  # also - license server does not handle being run in a different container each time)
  #apply_template metashape-server.yaml
  #apply_template metashape-service.yaml
  #wait_for_pod metashape-server
fi

#Launch metashape processing nodes - require nvidia gpu resource
function deploy_metashape()
{
  #Deploy Metashape pod with unique name
  #$1 = id#
  export NODE_NAME=metashape-k8s$1
  if ! kubectl get pods | grep $NODE_NAME
  then
    echo ">>> METASHAPE NODE LAUNCH... " $NODE_NAME

    echo "Deploying $2 : $3 as $NODE_NAME"
    export NODE_TYPE="metashape"
    apply_template metashape.yaml
  fi
}

#Deploy Metashape nodes
for (( n=1; n<=$NODE_METASHAPE; n++ ))
do
  deploy_metashape $n
done


####################################################################################################
echo --- Phase 6a : Configuration: Floating IP
####################################################################################################

#Wait for the load balancer to be provisioned, necessary?
#echo "Waiting for load balancer IP"
EXTERNAL_IP=
while [ -z $EXTERNAL_IP ];
do
  printf '.';
  #EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.spec.loadBalancerIP}')
  EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  sleep 1
done
echo ""

#Used to open port if necessary... already open now but may be from previous test attempts
#PORT_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c Port -f value)
#openstack port show $PORT_ID -c security_group_ids -f value
#openstack port set --security-group http $PORT_ID #This was failing
echo "Ready at http://$EXTERNAL_IP"

#Check if the hostname resolves to an already defined floating-ip
WEBAPP_IP=$(getent hosts ${WEBAPP_HOST} | awk '{ print $1 }')
echo $WEBAPP_HOST resolves to $WEBAPP_IP

#Do we already have a floating-ip ready to use that our hostname points to?
#(should always be the case except on first spin-up as we want to keep this)
#FIP_ID=$(openstack floating ip list --floating-ip-address $WEBAPP_IP -c ID -f value)
FIP_ID=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'ID' -f value)
if [ -z ${FIP_ID} ];
then
  #Tag floating ips with their description, as we can't filter by description only tag
  FIPS=$(openstack floating ip list -c 'ID' -f value)
  for FIP_ID in ${FIPS}
  do
    DESC=$(openstack floating ip show $FIP_ID -c 'description' -f value)
    if [ ${DESC} ];
    then
      echo Tagging $FIP_ID with $DESC
      openstack floating ip set --tag='$DESC' $FIP_ID
    fi
  done

  #Check if floating ip already created and tagged for this hostname
  FP_ID=$(openstack floating ip list --tags ${WEBAPP_HOST} -c ID -f value)
  if [ -z ${FIP_ID} ];
  then
    #Create the floating ip that will be used from now on
    echo "Creating floating IP for $WEBAPP_HOST"
    #Getting network ID
    NET_ID=$(openstack network list --name=$NETWORK -c ID -f value)
    #Tag with the domain name to help with lookup
    openstack floating ip create $NET_ID --tag $WEBAPP_HOST --description $WEBAPP_HOST

    #Can set tag after if needed with
    #openstack floating ip set --tag='${WEBAPP_HOST}' $FP_ID
    #openstack floating ip set --description '${WEBAPP_HOST}' $FP_ID
    FP_ID=$(openstack floating ip list --tags ${WEBAPP_HOST} -c ID -f value)
    FLOATING_IP=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'Floating IP Address' -f value)
    echo "Please set your DNS for $WEBAPP_HOST to point to $FLOATING_IP"
    echo "...will loop until resolves: ctrl+c to abort"
    until [ ${WEBAPP_IP} = ${FLOATING_IP} ];
    do
      WEBAPP_IP=$(getent hosts ${WEBAPP_HOST} | awk '{ print $1 }');
      echo $WEBAPP_HOST resolves to $WEBAPP_IP
      sleep 5.0
    done

    #return 0
  else
    echo "Floating IP exists for $WEBAPP_HOST, but it resolves to $WEBAPP_IP, please check DNS entries"
    openstack floating ip show $FP_ID
    return 1
  fi
fi

#If we get to this point, we have
#1) Our own managed Floating IP (not created by k8s)
#2) DNS for our hostname correctly resolving to above floating ip
#3) webapp-service up and running ? - or use this ip to start it from template

#Get assigned IP details
EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
#EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.spec.loadBalancerIP}')
echo "Service ingress IP is : $EXTERNAL_IP"
FIXED_IP=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c 'Fixed IP Address' -f value)
echo "Associated internal Fixed IP is: $FIXED_IP"

#If webapp host resolves to this service load balancer IP, everything is good
if [ ${WEBAPP_IP} = ${EXTERNAL_IP} ] && [ ${FIXED_IP} != "None" ];
then
  echo "$WEBAPP_HOST ip matches service ip already, looks good to go"
else
  FLOATING_IP=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'Floating IP Address' -f value)
  echo "Floating IP found with tag $WEBAPP_HOST : $FLOATING_IP"
  #FIP_PORT=$(openstack floating ip list --tags ${WEBAPP_HOST} -c Port -f value)
  #FIP_PORT=$(openstack floating ip list --floating-ip-address $WEBAPP_IP -c Port -f value)

  echo Using this IP: $FLOATING_IP
  echo ID $FIP_ID
  #echo Port $FIP_PORT

  if [ ! $? ];
  then
    echo "No external IP available yet for load balancer, aborting"
    return 0
  fi
  PORT_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c Port -f value)
  echo Port $PORT_ID
  OLD_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c ID -f value)
  echo ID $OLD_ID

  #NOTE: there is an issue here if the FIP has been manually disassociated
  #need to detect and re-assign the port
  if [ ! -z ${OLD_ID} ];
  then
    if [ ${EXTERNAL_IP} != ${FLOATING_IP} ];
    then
      #Can only assign one external IP so must delete the generated one
      echo "Deleting assigned floating ip"
      openstack floating ip delete $OLD_ID
    else
      echo "WARNING: Designated floating IP already assigned to this service!"
      unset FIXED_IP #Skip re-assign
    fi
  else
    echo "WARNING: No existing floating IP assigned"
  fi

  if [ ! -z ${FIXED_IP} ];
  then
    echo "*** DEPRECATED - THIS SHOULD NOT BE REACHED!"
    return 1; 
    echo "Applying reserved floating ip"
    #Setup our reserved IP to point to the load-balancer service
    openstack floating ip set --port $PORT_ID --fixed-ip-address=$FIXED_IP $FIP_ID

    openstack floating ip list

    ping $WEBAPP_HOST -c 1

    echo "NOTE: must clear port of this floating ip before deleting services - or will be destroyed... use: ./asdc_update.sh ip"
    # ^^ Above is not true if service uses specific floating ip when created rather than replacing

    #Seems to work without writing this, but allows us to check the value on the service matches our floating IP
    kubectl patch svc webapp-service -p "{\"spec\": {\"loadBalancerIP\": \"${FLOATING_IP}\"}}"

  else
    echo "WARNING: No fixed IP found"
  fi
fi

####################################################################################################
echo --- Phase 6b : Configuration: SSL
####################################################################################################

#By default, webodm will attempt to setup SSL when enabled and no cert or key passed
#This does not seem to work through the loadbalancer, so initially we create a self signed cert
#Then manually run letsencrypt-autogen.sh after up and running

#Is SSL up and working yet?
if ! curl https://${WEBAPP_HOST};
then
  #Checks listening ports, requires nmap to be installed
  #kubectl exec webapp-worker -c webapp -- nmap -sT -O localhost

  #Wait for the server to be reachable with self-signed or provided certificate
  #(THIS CAN TAKE A WHILE)
  echo "Waiting for initial https service "
  while ! timeout 2.0 curl -k https://${WEBAPP_HOST} &> /dev/null;
    do printf '*';
    sleep 5;
  done;
  echo ""

  #If domain already has certificate issued, copy to local dir as cert.pem & key.pem
  #If not, will attempt to generate with letsencrypt
  echo "Checking for existing SSL cert..."
  #(file exists and length > 0)
  if [ ! -s "secrets/cert.pem" ] || [ ! -s "secrets/key.pem" ];
  then
    echo " - Not found, generating"
    #Kill nginx
    kubectl exec webapp-worker -c webapp -- killall nginx

    #Create cert
    kubectl exec webapp-worker -c webapp -- /bin/bash -c "WO_SSL_KEY='' /webodm/nginx/letsencrypt-autogen.sh"

    #Copy locally so will not be lost if pod deleted
    echo " - Copying to ./secrets"
    #(can't use kubectl cp for symlinks)
    kubectl exec --stdin --tty webapp-worker -c webapp -- cat /webodm/nginx/ssl/cert.pem > secrets/cert.pem
    kubectl exec --stdin --tty webapp-worker -c webapp -- cat /webodm/nginx/ssl/key.pem > secrets/key.pem
    chmod 600 secrets/*.pem

    #Restart nginx
    kubectl exec webapp-worker -c webapp -- nginx -c /webodm/nginx/nginx-ssl.conf
  fi;

fi

#Final URL
echo "Done. Access on https://$WEBAPP_HOST"

####################################################################################################
echo --- Phase 7 : Apps: Monitoring
####################################################################################################
# https://www.botkube.io/installation/slack/
kubectl create namespace botkube
helm repo add infracloudio https://infracloudio.github.io/charts
helm repo update

#Use values file instead
subst_template botkube-values.yaml
helm install --version v0.12.4 botkube --namespace botkube --wait -f yaml/botkube-values.yaml infracloudio/botkube


