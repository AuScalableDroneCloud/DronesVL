#!/bin/bash

#Get settings
source settings.env

#Need to clear port on our floating ip or it will be deleted with the cluster
./kube_freeip.sh

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

###DON'T DELETE VOLUMES UNLESS STARTING FROM SCRATCH
exit

#TODO: wait until DELETE_IN_PROGRESS over / cluster gone
echo "Waiting"
sleep 10

#Deleting test volumes - in production we would not do this!
delete_volume web-storage
delete_volume db-storage

for (( n=1; n<=$NODES; n++ ))
do
  delete_volume node$n-storage
done

unset KUBECONFIG
unset STACK_ID
