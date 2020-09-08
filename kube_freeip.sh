#Get settings
source settings.env

#Need to clear port on our floating ip or it will be deleted with the cluster
FLOATING_IP=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'Floating IP Address' -f value)
FIP_ID=$(openstack floating ip list --floating-ip-address $FLOATING_IP -c ID -f value)
openstack floating ip unset --port $FIP_ID

openstack floating ip list

#WARNING: if above fails, and this runs, ip will be destroyed, so check, or do this manually...
#kubectl delete service webapp-service

