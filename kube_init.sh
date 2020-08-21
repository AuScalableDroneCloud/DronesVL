#!/bin/bash

#Number of nodes in cluster
NODES=2
#Set cluster name
CLUSTER=odm-k8s-gpu
export CLUSTER=$CLUSTER
export NODES=$NODES

TEMPLATE=${CLUSTER}-template
KEYPAIR=ASDC_ODM
ZONE=monash-02
NETWORK=monash
MASTER_FLAVOUR=m3.large
FLAVOUR=mon.c22r60.gpu-p4

NODE_VOLSIZE=100
WEB_VOLSIZE=200
DB_VOLSIZE=1

if [[ "$0" = "$BASH_SOURCE" ]]; then
    echo "Please source this script. Do not execute."
    exit 1
fi

#Ensure ID set for openstack
if [ -z ${OS_PROJECT_ID+x} ];
then
  echo "OS_PROJECT_ID is unset";
  echo "Please source your openstack credentials"
  return 1
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

#Creating the template
if ! openstack coe cluster template show $TEMPLATE;
then
  echo "Creating cluster template: $TEMPLATE"
  openstack coe cluster template create $TEMPLATE --image fedora-atomic-latest --keypair $KEYPAIR --external-network $NETWORK --dns-nameserver 8.8.8.8 --flavor $FLAVOUR --master-flavor $MASTER_FLAVOUR --docker-volume-size 25 --docker-storage-driver overlay2 --network-driver flannel --coe kubernetes --volume-driver cinder --coe kubernetes --labels container_infra_prefix=docker.io/nectarmagnum/,cloud_provider_tag=v1.14.0,kube_tag=v1.14.6,master_lb_floating_ip_enabled=true,availability_zone=$ZONE
fi

#List running stacks
openstack stack list

STATUS=''
function get_status()
{
  #Get the status of the running cluster
  STATUS=`openstack coe cluster show $CLUSTER -f value -c status`
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
  sleep 0.5
done

#Once the cluster is running, get params and the config for kubectl
echo "Attempting to configure cluster";
#Finally setup the environment and export kubernetes config
export STACK_ID=`openstack coe cluster show $CLUSTER -f value -c stack_id`
export FLOATING_IP=`openstack stack output show $STACK_ID api_address -c output_value -f value`
export PORT_ID=`openstack floating ip show $FLOATING_IP -c port_id -f value`

#Open the port if not already done
SG_ID=`openstack security group show kubernetes-api -c id -f value`
if ! openstack port show $PORT_ID -c security_group_ids -f value | grep $SG_ID
then
  echo "SETTING PORT"
  openstack port set --security-group kubernetes-api $PORT_ID
else
  echo "PORT SET ALREADY"
fi
#Re-create the config
rm config
openstack coe cluster config $CLUSTER

export KUBECONFIG=`pwd`/config

#Add cwd to path so kubectl can be run without dir
export PATH=$PATH:`pwd`

kubectl get all --all-namespaces
#kubectl get nodes

#Volume creation unction
VOL_ID=''
function create_volume()
{
  #Create volume for server, args size in gb, label
  echo "Creating Volume '$2' of size $1 gb"
  openstack volume create --availability-zone $ZONE --size $1 $2
  VOL_ID=`openstack volume show $2 -f value -c id`
}

#Create persistent cinder volumes
if ! openstack volume show web-storage;
then
  #Create volume for server/webapp
  create_volume $WEB_VOLSIZE web-storage
  export WEB_VOLUME_ID=$VOL_ID
else
  export WEB_VOLUME_ID=`openstack volume show web-storage -c id -f value`
fi

if ! openstack volume show db-storage;
then
  #Create volumes for db
  create_volume $DB_VOLSIZE db-storage
  export DB_VOLUME_ID=$VOL_ID
else
  export DB_VOLUME_ID=`openstack volume show db-storage -c id -f value`
fi

#Apply the storage IDs to the persistent volumes and volume sizes to volumes/claims
export DB_VOLUME_SIZE=$DB_VOLSIZE
export WEBAPP_VOLUME_SIZE=$WEB_VOLSIZE
cat templates/webapp-persistentvolume.yaml | envsubst > webapp-persistentvolume.yaml
cat templates/dbdata-persistentvolume.yaml | envsubst > dbdata-persistentvolume.yaml
cat templates/webapp-persistentvolumeclaim.yaml | envsubst > webapp-persistentvolumeclaim.yaml
cat templates/dbdata-persistentvolumeclaim.yaml | envsubst > dbdata-persistentvolumeclaim.yaml

#Deploy the server WebODM instance
kubectl create -f dbdata-persistentvolume.yaml,webapp-persistentvolume.yaml,db-service.yaml,db-deployment.yaml,dbdata-persistentvolumeclaim.yaml,broker-deployment.yaml,webapp-worker-pod.yaml,webapp-persistentvolumeclaim.yaml,broker-service.yaml

#Having issues with LoadBalancer service, in the meantime using this
#NodePort - uses the node's IP, with randomly generated port
kubectl expose pod webapp-worker  --target-port=8000 --type=NodePort

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
    VOL_ID=`openstack volume show $VOL -c id -f value`
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
export NODE_VOL_IDS=$NODE_VOL_IDS

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
echo $CLUSTER_NODES
kubectl exec clusterodm -- bash -c "$CLUSTER_NODES"
kubectl exec clusterodm -- bash -c "(sleep 1; echo 'NODE LIST'; sleep 1;) | telnet localhost 8080"

#TODO:
#Fix the loadbalancer service rather than using NodePort
#Better shared storage, nfs or similar

kubectl get pods
kubectl get svc

#For debugging... log in to pod shell
#kubectl exec --stdin --tty webapp-worker -- /bin/bash

#To specify alternate container in multi-container pod
#kubectl exec --stdin --tty webapp-worker -c worker -- /bin/bash

