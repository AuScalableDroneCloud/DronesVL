####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, August 2020
#
# - Shutdown kubernetes cluster on openstack
# - Leaves persistent volumes in place
####################################################################################################

#Load the settings, setup openstack and kubectl
source settings.env

if [ -z ${KUBECONFIG+x} ];
then
  echo "KUBECONFIG is unset, run : source asdc_run.sh to init cluster";
  exit
fi

#Delete the cluster
openstack coe cluster delete $CLUSTER

#Remove the config file
rm ${KUBECONFIG}

