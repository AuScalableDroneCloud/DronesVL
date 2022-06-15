####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, August 2020
#
# - This script contains several operations to apply to the running cluster, 
#   such as restarting pods for updates or reconfiguring the live cluster
#
# ./asdc_update.sh - update the configmaps and secrets only
#                    use this to quickly apply modified values to the live cluster.
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

if [[ ${BASH_SOURCE[0]} != $0 ]]; then
   printf "script '%s' is sourced in\n" "${BASH_SOURCE[0]}"
   return
fi

#Load the settings, setup openstack and kubectl
source settings.env

#####################################################
echo "Configuring storage..."
#####################################################

# Create StorageClasses for dynamic provisioning
apply_template storage-classes.yaml

# csi-rclone config secrets
#apply_template rclone-secret.yaml #Old rclone csi - deprecated
apply_template csi-s3-secret.yaml #New version k8s-csi-s3

#AWS S3 setup - required if tusd is to use object storage
#Also now used for filestash testing
#apply_template s3-secret.yaml

#https://github.com/yandex-cloud/k8s-csi-s3
#https://github.com/yandex-cloud/k8s-csi-s3/tree/master/deploy/helm
helm install --namespace kube-system csi-s3 ./k8s-csi-s3/deploy/helm/

#####################################################
echo "Upating ConfigMaps and Secret data for FluxCD..."
#####################################################

#Apply the configMap and secret data for fluxcd
#Get content of the setup scripts
export NODEODM_SETUP_SCRIPT_CONTENT=$(cat node_setup.sh | sed 's/\(.*\)/    \1/')
export WEBODM_SETUP_SCRIPT_CONTENT=$(cat asdc_init.sh | sed 's/\(.*\)/    \1/')

#Export all required settings env variables to this ConfigMap
apply_template flux-configmap.yaml
#####################################################

if [ $# -eq 0 ]
then
  echo "No arguments supplied, no further tasks, exiting"
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

elif [ "$1" = "tusd" ];
then
  helm uninstall tusd
  echo "tusd deleted successfully, re-installing..."
  kubectl apply -f uppy/s3-secret.yaml
  kubectl apply -f uppy/tusd-pvc.yaml
  helm install tusd --wait -f uppy/tusd-values.yaml skm/tusd

elif [ "$1" = "web-storage-resize" ];
then
  #Resize the web-storage volume (experimental)
  # first set the new volume size in settings.env and run 'source settings.env'
  kubectl delete pod webapp-worker-0
  kubectl delete pvc webapp-pvc
  kubectl delete pv webapp-volume

  openstack volume set --size ${WEBAPP_VOLUME_SIZE} web-storage

  #Re-apply the volume sizes to volumes/claims
  export WEB_VOLUME_ID=$(openstack volume show web-storage -c id -f value)
  apply_template webapp-volume.yaml

  #Re-create with resizer pod
  #(runs privileged and uses resize2fs to resize the ext4 fs)
  kubectl create -f utils/resize-webapp-volume.yaml

  sleep 5

  #Re-deploy webapp
  apply_template webapp-worker.yaml

elif [ "$1" = "db-storage-resize" ];
then
  #Resize the db-storage volume (experimental)
  # first set the new volume size in settings.env and run 'source settings.env'
  kubectl delete deployment db
  kubectl delete pvc db-pvc
  kubectl delete pv db-volume

  openstack volume set --size ${DB_VOLUME_SIZE} db-storage

  #Re-apply the volume sizes to volumes/claims
  export DB_VOLUME_ID=$(openstack volume show db-storage -c id -f value)
  apply_template db-volume.yaml

  #Re-create with resizer pod
  #(runs privileged and uses resize2fs to resize the ext4 fs)
  kubectl create -f utils/resize-dbvolume.yaml

  sleep 5

  #Re-deploy database
  apply_template db-deployment.yaml

fi

