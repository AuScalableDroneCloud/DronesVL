#!/bin/bash
#Run on a node to do setup tasks
# - fix ./tmp
# - wait for ClusterODM
# - register self with ClusterODM
#
#Designed to use builtin shell features so
#no packages required (telnet/netcat/nslookup etc)

#Now also used to launch ClusterODM, check the NODETYPE var
NODETYPE="${NODETYPE:-nodeodm}"
#Fix the tmp path storage issue
#(writes to ./tmp in /var/www by default, which fills ethemeral storage of docker image and node)
#(replace this with symlink to the scratch volume)
if ! [ -L /var/www/tmp ] ; then
  rm -rf /var/www/tmp;
  mkdir -p /var/www/scratch/${NODETYPE}/${HOSTNAME}/tmp;
  ln -s /var/www/scratch/${NODETYPE}/${HOSTNAME}/tmp /var/www/tmp;
fi

if [ "$NODETYPE" != "clusterodm" ]; then
  #-- Setup NodeODM,
  #Link /var/www/data to scratch/nodetype/hostname
  if ! [ -L /var/www/data ] ; then
    rm -rf /var/www/data;
    mkdir -p /var/www/scratch/${NODETYPE}/${HOSTNAME};
    ln -s /var/www/scratch/${NODETYPE}/${HOSTNAME} /var/www/data;
  fi
  #   register with ClusterODM instance on first node of this type
  NODEPORT="${NODEPORT:-3000}"
  NODEHOST=${HOSTNAME}.nodeodm-svc
  CLUSTERODM_ID="${CLUSTERODM_ID:-0}" #Default to first node clusterodm
  CLUSTERODM=${NODETYPE}-${CLUSTERODM_ID}.nodeodm-svc
  CLUSTERODM_PORT=8080
  #Loop until clusterodm is running
  until getent hosts ${CLUSTERODM}
  do
    echo "Waiting for ${CLUSTERODM} to start"
    sleep 2
  done
  echo "${CLUSTERODM} is running : $1"

  #Check if added already
  exec {fd}<>/dev/tcp/${CLUSTERODM}/${CLUSTERODM_PORT}
  sleep 0.1
  echo -e "NODE LIST" >&${fd}
  sleep 0.1
  echo -e "QUIT" >&${fd}
  if cat <&${fd} | grep ${HOSTNAME}; then
    echo "Node already added..."
  else
    echo "Adding node to cluster..."
    exec {fd}<>/dev/tcp/${CLUSTERODM}/${CLUSTERODM_PORT}
    sleep 0.1
    echo -e "NODE ADD ${NODEHOST} ${NODEPORT}" >&${fd}
    sleep 0.1
    echo -e "QUIT" >&${fd}
  fi

  #Launch node with provided args
  node /var/www/index.js $@;

  #Possible args (NodeODM):
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

else
  #Launch clusterodm node
  node /var/www/index.js -p 3001 --public-address http://${HOSTNAME}.nodeodm-svc:3001 $@;

  #Possible args (ClusterODM):
  #Usage: node index.js [options]
  #Options:
  #    --config <path>	Path to JSON configuration file. You can use a configuration file instead of passing command line parameters. (default: config-default.json)
  #    -p, --port <number>	Port to bind the server to (default: 3000)
  #    --secure-port <number>	If SSL is enabled and you want to expose both a secure and non-secure service, set this value to the secure port. Otherwise only SSL will be enabled using the --port value. (default: none)
  #    --admin-cli-port <number> 	Port to bind the admin CLI to. Set to zero to disable. (default: 8080)
  #    --admin-web-port <number> 	Port to bind the admin web interface to. Set to zero to disable. (default: 10000)
  #    --admin-pass <string> 	Password to log-in to the admin functions (default: none)
  #    --log-level <logLevel>	Set log level verbosity (default: info)
  #    -c, --cloud-provider	Cloud provider to use (default: local)
  #    --upload-max-speed <number>	Upload to processing nodes speed limit in bytes / second (default: no limit)
  #    --downloads-from-s3 <URL>	Manually set the S3 URL prefix where to redirect /task/<uuid>/download requests. (default: do not use S3, forward download requests to nodes, unless the autoscaler is setup, in which case the autoscaler's S3 configuration is used) 
  #    --no-splitmerge	By default the program will set itself as being a cluster node for all split/merge tasks. Setting this option disables it. (default: false)
  #    --public-address <http(s)://host:port>	Should be set to a public URL that nodes can use to reach ClusterODM. (default: match the "host" header from client's HTTP request)
  #    --flood-limit <number>	Limit the number of simultaneous task uploads that a user can initiate concurrently (default: no limit)
  #    --stale-uploads-timeout <number>	Delete temporary uploads if no activity is recorded for these many hours. After 48 hours stale uploads are always removed regardless of this option. (default: do not remove stale uploads)
  #    --token <token> Sets a token that needs to be passed for every request. This can be used to limit access to the node only to token holders. (default: none)
  #    --debug 	Disable caches and other settings to facilitate debug (default: false)
  #    --ssl-key <file>	Path to .pem SSL key file
  #    --ssl-cert <file>	Path to SSL .pem certificate
  #    --asr <file>	Path to configuration for enabling the autoscaler. This is combined with the provider's default configuration (default: none)
  #Log Levels: 
  #error | debug | info | verbose | debug | silly

fi
