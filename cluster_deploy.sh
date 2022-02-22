####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, February 2022
#
# - Deploy kubernetes cluster nodegroup on openstack
# - This is a the compute cluster used to run ODM jobs and Jupyterhub pods
# - This script configures the cluster ready for use
####################################################################################################

#Load the settings, setup openstack and kubectl
source settings.env

if [ -z ${KUBECONFIG+x} ];
then
  echo "KUBECONFIG is unset, run : source asdc_run.sh to init cluster";
  exit
fi

function nodegroup_check()
{
  NSTATUS=$(openstack coe nodegroup show $CLUSTER cluster-nodes -f value -c status)
  if [[ "$NSTATUS" == *"$1"* ]]; then
    return 0
  fi
  return 1
}

####################################################################################################
echo --- Phase 4a : Cluster node taints
####################################################################################################

#Wait until nodegroup complete
until nodegroup_check "COMPLETE"
do
  printf "Nodegroup $NSTATUS "
  sleep 2
done

#Need to re-create flannel pods after nodegroup created
if [ $NODEGROUP_CREATED == 1 ];
then
  kubectl -n kube-system delete pod -l app=flannel

  # All gpu cluster nodes need to be tainted to prevent other pods running on them!
  #kubectl taint nodes $NODE key1=value1:NoSchedule
  #kubectl taint nodes $NODE compute=compute-jobs-only:NoSchedule
  for node in $(kubectl get nodes -l magnum.openstack.org/role=cluster -ojsonpath='{.items[*].metadata.name}'); 
  do 
    #kubectl get pods -A -owide --field-selector spec.nodeName=$node;
    kubectl taint nodes $node compute=true:NoSchedule

    #Use the compute nodes for jupyterhub pods
    #https://zero-to-jupyterhub.readthedocs.io/en/latest/administrator/optimization.html
    kubectl label nodes $node hub.jupyter.org/node-purpose=user
    #Use PreferNoSchedule so pods other than jupyterhub will still run on these nodes if they tolerate compute=true
    kubectl taint nodes $node hub.jupyter.org/dedicated=user:PreferNoSchedule
  done
fi

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

#TODO: re-enable this, but leaving commented for now as addition of namespace might confuse things until next cluster restart
subst_template gpu-operator-values.yaml
helm install gpu-operator --devel --namespace nvidia-gpu --wait -f yaml/gpu-operator-values.yaml nvidia/gpu-operator

####################################################################################################
echo --- Phase 4c : Deployment: NodeODM
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
echo --- Phase 4d : Apps: ClusterODM
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
echo --- Phase 4e : Deployment: Metashape
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


