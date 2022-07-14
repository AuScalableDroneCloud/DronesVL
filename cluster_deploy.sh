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
echo --- Phase 4a : Cluster node taints
####################################################################################################

#Until bug with nodegroup creation fixed, may have to skip this
if [ "$NODES_P4" -gt "0" ]; then
  nodegroup_wait $CLUSTER_BASE-P4
fi
if [ "$NODES_A40" -gt "0" ]; then
  nodegroup_wait $CLUSTER_BASE-A40
fi
if [ "$NODES_A100" -gt "0" ]; then
  nodegroup_wait $CLUSTER_BASE-A100
fi

#Need to re-create flannel pods after nodegroup created
export NODEGROUP_CREATED=1 #Need to force this if interrupted
if [ $NODEGROUP_CREATED == 1 ];
then
  #NOTE: this needs to be done a bit later, and at least twice
  #gpu-operator pods still struggle on a newly created nodegroup
  #without manually running this again
  kubectl -n kube-system delete pod -l app=flannel
  #kubectl -n kube-system delete pod -l k8s-app=calico-node

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
echo --- Phase 4e : Deployment: Metashape
####################################################################################################

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


