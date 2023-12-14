#!/bin/bash
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
echo "Upating ConfigMaps and Secret data for FluxCD..."
#####################################################

#Apply the configMap and secret data for fluxcd
#Get content of the setup scripts
export NODEODM_SETUP_SCRIPT_CONTENT=$(cat scripts/node_setup.sh | sed 's/\(.*\)/    \1/')
export WEBODM_SETUP_SCRIPT_CONTENT=$(cat scripts/asdc_init.sh | sed 's/\(.*\)/    \1/')
export DATABASE_CHECK_SCRIPT_CONTENT=$(cat scripts/db_check.sh | sed 's/\(.*\)/    \1/')
export JUPYTERHUB_CONFIG_SCRIPT_CONTENT=$(cat scripts/jupyterhub_config.py | envsubst | sed 's/\(.*\)/    \1/')
export JUPYTERHUB_START_SCRIPT_CONTENT=$(cat scripts/asdc-start-notebook.sh | sed 's/\(.*\)/    \1/')

kubectl delete secret jwt-keys-secret
kubectl create secret generic jwt-keys-secret \
    --from-file=public_key=$JWT_KEY.pub \
    --from-file=private_key=$JWT_KEY

#Create required directories
mkdir yaml 2>/dev/null

#Export all required settings env variables to this ConfigMap
apply_template flux-configmap.yaml

#####################################################
echo "Checking database volume size..."
#####################################################
#Check DB storage volume size has not been increased in settings.env
DBSIZE=$(openstack volume show db-storage --format value --column size)
if ((DB_VOLUME_SIZE > DBSIZE)); then 
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
fi

#Apply changes
if [ "$1" != "noflux" ]; then
  flux reconcile kustomization apps --with-source
fi

