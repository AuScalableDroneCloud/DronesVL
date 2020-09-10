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
# It is intended to add further options for other components
####################################################################################################

#Load the settings, setup openstack and kubectl
source settings.env

if [ -z ${KUBECONFIG+x} ];
then
  echo "KUBECONFIG is unset, run : source asdc_run.sh to init cluster";
  exit
fi

if [ $1 = "webapp" ];
then
  #Delete the worker pod to force rebuild
  kubectl delete pod webapp-worker

  #Apply variables (hostname) to webapp-worker
  cat templates/webapp-worker-pod.yaml | envsubst > webapp-worker-pod.yaml

  #Re-deploy the WebODM instance
  kubectl create -f webapp-worker-pod.yaml

else if [ $1 = "ip" ];
then
  #Need to clear port on our floating ip or it will be deleted with the cluster
  FLOATING_IP=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'Floating IP Address' -f value)
  FIP_ID=$(openstack floating ip list --floating-ip-address $FLOATING_IP -c ID -f value)
  openstack floating ip unset --port $FIP_ID

  openstack floating ip list

  #WARNING: if above fails, and this runs, ip will be destroyed, so check, or do this manually...
  EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [ ${EXTERNAL_IP} = ${FLOATING_IP}];
  then
    echo "WARNING: service still appears to be using floating ip, DO NOT DELETE"
  else
    #kubectl delete service webapp-service
  fi

fi

