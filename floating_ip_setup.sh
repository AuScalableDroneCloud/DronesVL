#DEPRECATED: MOVED FROM asdc_run.sh

#Not needed in regular operation as we use a predefined IP now
#If we use this at all it needs cleanup, but really should just document requirements, such as:

#1) Need to create a floating ip manually, create the domain and DNS entries to point to the FIP

####################################################################################################
echo --- Phase 4a : Configuration: Floating IP
####################################################################################################

#Wait for the load balancer to be provisioned, necessary?
#echo "Waiting for load balancer IP"
EXTERNAL_IP=
while [ -z $EXTERNAL_IP ];
do
  printf '.';
  #EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.spec.loadBalancerIP}')
  EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  sleep 1
done
echo ""

#Used to open port if necessary... already open now but may be from previous test attempts
#PORT_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c Port -f value)
#openstack port show $PORT_ID -c security_group_ids -f value
#openstack port set --security-group http $PORT_ID #This was failing
echo "Ready at http://$EXTERNAL_IP"

#Check if the hostname resolves to an already defined floating-ip
WEBAPP_IP=$(getent hosts ${WEBAPP_HOST} | awk '{ print $1 }')
echo $WEBAPP_HOST resolves to $WEBAPP_IP

#Do we already have a floating-ip ready to use that our hostname points to?
#(should always be the case except on first spin-up as we want to keep this)
#FIP_ID=$(openstack floating ip list --floating-ip-address $WEBAPP_IP -c ID -f value)
FIP_ID=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'ID' -f value)
if [ -z ${FIP_ID} ];
then
  #Tag floating ips with their description, as we can't filter by description only tag
  FIPS=$(openstack floating ip list -c 'ID' -f value)
  for FIP_ID in ${FIPS}
  do
    DESC=$(openstack floating ip show $FIP_ID -c 'description' -f value)
    if [ ${DESC} ];
    then
      echo Tagging $FIP_ID with $DESC
      openstack floating ip set --tag='$DESC' $FIP_ID
    fi
  done

  #Check if floating ip already created and tagged for this hostname
  FP_ID=$(openstack floating ip list --tags ${WEBAPP_HOST} -c ID -f value)
  if [ -z ${FIP_ID} ];
  then
    #Create the floating ip that will be used from now on
    echo "Creating floating IP for $WEBAPP_HOST"
    #Getting network ID
    NET_ID=$(openstack network list --name=$NETWORK -c ID -f value)
    #Tag with the domain name to help with lookup
    openstack floating ip create $NET_ID --tag $WEBAPP_HOST --description $WEBAPP_HOST

    #Can set tag after if needed with
    #openstack floating ip set --tag='${WEBAPP_HOST}' $FP_ID
    #openstack floating ip set --description '${WEBAPP_HOST}' $FP_ID
    FP_ID=$(openstack floating ip list --tags ${WEBAPP_HOST} -c ID -f value)
    FLOATING_IP=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'Floating IP Address' -f value)
    echo "Please set your DNS for $WEBAPP_HOST to point to $FLOATING_IP"
    echo "...will loop until resolves: ctrl+c to abort"
    until [ ${WEBAPP_IP} = ${FLOATING_IP} ];
    do
      WEBAPP_IP=$(getent hosts ${WEBAPP_HOST} | awk '{ print $1 }');
      echo $WEBAPP_HOST resolves to $WEBAPP_IP
      sleep 5.0
    done

    #return 0
  else
    echo "Floating IP exists for $WEBAPP_HOST, but it resolves to $WEBAPP_IP, please check DNS entries"
    openstack floating ip show $FP_ID
    return 1
  fi
fi

#If we get to this point, we have
#1) Our own managed Floating IP (not created by k8s)
#2) DNS for our hostname correctly resolving to above floating ip
#3) webapp-service up and running ? - or use this ip to start it from template

#Get assigned IP details
EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
#EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.spec.loadBalancerIP}')
echo "Service ingress IP is : $EXTERNAL_IP"
FIXED_IP=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c 'Fixed IP Address' -f value)
echo "Associated internal Fixed IP is: $FIXED_IP"

#If webapp host resolves to this service load balancer IP, everything is good
if [ ${WEBAPP_IP} = ${EXTERNAL_IP} ] && [ ${FIXED_IP} != "None" ];
then
  echo "$WEBAPP_HOST ip matches service ip already, looks good to go"
else
  FLOATING_IP=$(openstack floating ip list --tags ${WEBAPP_HOST} -c 'Floating IP Address' -f value)
  echo "Floating IP found with tag $WEBAPP_HOST : $FLOATING_IP"
  #FIP_PORT=$(openstack floating ip list --tags ${WEBAPP_HOST} -c Port -f value)
  #FIP_PORT=$(openstack floating ip list --floating-ip-address $WEBAPP_IP -c Port -f value)

  echo Using this IP: $FLOATING_IP
  echo ID $FIP_ID
  #echo Port $FIP_PORT

  if [ ! $? ];
  then
    echo "No external IP available yet for load balancer, aborting"
    return 0
  fi
  PORT_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c Port -f value)
  echo Port $PORT_ID
  OLD_ID=$(openstack floating ip list --floating-ip-address $EXTERNAL_IP -c ID -f value)
  echo ID $OLD_ID

  #NOTE: there is an issue here if the FIP has been manually disassociated
  #need to detect and re-assign the port
  if [ ! -z ${OLD_ID} ];
  then
    if [ ${EXTERNAL_IP} != ${FLOATING_IP} ];
    then
      #Can only assign one external IP so must delete the generated one
      echo "Deleting assigned floating ip"
      openstack floating ip delete $OLD_ID
    else
      echo "WARNING: Designated floating IP already assigned to this service!"
      unset FIXED_IP #Skip re-assign
    fi
  else
    echo "WARNING: No existing floating IP assigned"
  fi

  if [ ! -z ${FIXED_IP} ];
  then
    echo "*** DEPRECATED - THIS SHOULD NOT BE REACHED!"
    return 1; 
    echo "Applying reserved floating ip"
    #Setup our reserved IP to point to the load-balancer service
    openstack floating ip set --port $PORT_ID --fixed-ip-address=$FIXED_IP $FIP_ID

    openstack floating ip list

    ping $WEBAPP_HOST -c 1

    echo "NOTE: must clear port of this floating ip before deleting services - or will be destroyed... use: ./asdc_update.sh ip"
    # ^^ Above is not true if service uses specific floating ip when created rather than replacing

    #Seems to work without writing this, but allows us to check the value on the service matches our floating IP
    kubectl patch svc webapp-service -p "{\"spec\": {\"loadBalancerIP\": \"${FLOATING_IP}\"}}"

  else
    echo "WARNING: No fixed IP found"
  fi
fi

#Final URL
echo "Done. Access on https://$WEBAPP_HOST"


