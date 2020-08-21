#!/bin/bash
openstack coe cluster delete $CLUSTER
function delete_volume()
{
  echo "Deleting volume $1"
  VOL_ID=`openstack volume show $1 -f value -c id`
  if [ $? -eq 0 ];
  then
    openstack volume delete $VOL_ID
  fi
}

echo "Waiting"
sleep 10

#Deleting test volumes - in production we would not do this!
delete_volume web-storage
delete_volume worker-storage
delete_volume db-storage

NODES=4 #Max nodes
for (( n=1; n<=$NODES; n++ ))
do
  delete_volume node$n-storage
done

unset KUBECONFIG
unset STACK_ID
