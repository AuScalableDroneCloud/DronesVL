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

#Use our config file from openstack magnum for kubectl
export KUBECONFIG=$(pwd)/secrets/kubeconfig

#If secrets/kubeconfig exists, then skip cluster build, remove it to re-create
if [ ! -s "${KUBECONFIG}" ] || ! grep "${CLUSTER}" ${KUBECONFIG};
then
  echo "Kubernetes config for $CLUSTER not found, preparing to create cluster"
  #DEBUG - delete the existing template to apply changes / edits
  #NOTE: This just fails when the cluster is running, so it's ok to run without checking here
  openstack coe cluster template delete $TEMPLATE;

  #Working labels for k8s 1.21.1 on fedora-coreos-32
  LABELS=container_infra_prefix=registry.rc.nectar.org.au/nectarmagnum/,kube_tag=$KUBE_TAG,flannel_tag=$FLANNEL_TAG,master_lb_floating_ip_enabled=true,docker_volume_type=standard,availability_zone=$ZONE,cinder_csi_enabled=true,ingress_controller=octavia

  #Current default labels from kubernetes-monash-02-v1.21.1
  #container_infra_prefix=registry.rc.nectar.org.au/nectarmagnum/,kube_tag=v1.21.1,flannel_tag=v0.14.0-amd64,master_lb_floating_ip_enabled=true,cinder_csi_enabled=true,docker_volume_type=standard,availability_zone=monash-02,ingress_controller=octavia

  #Creating the template
  echo "Using labels: $LABELS"
  if ! openstack coe cluster template show $TEMPLATE;
  then
    #See: https://docs.openstack.org/magnum/latest/user/
    echo "Creating cluster template: $TEMPLATE"

    #Tried calico for dns issues and slow image pulls, didn't resolve
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
    openstack coe cluster create --cluster-template $TEMPLATE --keypair $KEYPAIR --master-count 1 --node-count $APP_NODES $CLUSTER
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
  : '
  STACK_ID=$(openstack coe cluster show $CLUSTER -f value -c stack_id)
  K_FLOATING_IP=$(openstack stack output show $STACK_ID api_address -c output_value -f value)
  PORT_ID=$(openstack floating ip show $K_FLOATING_IP -c port_id -f value)

  #Open the port if not already done
  SG_ID=$(openstack security group show kubernetes-api -c id -f value)
  if ! openstack port show $PORT_ID -c security_group_ids -f value | grep $SG_ID
  then
    echo "SETTING PORT"
    #THIS STILL FAILS... DOESNT SEEM TO MATTER ANYWAY AS CAN ACCESS WITH IP???
    #ResourceNotFound: 404: Client Error for url: https://neutron.rc.nectar.org.au:9696/v2.0/ports/1cfcf6b5-cf52-476b-9598-01e49ffffce6, Security group bde2e01a-9c02-4e90-b9af-dcba62f47660 does not exist
    openstack port set --security-group kubernetes-api $PORT_ID
  else
    echo "PORT SET ALREADY"
  fi
  '

  #Create the config
  openstack coe cluster config $CLUSTER
  mv config ${KUBECONFIG}
  chmod 600 ${KUBECONFIG}

  # DNS fails on newer kubernetes with fedora-coreos-32 image, need to restart flannel pods...
  # See: https://tutorials.rc.nectar.org.au/kubernetes/09-troubleshooting
  #Flannel
  kubectl -n kube-system delete pod -l app=flannel

  #Calico - reset pods to try and fix network issues?
  #kubectl get pods --all-namespaces -owide --show-labels
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

#Create volume for server/webapp
get_volume $WEBAPP_VOLUME_SIZE web-storage
export WEB_VOLUME_ID=$VOL_ID

#Create volume for db
get_volume $DB_VOLUME_SIZE db-storage
export DB_VOLUME_ID=$VOL_ID

# ####################################################################################################
echo --- Phase 3 : Deployment: Flux apps - Prepare configmaps and secrets for flux
# ####################################################################################################

#NOTE!!! cluster_deploy taints need to be applied before starting flux apps
# or they will run on the GPU nodes!!! (Alternatively, wait until after this before starting with cluster_create)

#Update ConfigMap/Secret data
./asdc_update.sh

# Bootstrap flux.
#(Requires github personal access token with repo rights in GITHUB_TOKEN)

# Installs flux if it's not already present, using the configured live repo. This is idempotent.
#(OK: Adding image automation features: https://fluxcd.io/docs/guides/image-update/#configure-image-scanning)
flux bootstrap ${FLUX_LIVE_REPO_TYPE} --owner=${FLUX_LIVE_REPO_OWNER} --repository=${FLUX_LIVE_REPO} --team=${FLUX_LIVE_REPO_TEAM} --path=${FLUX_LIVE_REPO_PATH} --read-write-key --components-extra=image-reflector-controller,image-automation-controller

#Info...
#flux get all

#See/Suspend/resume
#flux get helmreleases -n jupyterhub
#flux suspend/resume helmrelease jupyterhub -n jupyterhub
#flux suspend/resume kustomization apps

#Update immediately
#flux reconcile kustomization cesium-asdc --with-source
#flux reconcile kustomization apps --with-source
#flux reconcile helmrelease jupyterhub -n jupyterhub

#BUG: autohttps seems to fail to get letsencrypt cert on first boot, need to delete and let them run again
#kubectl delete pod autohttps-##### -n jupyterhub

####################################################################################################
echo --- Phase 4 : Start the cluster nodes
####################################################################################################

#Create the compute cluster
source cluster_create.sh

####################################################################################################
echo --- Phase 5 : Cluster config and GPU setup, deploy nodes etc
####################################################################################################

source cluster_deploy.sh

#SMTP
#https://artifacthub.io/packages/helm/docker-postfix/mail
#helm repo add bokysan https://bokysan.github.io/docker-postfix/
#helm upgrade --install --set persistence.enabled=false --set config.general.ALLOW_EMPTY_SENDER_DOMAINS=1 mail bokysan/mail

