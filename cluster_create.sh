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
  create_cluster $CLUSTER_BASE-P4 $CLUSTER_P4_FLAVOUR $NODES_P4 cluster
fi
if [ "$NODES_A40" -gt "0" ]; then
  create_cluster $CLUSTER_BASE-A40 $CLUSTER_A40_FLAVOUR $NODES_A40 cluster
fi
if [ "$NODES_A100" -gt "0" ]; then
  create_cluster $CLUSTER_BASE-A100 $CLUSTER_A100_FLAVOUR $NODES_A100 cluster
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
#openstack coe cluster resize $CLUSTER --nodegroup $CLUSTER_BASE-A40 2
#openstack coe cluster resize $CLUSTER --nodegroup $CLUSTER_BASE-A100 1

#Create the compute cluster
#source cluster_create.sh

####################################################################################################
echo --- Phase 5 : Cluster config and GPU setup, deploy nodes etc
####################################################################################################

source cluster_deploy.sh

