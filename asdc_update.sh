####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, August 2020
#
# - This script applies any changes to deployment settings to the live cluster
#
# ./asdc_update.sh - update the configmaps and secrets only
#                    use this to quickly apply modified values to the live cluster.
#
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
#apply_template storage-classes.yaml

# csi-rclone config secrets
#apply_template rclone-secret.yaml #Old rclone csi - deprecated
apply_template csi-s3-secret.yaml #New version k8s-csi-s3

#AWS S3 setup - required if tusd is to use object storage
#Also now used for filestash testing
#apply_template s3-secret.yaml

#MOVED TO FLUX
#https://github.com/yandex-cloud/k8s-csi-s3
#https://github.com/yandex-cloud/k8s-csi-s3/tree/master/deploy/helm
#helm install --namespace kube-system csi-s3 ./k8s-csi-s3/deploy/helm/

#Use the plain k8s scripts as this will work better in flux
#kubectl create -f k8s-csi-s3/deploy/kubernetes/csi-s3.yaml
#kubectl create -f k8s-csi-s3/deploy/kubernetes/attacher.yaml
#kubectl create -f k8s-csi-s3/deploy/kubernetes/provisioner.yaml
#kubectl create -f k8s-csi-s3/deploy/kubernetes/examples/storageclass.yaml

#####################################################
echo "Upating ConfigMaps and Secret data for FluxCD..."
#####################################################

#Apply the configMap and secret data for fluxcd
#Get content of the setup scripts
export NODEODM_SETUP_SCRIPT_CONTENT=$(cat scripts/node_setup.sh | sed 's/\(.*\)/    \1/')
export WEBODM_SETUP_SCRIPT_CONTENT=$(cat scripts/asdc_init.sh | sed 's/\(.*\)/    \1/')
export DATABASE_CHECK_SCRIPT_CONTENT=$(cat scripts/db_check.sh | sed 's/\(.*\)/    \1/')

#Export all required settings env variables to this ConfigMap
apply_template flux-configmap.yaml

#####################################################
echo "Checking database volume size..."
#####################################################
#Check DB storage volume size has not been increased in settings.env
DBSIZE=$(openstack volume show db-storage -f value -c size)
if [ ${DB_VOLUME_SIZE} -gt ${DBSIZE} ]; then 
  echo "RESIZING DB VOLUME, delete pods..."
  kubectl delete deployment db
  echo "sleep 10"
  sleep 10
  echo "Delete pv/pvc"
  kubectl delete pvc db-pvc
  kubectl delete pv db-volume
  echo "sleep 5"
  sleep 5
  echo "Resize now"
  openstack volume set --size ${DB_VOLUME_SIZE} db-storage
  #Restart
  flux reconcile kustomization apps --with-source
fi

