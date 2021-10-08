####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, August 2020
#
# - This script contains several operations to apply to the running cluster, 
#   such as restarting pods for updates or reconfiguring the live cluster
#
# ./asdc_update.sh webapp - update the webapp/worker pod
#                           use this when the image has been modified,
#                           to get the latest code into live instance
#
# ./asdc_update.sh ip - unassign floating ip from webapp loadbalancer service,
#                       always use this before deleting webapp-service or shutting down cluster
#                       (is called by asdc_stop.sh so don't need to run explicitly in this case)
#
# ./asdc_update.sh web-storage-resize - resize the webapp storage volume to value in settings.env
#                       resizes the openstack cinder volume, then runs a pod that calls resize2fs
#                       to expand the filesystem to match
#
# ./asdc_update.sh db-storage-resize - resize the database storage volume to value in settings.env
#                       resizes the openstack cinder volume, then runs a pod that calls resize2fs
#                       to expand the filesystem to match
#
# It is intended to add further options for other components
####################################################################################################

#Load the settings, setup openstack and kubectl
source settings.env

if [ $# -eq 0 ]
then
  echo "No arguments supplied"
  exit
fi

if [ -z ${KUBECONFIG+x} ];
then
  echo "KUBECONFIG is unset, run : source asdc_run.sh to init cluster";
  exit
fi

if [ "$1" = "webapp" ];
then
  #Delete the worker pod to force rebuild
  kubectl delete pod webapp-worker

  echo "webapp-worker deleted successfully, running asdc_run.sh to re-create and initialise the webapp pod..."
  source asdc_run.sh

elif [ "$1" = "web-storage-resize" ];
then

  #Resize the web-storage volume (experimental)
  # first set the new volume size in settings.env and run 'source settings.env'
  kubectl delete pod webapp-worker
  kubectl delete pvc webapp-claim0
  kubectl delete pv webapp-volume

  openstack volume set --size ${WEBAPP_VOLUME_SIZE} web-storage

  #Re-apply the volume sizes to volumes/claims
  export WEB_VOLUME_ID=$(openstack volume show web-storage -c id -f value)
  cat templates/webapp-persistentvolume.yaml | envsubst > webapp-persistentvolume.yaml
  cat templates/webapp-persistentvolumeclaim.yaml | envsubst > webapp-persistentvolumeclaim.yaml

  #Re-create with resizer pod
  #(runs privileged and uses resize2fs to resize the ext4 fs)
  kubectl create -f resize-webapp-volume.yaml,webapp-persistentvolume.yaml,webapp-persistentvolumeclaim.yaml

  sleep 5

  echo "running asdc_run.sh to re-create and initialise the webapp pod..."
  source asdc_run.sh

elif [ "$1" = "db-storage-resize" ];
then

  #Resize the db-storage volume (experimental)
  # first set the new volume size in settings.env and run 'source settings.env'
  kubectl delete deployment db
  kubectl delete pvc dbdata
  kubectl delete pv dbvolume

  openstack volume set --size ${DB_VOLUME_SIZE} db-storage

  #Re-apply the volume sizes to volumes/claims
  export DB_VOLUME_ID=$(openstack volume show db-storage -c id -f value)
  cat templates/dbdata-persistentvolume.yaml | envsubst > dbdata-persistentvolume.yaml
  cat templates/dbdata-persistentvolumeclaim.yaml | envsubst > dbdata-persistentvolumeclaim.yaml

  #Re-create with resizer pod
  #(runs privileged and uses resize2fs to resize the ext4 fs)
  kubectl create -f resize-dbvolume.yaml,dbdata-persistentvolume.yaml,dbdata-persistentvolumeclaim.yaml

  sleep 5

  echo "running asdc_run.sh to re-create and initialise the webapp pod..."
  source asdc_run.sh

elif [ $1 = "ip" ];
then
  #Need to clear port on our floating ip or it will be deleted with the cluster
  FLOATING_IP=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'Floating IP Address' -f value)
  FIP_ID=$(openstack floating ip list --floating-ip-address $FLOATING_IP -c ID -f value)
  openstack floating ip unset --port $FIP_ID

  openstack floating ip list

  #Ensure the floating-ip is no longer assigned to our fixed ip
  #WARNING: if above fails, and this runs, ip will be destroyed, so check, or do this manually...
  FIXED_IP=$(openstack floating ip list --floating-ip-address $FLOATING_IP -c 'Fixed IP Address' -f value)
  if [ ${FIXED_IP} == "None" ];
  then
    echo "Can now delete webapp-service, floating ip has been directed to: " ${FIXED_IP}
    #Just delete it, as once the ip is disassociated it's easier to just re-create than patch the service again
    kubectl delete service webapp-service
  else
    echo "WARNING: a service still appears to be attached to floating ip, DO NOT DELETE " ${FIXED_IP}
  fi

fi

