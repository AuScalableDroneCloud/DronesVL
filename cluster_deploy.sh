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

subst_template gpu-operator-values.yaml
#helm install gpu-operator --devel --namespace nvidia-gpu --wait -f yaml/gpu-operator-values.yaml nvidia/gpu-operator
helm install --wait --generate-name -n gpu-operator --create-namespace --wait -f yaml/gpu-operator-values.yaml nvidia/gpu-operator

####################################################################################################
echo --- Phase 4c : Deployment: NodeODM, ClusterODM
####################################################################################################
#Deploy processing nodes

#Deploy clusterODM
apply_template clusterodm.yaml 

#Get content of the setup script
export NODE_SETUP_SCRIPT_CONTENT=$(cat node_setup.sh | sed 's/\(.*\)/    \1/')

#Deploy NodeODM nodes (all GPU now, if we need CPU only can be restored)
export NODE_COUNT=$NODES
export NODE_TYPE=nodeodm
export NODE_IMAGE=opendronemap/nodeodm:gpu
#export NODE_IMAGE=opendronemap/nodeodm
export NODE_PORT=3000
export NODE_GPUS=1
export NODE_ARGS=${ODM_FLAGS_GPU}
#export NODE_ARGS=${ODM_FLAGS}
export NODE_VOLUME_SIZE=$NODE_VOLSIZE
apply_template nodeodm.yaml

#Deploy any additional nodes (MicMac)
#export NODE_COUNT=2
#export NODE_TYPE=nodemicmac
#export NODE_IMAGE=dronemapper/node-micmac
#export NODE_PORT=3000
#export NODE_GPUS=0
#export NODE_ARGS=""
#export NODE_VOLUME_SIZE=$NODE_VOLSIZE
#apply_template nodeodm.yaml

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


