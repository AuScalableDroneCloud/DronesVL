#!/bin/bash

# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, August 2020
#
# - Provision a kubernetes cluster using OpenStack cluter orchestration engine
# - Launch a WebODM instance, a NodeODM instance per cluster node and other required services to connect them

#TODO:
# - Better shared storage pool between nodes, nfs or similar

####################################################################################################################
echo --- Phase 1 : Setup
####################################################################################################################

#Load the settings
source settings.env

if [[ "$0" = "$BASH_SOURCE" ]]; then
    echo "Please source this script. Do not execute."
    exit 1
fi

#Ensure ID set for openstack
if [ -z ${OS_PROJECT_ID+x} ];
then
  echo "OS_PROJECT_ID is unset";
  FILE=Monash-Drone-openrc.sh
  if [ -f $FILE ]; then
    echo "Using $FILE."
    source Monash-Drone-openrc.sh
  else
    echo "File $FILE does not exist."
    echo "Please source your openstack credentials"
    return 1
  fi
else
  echo "OS_PROJECT_ID is set to '$OS_PROJECT_ID'";
fi

#This script sets KUBECONFIG, if already set then return/exit
if [ -z ${KUBECONFIG+x} ];
then
  echo "KUBECONFIG is unset, attempting to init cluster";
else
  echo "KUBECONFIG is already set to '$KUBECONFIG'";
  echo "run 'unset KUBECONFIG' first if you want to rerun";
  return 0
fi

#DEBUG - delete the existing template to apply changes / edits
#openstack coe cluster template delete $TEMPLATE;

#Creating the template
if ! openstack coe cluster template show $TEMPLATE;
then
  #See: https://docs.openstack.org/magnum/latest/user/
  echo "Creating cluster template: $TEMPLATE"
  #Floating ip disabled, master-lb-enabled, master-lb-floating-ip enabled
  openstack coe cluster template create $TEMPLATE --image fedora-atomic-latest --keypair $KEYPAIR --external-network $NETWORK --floating-ip-disabled --master-lb-enabled --dns-nameserver 8.8.8.8 --flavor $FLAVOUR --master-flavor $MASTER_FLAVOUR --docker-volume-size 25 --docker-storage-driver overlay2 --network-driver flannel --coe kubernetes --volume-driver cinder --coe kubernetes --labels container_infra_prefix=docker.io/nectarmagnum/,cloud_provider_tag=v1.14.0,kube_tag=v1.14.6,master_lb_floating_ip_enabled=true,availability_zone=$ZONE

  #Floating ip enabled
  #openstack coe cluster template create $TEMPLATE --image fedora-atomic-latest --keypair $KEYPAIR --external-network $NETWORK --dns-nameserver 8.8.8.8 --flavor $FLAVOUR --master-flavor $MASTER_FLAVOUR --docker-volume-size 25 --docker-storage-driver overlay2 --network-driver flannel --coe kubernetes --volume-driver cinder --coe kubernetes --labels container_infra_prefix=docker.io/nectarmagnum/,cloud_provider_tag=v1.14.0,kube_tag=v1.14.6,master_lb_floating_ip_enabled=false,availability_zone=$ZONE
fi

#List running stacks
openstack stack list


####################################################################################################################
echo --- Phase 2 : Cluster Launch
####################################################################################################################

STATUS=''
function get_status()
{
  #Get the status of the running cluster
  STATUS=$(openstack coe cluster show $CLUSTER -f value -c status)
}

function cluster_check()
{
  if [ "$STATUS" == $1 ]; then
    return 0
  fi
  return 1
}

function cluster_launched()
{
  if cluster_check "CREATE_COMPLETE" ; then
    return 0
  fi
  if cluster_check "CREATE_IN_PROGRESS"; then
    return 0
  fi
  return 1
}

#Create the cluster, wait until complete
get_status
if cluster_check "CREATE_FAILED"; then
  echo "Cluster create failed!"
  return 1
fi
if ! cluster_launched; then
  #Create the cluster from default template
  openstack coe cluster create --cluster-template $TEMPLATE --keypair $KEYPAIR --master-count 1 --node-count $NODES $CLUSTER
  echo "Cluster create initiated..."
fi

#Wait until cluster complete
until cluster_check "CREATE_COMPLETE"
do
  get_status
  echo $STATUS
  if cluster_check "CREATE_FAILED"; then
    echo "Cluster create failed!"
    return 1
  fi
  sleep 2
done

#WITHOUT FLOATING-IPS ENABLED, NEED TO WAIT FOR LB TO START??
#Wait for the load balancer to be provisioned
STACK_ID=$(openstack coe cluster show $CLUSTER -f value -c stack_id)
FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
while ! timeout 0.2 ping -c 1 -n ${FLOATING_IP} &> /dev/null;
do
  echo "Waiting for master-lb to be assigned floating IP, current api_address = $FLOATING_IP"
  FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
  sleep 1
done

#Once the cluster is running, get params and the config for kubectl
echo "Attempting to configure cluster";
#Finally setup the environment and export kubernetes config
: '
STACK_ID=$(openstack coe cluster show $CLUSTER -f value -c stack_id)
FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
PORT_ID=$(openstack floating ip show $FLOATING_IP -c port_id -f value)

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

#Re-create the config
rm config
openstack coe cluster config $CLUSTER

export KUBECONFIG=$(pwd)/config

#Add cwd to path so kubectl can be run without dir
PATH=$PATH:$(pwd)

kubectl get all --all-namespaces
#kubectl get nodes


####################################################################################################################
echo --- Phase 3a : Deployment: Volumes and storage
####################################################################################################################

#Volume creation unction
VOL_ID=''
function create_volume()
{
  #Create volume for server, args size in gb, label
  echo "Creating Volume '$2' of size $1 gb"
  openstack volume create --availability-zone $ZONE --size $1 $2
  VOL_ID=$(openstack volume show $2 -f value -c id)
}

#Create persistent cinder volumes
if ! openstack volume show web-storage;
then
  #Create volume for server/webapp
  create_volume $WEBAPP_VOLUME_SIZE web-storage
  export WEB_VOLUME_ID=$VOL_ID
else
  export WEB_VOLUME_ID=$(openstack volume show web-storage -c id -f value)
fi

if ! openstack volume show db-storage;
then
  #Create volumes for db
  create_volume $DB_VOLUME_SIZE db-storage
  export DB_VOLUME_ID=$VOL_ID
else
  export DB_VOLUME_ID=$(openstack volume show db-storage -c id -f value)
fi

#Apply the storage IDs to the persistent volumes and volume sizes to volumes/claims
cat templates/webapp-persistentvolume.yaml | envsubst > webapp-persistentvolume.yaml
cat templates/dbdata-persistentvolume.yaml | envsubst > dbdata-persistentvolume.yaml
cat templates/webapp-persistentvolumeclaim.yaml | envsubst > webapp-persistentvolumeclaim.yaml
cat templates/dbdata-persistentvolumeclaim.yaml | envsubst > dbdata-persistentvolumeclaim.yaml

####################################################################################################################
echo --- Phase 3b : Deployment: pods
####################################################################################################################

#Apply hostname to webapp-worker
cat templates/webapp-worker-pod.yaml | envsubst > webapp-worker-pod.yaml

#Deploy the server WebODM instance
kubectl create -f dbdata-persistentvolume.yaml,webapp-persistentvolume.yaml,db-service.yaml,db-deployment.yaml,dbdata-persistentvolumeclaim.yaml,broker-deployment.yaml,webapp-worker-pod.yaml,webapp-persistentvolumeclaim.yaml,broker-service.yaml,webapp-service.yaml

#Create volume for node(s)
NODE_VOL_IDS=()
for (( n=1; n<=$NODES; n++ ))
do
  VOL=node$n-storage
  if ! openstack volume show $VOL;
  then
    create_volume $NODE_VOLSIZE $VOL
    NODE_VOL_IDS+=( $VOL_ID )
  else
    VOL_ID=$(openstack volume show $VOL -c id -f value)
    NODE_VOL_IDS+=( $VOL_ID )
  fi

  #Deploy NodeODM pod using name and volume ID
  export NODE_NAME=nodeodm$n
  export NODE_VOLUME_ID=$VOL_ID
  cat templates/nodeodm.yaml | envsubst > nodeodm.yaml
  cat templates/nodeodm-service.yaml | envsubst > nodeodm-service.yaml
  kubectl apply -f nodeodm.yaml
  kubectl apply -f nodeodm-service.yaml
done

echo ${NODE_VOL_IDS[@]}
# Iterate the loop to read and print each array element
#for value in "${NODE_VOL_IDS[@]}"
#do
#  echo $value
#done


#Adding nodes to cluster via telnet interface
CLUSTER_NODES='(sleep 1; '
for (( n=1; n<=$NODES; n++ ))
do
  NODE_NAME=nodeodm$n
  CLUSTER_NODES+="echo 'NODE ADD $NODE_NAME 3000'; sleep 1;"
done
CLUSTER_NODES+=') | telnet localhost 8080'


#Launch clusterodm instance
kubectl apply -f clusterodm.yaml
kubectl apply -f clusterodm-service.yaml

#Wait until clusterodm running
until kubectl get pods --field-selector status.phase=Running | grep clusterodm
do
  echo "Waiting for clusterodm"
  sleep 0.5
done

#Exec command to set cluster nodes
#(TODO: a better way would be for each node to add itself to the cluster on spinning up)
echo $CLUSTER_NODES
kubectl exec clusterodm -- bash -c "$CLUSTER_NODES"
kubectl exec clusterodm -- bash -c "(sleep 1; echo 'NODE LIST'; sleep 1;) | telnet localhost 8080"

#Wait for the load balancer to be provisioned
while [ -z $EXTERNAL_IP ];
do
  echo "Waiting for load balancer IP"
  EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  sleep 0.5
done

#Used to open port if necessary... already open now but may be from previous test attempts
#PORT_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c Port -f value)
#openstack port show $PORT_ID -c security_group_ids -f value
#openstack port set --security-group http $PORT_ID #This was failing
echo "Accessible on http://$EXTERNAL_IP"

kubectl get pods
kubectl get svc

#For debugging... log in to pod shell
#kubectl exec --stdin --tty webapp-worker -- /bin/bash

#Get output
#kubectl logs webapp-worker -c worker

#To specify alternate container in multi-container pod
#kubectl exec --stdin --tty webapp-worker -c worker -- /bin/bash

#When all is ready, start the web app (requires DNS resolution to hostname working for SSL cert)
#kubectl exec webapp-worker -c webapp -- /webodm/start.sh


####################################################################################################################
echo --- Phase 4a : Configuration: Floating IP
####################################################################################################################

#Getting network ID
NET_ID=$(openstack network list --name=$NETWORK -c ID -f value)

#Create our own floating-ip which will be set in DNS for our hostname
#Have not found a way to pass to load-balancer/service creation, so...
#1) Get port and local IP from load-balancer
#2) Delete lb assigned floating ip
#3) Set this fip to replace it

#Check if the hostname resolves to an already defined floating-ip
WEBAPP_IP=$(getent hosts ${WEBAPP_HOST} | awk '{ print $1 }')
echo $WEBAPP_HOST resolves to $WEBAPP_IP

#FIP_ID=$(openstack floating ip list --floating-ip-address $WEBAPP_IP -c ID -f value)
FIP_ID=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'ID' -f value)
if [ -z ${FIP_ID} ];
then
  #Check if floating ip alreasy created and tagged for this hostname
  FP_ID=$(openstack floating ip list --tags ${WEBAPP_HOST} -c ID -f value)
  if [ -z ${FIP_ID} ];
  then
    #Create the floating ip that will be used from now on
    echo "Creating floating IP for $WEBAPP_HOST"
    #Tag with the domain name to help with lookup
    openstack floating ip create $NET_ID --tag $WEBAPP_HOST
    #Can set tag after if needed with
    #openstack floating ip set --tag='${WEBAPP_HOST}' $FP_ID
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
FLOATING_IP=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'Floating IP Address' -f value)
echo "Floating IP found with tag $WEBAPP_HOST : $FLOATING_IP"
#FIP_PORT=$(openstack floating ip list --tags ${WEBAPP_HOST} -c Port -f value)
#FIP_PORT=$(openstack floating ip list --floating-ip-address $WEBAPP_IP -c Port -f value)

echo New IP $FLOATING_IP
echo ID $FIP_ID
#echo Port $FIP_PORT

############################
#OPTIONS
# a) use current setup with LoadBalancer and swap out the IPS
# b) attempt to use ExternalIP service and provide our IP directly without LB
#https://kubernetes.io/docs/concepts/services-networking/service/#external-ips

#Get assigned IP details
EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ ! $? ];
then
  echo "No external IP available yet for load balancer, aborting"
  return 0
fi
echo Ext IP $EXTERNAL_IP
FIXED_IP=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c 'Fixed IP Address' -f value)
echo Fixed IP $FIXED_IP
PORT_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c Port -f value)
echo Port $PORT_ID
OLD_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c ID -f value)
echo ID $OLD_ID

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
  echo "Applying reserved floating ip"
  #Setup our reserved IP to point to the load-balancer service
  openstack floating ip set --port $PORT_ID --fixed-ip-address=$FIXED_IP $FIP_ID

  openstack floating ip list

  ping $WEBAPP_HOST -c 1

  echo "NOTE: must clear port of this floating ip before deleting services - or will be destroyed... use: ./kube_freeip.sh"

  #Necessary?
  kubectl patch svc webapp-service -p "{\"spec\": {\"loadBalancerIP\": \"${FLOATING_IP}\"}}"

else
  echo "WARNING: No fixed IP found"
fi

####################################################################################################################
echo --- Phase 4b : Configuration: SSL
####################################################################################################################

#By default, webodm will attempt to setup SSL when enabled and no cert of key passed
#This does not seem to work through the loadbalancer, so initially we create a self signed cert
#Then manually run letsencrypt-autogen.sh after up and running
#TODO: handle renew
# - run certbot renew
# - copy updated certs to local backup

kubectl exec webapp-worker -c webapp -- nmap -sT -O localhost

#Wait for the server to be reachable with self-signed certificate
#(THIS CAN TAKE A WHILE)
#while ! wget https://${WEBAPP_HOST} --no-check-certificate -O /dev/null;
while ! timeout 5.0 wget https://${WEBAPP_HOST} --no-check-certificate -O /dev/null;
  do printf '*';
  sleep 5;
done;

#Kill nginx
kubectl exec webapp-worker -c webapp -- killall nginx

#If domain already has certificate issued, copy to local dir as cert.pem & key.pem
#If not, will attempt to generate with letsencrypt
if [ ! -s "cert.pem" ] || [ ! -s "key.pem" ];
then
  #Create cert
  kubectl exec webapp-worker -c webapp -- /bin/bash -c "WO_SSL_KEY='' /webodm/nginx/letsencrypt-autogen.sh"

  #Copy locally so will not be lost if pod deleted
  kubectl cp webapp-worker:/webodm/nginx/ssl/cert.pem cert.pem -c webapp
  kubectl cp webapp-worker:/webodm/nginx/ssl/key.pem key.pem -c webapp
else
  #Copy in cert from local
  kubectl cp cert.pem webapp-worker:/webodm/nginx/ssl/cert.pem -c webapp
  kubectl cp key.pem webapp-worker:/webodm/nginx/ssl/key.pem -c webapp
fi;

#Restart nginx
kubectl exec webapp-worker -c webapp -- nginx -c /webodm/nginx/nginx-ssl.conf

#Final URL
echo "Done. Access on http://$WEBAPP_HOST"

