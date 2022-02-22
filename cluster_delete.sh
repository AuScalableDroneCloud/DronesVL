####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, February 2022
#
# - Delete kubernetes cluster nodegroup on openstack
# - Leaves everything else in place
####################################################################################################

#Load the settings, setup openstack and kubectl
source settings.env

if [ -z ${KUBECONFIG+x} ];
then
  echo "KUBECONFIG is unset, run : source asdc_run.sh to init cluster";
  exit
fi

#Delete the cluster
openstack coe nodegroup delete $CLUSTER cluster-nodes

openstack coe nodegroup show $CLUSTER cluster-nodes -f value -c status

