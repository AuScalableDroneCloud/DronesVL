####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, February 2022
#
# - Create kubernetes cluster nodegroup on openstack
# - This is a the compute cluster used to run ODM jobs and Jupyterhub pods
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
if ! openstack coe nodegroup show $CLUSTER cluster-nodes -f value -c status;
then
  echo "Cluster nodegroup doesn't exist, creating"
  # https://docs.openstack.org/magnum/latest/user/#node-groups
  #(Will error if already created so ok to run again without check)
  openstack coe nodegroup create $CLUSTER cluster-nodes --flavor $CLUSTER_FLAVOUR --min-nodes $NODES --node-count $NODES --role cluster 
  NODEGROUP_CREATED=1
fi
#Second cluster group? (once more hardware available)
#openstack coe nodegroup create $CLUSTER cluster2-nodes --flavor $CLUSTER2_FLAVOUR --min-nodes $NODES --node-count $NODES --role cluster

#kubectl get all
#kubectl get all --all-namespaces
kubectl get nodes


