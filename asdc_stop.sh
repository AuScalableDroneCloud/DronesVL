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

#Need to clear port on our floating ip or it will be deleted with the cluster
./asdc_update.sh ip

#Delete the cluster
openstack coe cluster delete $CLUSTER
function delete_volume()
{
  echo "Deleting volume $1"
  VOL_ID=$(openstack volume show $1 -f value -c id)
  if [ $? -eq 0 ];
  then
    openstack volume delete $VOL_ID
  fi
}

#Remove the config file
rm config

###DON'T DELETE VOLUMES UNLESS STARTING FROM SCRATCH
exit
####################################################################################################

#TODO: wait until DELETE_IN_PROGRESS over / cluster gone
echo "Waiting"
sleep 10

#Deleting test volumes - in production we would not do this!
delete_volume web-storage
delete_volume db-storage

for (( n=1; n<=$NODES; n++ ))
do
  delete_volume nodeodm$n-storage
done

delete_volume clusterodm-storage
delete_volume nodemicmac-storage
unset KUBECONFIG
unset STACK_ID

