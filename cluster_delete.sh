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
if [ "$NODES_P4" -gt "0" ]; then
  openstack coe nodegroup delete $CLUSTER $NODEGROUP_BASE-P4
fi
if [ "$NODES_A40" -gt "0" ]; then
  openstack coe nodegroup delete $CLUSTER $NODEGROUP_BASE-A40
fi
if [ "$NODES_A100" -gt "0" ]; then
  openstack coe nodegroup delete $CLUSTER $NODEGROUP_BASE-A100
fi

#openstack coe nodegroup show $CLUSTER $NODEGROUP_BASE-P4 -f value -c status

