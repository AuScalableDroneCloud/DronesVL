####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, February 2022
#
# - Create kubernetes cluster nodegroup on openstack
# - This is a the compute cluster used to run ODM jobs and Jupyterhub pods
####################################################################################################

####################################################################################################
echo --- Phase 4 : Start the cluster nodes
####################################################################################################

#Load the settings, setup openstack and kubectl
source settings.env

if [ -z ${KUBECONFIG+x} ];
then
  echo "KUBECONFIG is unset, run : source asdc_run.sh to init cluster";
  exit
fi

#Setup node groups
NODEGROUP_CREATED=0

function create_cluster()
{
  #Create a cluster nodegroup
  #$1 : name
  #$2 : flavour
  #$3 : number of nodes
  #$4 : role
  if ! openstack coe nodegroup show $CLUSTER $1 -f value -c status;
  then
    echo "Cluster nodegroup $1 doesn't exist, creating"
    # https://docs.openstack.org/magnum/latest/user/#node-groups
    #(Will error if already created so ok to run again without check)
    openstack coe nodegroup create $CLUSTER $1 --flavor $2 \
      --min-nodes 1 --node-count $3 --role $4 \
      --docker-volume-size ${CLUSTER_DOCKER_VOL_SIZE} \
    #Labels don't seem to work at all... use magnum.openstack.role=cluster for nodeSelector
    #  --labels asdc.cloud.edu.au/type=$1,asdc.cloud.edu.au/compute=1 --merge-labels
    #NOTE: if usng the --labels option, also add --merge-labels or others will be cleared

    #If any nodegroups created, this flag triggers setting taints etc in cluster_deploy.sh
    NODEGROUP_CREATED=1
    sleep 1
  else
    echo "Cluster nodegroup $1 already exists"
  fi
}

if [ "$NODES_P4" -gt "0" ]; then
  create_cluster $NODEGROUP_BASE-P4 $CLUSTER_P4_FLAVOUR $NODES_P4 cluster
fi
if [ "$NODES_A40" -gt "0" ]; then
  create_cluster $NODEGROUP_BASE-A40 $CLUSTER_A40_FLAVOUR $NODES_A40 cluster
fi
if [ "$NODES_A100" -gt "0" ]; then
  create_cluster $NODEGROUP_BASE-A100 $CLUSTER_A100_FLAVOUR $NODES_A100 cluster
fi


#kubectl get all
#kubectl get all --all-namespaces
kubectl get nodes
kubectl get nodes -l magnum.openstack.org/role=cluster
#kubectl get nodes -l asdc.cloud.edu.au/type=a40
#kubectl get nodes -l nvidia.com/gpu.product=A40
#kubectl get nodes -l nvidia.com/gpu.product=A100
#kubectl get nodes -l nvidia.com/gpu.product=Tesla-P4

#To resize nodegroups
#openstack coe cluster resize $CLUSTER --nodegroup gpu-A40 2
#openstack coe cluster resize $CLUSTER --nodegroup gpu-A100 1

#Create the compute cluster
#source cluster_create.sh

####################################################################################################
echo --- Phase 5 : Cluster config and GPU setup, deploy nodes etc
####################################################################################################

####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, February 2022
#
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
  #$1 nodegroup name
  NSTATUS=$(openstack coe nodegroup show $CLUSTER $1 -f value -c status)
  if [[ "$NSTATUS" == *"$2"* ]]; then
    return 0
  fi
  return 1
}

function nodegroup_wait()
{
  #Wait until nodegroup complete
  #$1 nodegroup name
  until nodegroup_check $1 "COMPLETE"
  do
    printf "Nodegroup $NSTATUS "
    sleep 2
  done
}

####################################################################################################
echo --- Phase 5a : Cluster node taints
####################################################################################################

#Until bug with nodegroup creation fixed, may have to skip this
if [ "$NODES_P4" -gt "0" ]; then
  nodegroup_wait $NODEGROUP_BASE-P4
fi
if [ "$NODES_A40" -gt "0" ]; then
  nodegroup_wait $NODEGROUP_BASE-A40
fi
if [ "$NODES_A100" -gt "0" ]; then
  nodegroup_wait $NODEGROUP_BASE-A100
fi

export NODEGROUP_CREATED=1 #Need to force this if interrupted
if [ $NODEGROUP_CREATED == 1 ];
then
  #Apply some labels to the compute pods
  for node in $(kubectl get nodes -l magnum.openstack.org/role=cluster -ojsonpath='{.items[*].metadata.name}'); 
  do 
    kubectl label nodes $node asdc.cloud.edu.au/gpu=1 --overwrite
    #https://github.com/NVIDIA/gpu-operator/issues/322
    kubectl label nodes $node nvidia.com/mig.config=all-disabled --overwrite
    #kubectl get pods -A -owide --field-selector spec.nodeName=$node;
    kubectl taint nodes $node compute=true:NoSchedule --overwrite

    #Only use the compute hardware for jupyterhub
    #Use the compute nodes for jupyterhub pods
    #https://zero-to-jupyterhub.readthedocs.io/en/latest/administrator/optimization.html
    kubectl label nodes $node hub.jupyter.org/node-purpose=user --overwrite
    #Use PreferNoSchedule so pods other than jupyterhub will still run on these nodes if they tolerate compute=true
    #kubectl taint nodes $node hub.jupyter.org/dedicated=user:PreferNoSchedule
  done
  export NODEGROUP_CREATED=0
fi

####################################################################################################
echo --- Phase 6 : Deployment: Metashape
####################################################################################################

#THIS IS A LEGACY STEP - WHEN WE WANT TO RUN METASHAPE NODES AGAIN, USE FLUXCD

#Apply the secrets
if [ "$NODE_METASHAPE" -gt "0" ]; then
  #TODO: move secrets to secrets/secret.env and the rest to asdc-infra
  kubectl apply -f metashape/dronedrive_secret.yaml

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
fi


