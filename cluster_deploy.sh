####################################################################################################
# OpenDroneMap on k8s for ASDC DronesVL
# Owen Kaluza, Monash University, February 2022
#
# - Deploy kubernetes cluster nodegroup on openstack
# - This is a the compute cluster used to run ODM jobs and Jupyterhub pods
# - This script configures the cluster ready for use
####################################################################################################

#Load the settings, setup openstack and kubectl
source settings.env

if [ -z ${KUBECONFIG+x} ];
then
  echo "KUBECONFIG is unset, run : source asdc_run.sh to init cluster";
  exit
fi

function nodegroup_check()
{
  #$1 nodegroup name
  NSTATUS=$(openstack coe nodegroup show $CLUSTER $1 -f value -c status)
  if [[ "$NSTATUS" == *"$2"* ]]; then
    return 0
  fi
  return 1
}

function nodegroup_wait()
{
  #Wait until nodegroup complete
  #$1 nodegroup name
  until nodegroup_check $1 "COMPLETE"
  do
    printf "Nodegroup $NSTATUS "
    sleep 2
  done
}

####################################################################################################
echo --- Phase 4a : Cluster node taints
####################################################################################################

#Until bug with nodegroup creation fixed, may have to skip this
#nodegroup_wait $CLUSTER_BASE-P4
nodegroup_wait $CLUSTER_BASE-A40
nodegroup_wait $CLUSTER_BASE-A100

#Need to re-create flannel pods after nodegroup created
if [ $NODEGROUP_CREATED == 1 ];
then
  kubectl -n kube-system delete pod -l app=flannel

  # All gpu cluster nodes need to be tainted to prevent other pods running on them!
  #kubectl taint nodes $NODE key1=value1:NoSchedule
  #kubectl taint nodes $NODE compute=compute-jobs-only:NoSchedule
  for node in $(kubectl get nodes -l magnum.openstack.org/role=cluster -ojsonpath='{.items[*].metadata.name}'); 
  do 
    #kubectl get pods -A -owide --field-selector spec.nodeName=$node;
    kubectl taint nodes $node compute=true:NoSchedule
  done

  #Only use the new hardware for jupyterhub

  for node in $(kubectl get nodes -l "nvidia.com/gpu.product in (A40,A100-PCIE-40GB)" -ojsonpath='{.items[*].metadata.name}'); 
  do 
    #Use the compute nodes for jupyterhub pods
    #https://zero-to-jupyterhub.readthedocs.io/en/latest/administrator/optimization.html
    kubectl label nodes $node hub.jupyter.org/node-purpose=user
    #Use PreferNoSchedule so pods other than jupyterhub will still run on these nodes if they tolerate compute=true
    kubectl taint nodes $node hub.jupyter.org/dedicated=user:PreferNoSchedule
  done
  export NODEGROUP_CREATED=0
fi

####################################################################################################
echo --- Phase 4c : Additional storage
####################################################################################################

#The new nodes include a 3T volume, mount it so we can use it for scratch space
#(Mounts on /var/mnt/scratch)
#TODO: MOVE THIS TO FLUX
kubectl apply -f templates/scratch-volume-mounter.yaml

####################################################################################################
echo --- Phase 4d : Deployment: NodeODM, ClusterODM
####################################################################################################
#Deploy processing nodes

#Get content of the setup script
export NODE_SETUP_SCRIPT_CONTENT=$(cat node_setup.sh | sed 's/\(.*\)/    \1/')
apply_template nodeodm-script-configmap.yaml

#Deploy NodeODM nodes (all GPU now, if we need CPU only can be configured per-cluster)
#TODO: HOW TO MOVE THIS TO FLUX?
function deploy_cluster()
{
  #Create a cluster nodegroup
  #$1 : cluster name
  #$2 : number of nodes
  #$3 : label/gpu selector
  #$4 : additional args, eg: --maxImages 5000
  #$5 : volume size
  #$6 : volume storage class

  #Deploy clusterODM
  export CLUSTER_NAME=clusterodm-$1

  export NODE_COUNT=$2
  export NODE_SELECTOR=$3
  export NODE_TYPE=nodeodm-$1
  export NODE_IMAGE=opendronemap/nodeodm:gpu
  #export NODE_IMAGE=opendronemap/nodeodm
  export NODE_GPUS=1
  export NODE_ARGS="${ODM_FLAGS_GPU} ${4}"
  #export NODE_ARGS=${ODM_FLAGS}
  export NODE_VOLUME_SIZE=$NODE_VOLSIZE

  export NODE_VOLUME_SIZE=$5
  export NODE_STORAGE_CLASS=$6

  #Deploy nodeODM
  apply_template nodeodm.yaml
}

#Possible args:
#Usage: node index.js [options]
#
#Options:
#        --config <path> Path to the configuration file (default: config-default.json)
#        -p, --port <number>     Port to bind the server to, or "auto" to automatically find an available port (default: 3000)
#        --odm_path <path>       Path to OpenDroneMap's code     (default: /code)
#        --log_level <logLevel>  Set log level verbosity (default: info)
#        -d, --daemon    Set process to run as a deamon
#        -q, --parallel_queue_processing <number> Number of simultaneous processing tasks (default: 2)
#        --cleanup_tasks_after <number> Number of minutes that elapse before deleting finished and canceled tasks (default: 2880) 
#        --cleanup_uploads_after <number> Number of minutes that elapse before deleting unfinished uploads. Set this value to the maximum time you expect a dataset to be uploaded. (default: 2880) 
#        --test Enable test mode. In test mode, no commands are sent to OpenDroneMap. This can be useful during development or testing (default: false)
#        --test_skip_orthophotos If test mode is enabled, skip orthophoto results when generating assets. (default: false) 
#        --test_skip_dems        If test mode is enabled, skip dems results when generating assets. (default: false) 
#        --test_drop_uploads     If test mode is enabled, drop /task/new/upload requests with 50% probability. (default: false)
#        --test_fail_tasks       If test mode is enabled, mark tasks as failed. (default: false)
#        --test_seconds  If test mode is enabled, sleep these many seconds before finishing processing a test task. (default: 0)
#        --powercycle    When set, the application exits immediately after powering up. Useful for testing launch and compilation issues.
#        --token <token> Sets a token that needs to be passed for every request. This can be used to limit access to the node only to token holders. (default: none)
#        --max_images <number>   Specify the maximum number of images that this processing node supports. (default: unlimited)
#        --webhook <url> Specify a POST URL endpoint to be invoked when a task completes processing (default: none)
#        --s3_endpoint <url>     Specify a S3 endpoint (for example, nyc3.digitaloceanspaces.com) to upload completed task results to. (default: do not upload to S3)
#        --s3_bucket <bucket>    Specify a S3 bucket name where to upload completed task results to. (default: none)
#        --s3_access_key <key>   S3 access key, required if --s3_endpoint is set. (default: none)
#        --s3_force_path_style  Whether to force path style URLs for S3 objects. (default: false)
#        --s3_secret_key <secret>        S3 secret key, required if --s3_endpoint is set. (default: none) 
#        --s3_signature_version <version>        S3 signature version. (default: 4)
#        --s3_acl <canned-acl> S3 object acl. (default: public-read)
#        --s3_upload_everything  Upload all task results to S3. (default: upload only all.zip archive)
#        --max_concurrency   <number>    Place a cap on the max-concurrency option to use for each task. (default: no limit)
#        --max_runtime   <number> Number of minutes (approximate) that a task is allowed to run before being forcibly canceled (timeout). (default: no limit)

#deploy_cluster p4 $NODES_P4 Tesla-P4 "--max_images 1000" ${NODE_VOLSIZE}Gi csi-sc-cinderplugin
deploy_cluster a40 $NODES_A40 A40 "--max_images 10000" ${NODE_VOLSIZE}Gi csi-sc-cinderplugin
deploy_cluster a100 $NODES_A100 A100-PCIE-40GB "--max_images 10000" ${NODE_VOLSIZE}Gi csi-sc-cinderplugin
#When local-path provisioner enabled:..
#deploy_cluster a40 $NODES_A40 A40 "--max_images 10000" 2000Gi local-path
#deploy_cluster a100 $NODES_A100 A100-PCIE-40GB "--max_images 10000" 2000Gi local-path

#Deploy any additional nodes (MicMac)
#export NODE_COUNT=2
#export NODE_TYPE=nodemicmac
#export NODE_IMAGE=dronemapper/node-micmac
#export NODE_PORT=3000
#export NODE_GPUS=0
#export NODE_ARGS=""
#export NODE_VOLUME_SIZE=$NODE_VOLSIZE
#apply_template nodeodm.yaml

####################################################################################################
echo --- Phase 4e : Deployment: Metashape
####################################################################################################

#Apply the secrets
#TODO: move secrets to secrets/secret.env and these to ./templates
kubectl apply -f metashape/dronedrive_secret.yaml

if [ "$NODE_METASHAPE" -gt "0" ]; then
  #Setup the cifs/smb volume mount - this has problems, keeps restarting
  # - Install csi plugin
  curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/deploy/install-driver.sh | bash -s master --
  # - Create persistent volume and claim
  kubectl apply -f metashape/csi-pv.yaml -f metashape/csi-pvc.yaml

  #Launch metashape server and load balancer service
  #(NOTE: we had to launch these in a separate VM on monash-02 instead
  # as monash-01 to monash-02 network is really broken right now
  # also - license server does not handle being run in a different container each time)
  #apply_template metashape-server.yaml
  #apply_template metashape-service.yaml
  #wait_for_pod metashape-server
fi

#Launch metashape processing nodes - require nvidia gpu resource
function deploy_metashape()
{
  #Deploy Metashape pod with unique name
  #$1 = id#
  export NODE_NAME=metashape-k8s$1
  if ! kubectl get pods | grep $NODE_NAME
  then
    echo ">>> METASHAPE NODE LAUNCH... " $NODE_NAME

    echo "Deploying $2 : $3 as $NODE_NAME"
    export NODE_TYPE="metashape"
    apply_template metashape.yaml
  fi
}

#Deploy Metashape nodes
for (( n=1; n<=$NODE_METASHAPE; n++ ))
do
  deploy_metashape $n
done


