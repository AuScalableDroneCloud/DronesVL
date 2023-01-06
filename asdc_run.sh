####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, August 2020
#
# - Provision a kubernetes cluster using OpenStack cluster orchestration engine
# - Create volumes for persistent storage
# - Launch a WebODM instance, a NodeODM instance per cluster node and other required services
# - Configure external load balancer with reserved floating ip and setup SSL
####################################################################################################


#TODO:
# - Better shared storage pool between nodes, nfs or similar

if [[ "$0" = "$BASH_SOURCE" ]]; then
    echo "Please source this script. Do not execute."
    exit 1
fi

#Load the settings, setup openstack and kubectl
source settings.env

####################################################################################################
echo --- Phase 1 : Cluster Launch
####################################################################################################

#If secrets/kubeconfig exists, then skip cluster build, remove it to re-create
if [ ! -s "${KUBECONFIG}" ] || ! grep "${CLUSTER}" ${KUBECONFIG};
then
  echo "Kubernetes config for $CLUSTER not found, preparing to create cluster"
  #DEBUG - delete the existing template to apply changes / edits
  #NOTE: This just fails when the cluster is running, so it's ok to run without checking here
  openstack coe cluster template delete $TEMPLATE;

  #Creating the template
  echo "Using labels: $LABELS"
  if ! openstack coe cluster template show $TEMPLATE;
  then
    #See: https://docs.openstack.org/magnum/latest/user/
    echo "Creating cluster template: $TEMPLATE"

    #Use calico to enable NetworkPolicy
    #NWDRIVER="calico"
    NWDRIVER="flannel"

    #Floating ip disabled, master-lb-enabled, master-lb-floating-ip enabled
    openstack coe cluster template create $TEMPLATE --image $IMAGE --keypair $KEYPAIR --external-network $NETWORK --floating-ip-disabled --master-lb-enabled --flavor $APP_FLAVOUR --master-flavor $MASTER_FLAVOUR --docker-volume-size $DOCKER_VOL_SIZE --docker-storage-driver overlay2 --network-driver $NWDRIVER --coe kubernetes --volume-driver cinder --coe kubernetes --labels $LABELS

    #Floating ip enabled (allows ssh into nodes but requires extra FIPs)
    #openstack coe cluster template create $TEMPLATE --image $IMAGE --keypair $KEYPAIR --external-network $NETWORK --dns-nameserver 8.8.8.8 --flavor $FLAVOUR --master-flavor $MASTER_FLAVOUR --docker-volume-size 25 --docker-storage-driver overlay2 --network-driver flannel --coe kubernetes --volume-driver cinder --coe kubernetes --labels $LABELS
  fi

  #List running stacks
  openstack stack list

  #Create the cluster, wait until complete
  get_status
  if ! cluster_check "CREATE_FAILED" && ! cluster_launched; then
    #Create the cluster from default template
    openstack coe cluster create --cluster-template $TEMPLATE --keypair $KEYPAIR --master-count $MASTER_NODES --node-count $APP_NODES $CLUSTER
    echo "Cluster create initiated..."
  fi

  #Wait until cluster complete
  until cluster_check "COMPLETE"
  do
    get_status
    printf "$STATUS "
    if cluster_check "CREATE_FAILED"; then
      echo "Cluster create failed!"
      heat stack-list -n
      echo "Use 'heat resource-list failedstackid'"
      echo "Then 'heat resource-show failedstackid resid' for more info"
      return 1
    fi
    sleep 2
  done
  echo ""

  #Wait for the load balancer to be provisioned
  #(if we set MASTER_NODES > 1, stays in UNHEALTHY and gets stuck here...)
  STACK_ID=$(openstack coe cluster show $CLUSTER -f value -c stack_id)
  K_FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
  #Ping no longer responding
  #while ! timeout 0.2 ping -c 1 -n ${K_FLOATING_IP} &> /dev/null;
  while ! timeout 0.2 nc -zv ${K_FLOATING_IP} 6443 &> /dev/null;
  do
    echo "Waiting for master-lb to be assigned floating IP, current api_address = $K_FLOATING_IP"
    K_FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
    sleep 1
  done

  #Once the cluster is running, get params and the config for kubectl
  echo "Attempting to configure cluster";
  #Finally setup the environment and export kubernetes config
  openstack coe cluster config $CLUSTER
  mv config $KUBECONFIG
  #Update secrets repo...
  ./crypt.sh push
  #Also copy to keybase
  if command -v keybase &> /dev/null; then
    BASE_KC="$(basename -- $KUBECONFIG)"
    echo $BASE_KC
    echo "keybase fs cp $KUBECONFIG /keybase/team/asdc.admin/${BASE_KC}"
    keybase fs rm /keybase/team/asdc.admin/${BASE_KC}
    keybase fs cp $KUBECONFIG /keybase/team/asdc.admin/${BASE_KC} -f
  fi

  #Calico - reset pods to try and fix network issues?
  kubectl get pods --all-namespaces -owide --show-labels
  #kubectl -n kube-system delete pod -l k8s-app=calico-node

else
  echo "${KUBECONFIG} exists for $CLUSTER, to force re-creation : rm ${KUBECONFIG}"
  #If config exists but cluster doesn't, remove config and exit here...
  if ! openstack coe cluster show $CLUSTER -f value -c status;
  then
    echo "Cluster doesn't exist, removing config, re-run to create"
    return 1;
  fi
fi;

####################################################################################################
echo --- Phase 2 : Deployment: Volumes and storage
####################################################################################################

### Create persistent cinder volumes

#Volume creation function
function get_volume()
{
  VOL_ID=$(openstack volume show $2 -f value -c id)
  if [ $? -eq 1 ]
  then
    #Create volume, args size in gb, label
    echo "Creating Volume '$2' of size $1 gb"
    openstack volume create --availability-zone $ZONE --size $1 $2
    VOL_ID=$(openstack volume show $2 -f value -c id)
  fi
}

#Create volume for db
get_volume $DB_VOLUME_SIZE db-storage
export DB_VOLUME_ID=$VOL_ID

# ####################################################################################################
echo --- Phase 3 : Deployment: Flux apps - Prepare configmaps and secrets for flux
# ####################################################################################################

#Update ConfigMap/Secret data
./asdc_update.sh noflux

# Bootstrap flux.
#(Requires github personal access token with repo rights in GITHUB_TOKEN)

#See re: multiple environments
#https://github.com/fluxcd/flux2-kustomize-helm-example#identical-environments

# Installs flux if it's not already present, using the configured live repo. This is idempotent.
#(OK: Adding image automation features: https://fluxcd.io/docs/guides/image-update/#configure-image-scanning)
if ! flux bootstrap ${FLUX_LIVE_REPO_TYPE} \
  --owner=${FLUX_LIVE_REPO_OWNER} \
  --repository=${FLUX_LIVE_REPO} \
  --branch=${FLUX_LIVE_REPO_BRANCH} \
  --team=${FLUX_LIVE_REPO_TEAM} \
  --path=${FLUX_LIVE_REPO_PATH} \
  --read-write-key \
  --components-extra=image-reflector-controller,image-automation-controller;
then
  echo "ERROR IN FLUX BOOTSTRAP, HALTING"
  return
fi

#SMTP
#https://artifacthub.io/packages/helm/docker-postfix/mail
#helm repo add bokysan https://bokysan.github.io/docker-postfix/
#helm upgrade --install --set persistence.enabled=false --set config.general.ALLOW_EMPTY_SENDER_DOMAINS=1 mail bokysan/mail

####################################################################################################
echo --- Phase 4 : Start the cluster nodes
####################################################################################################

#Create the compute cluster
source cluster_create.sh


