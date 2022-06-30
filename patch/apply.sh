#!/bin/bash
# This applies patches to WebODM based on a
# list of files in FILELIST and a reference WebODM 
# copy with the modified files
# - Files are copied to a persistent volume on the running app
# - App server processes are stopped, loop in pod runs the patch on startup
# - Files are copied into pod live version before restarting services
echo Running patch on $HOSTNAME

#Files to copy from local WebODM
FILELIST="
nginx/nginx-ssl.conf.template
package.json
requirements.txt
app/models/task.py
app/static/app/js/components/TaskListItem.jsx
"

#Run from the DronesVL repo base
#Default is to assume reference WebODM install and DronesVL dir both in parent dir
cd ..
BASEPATH=$(pwd)/DronesVL
WEBODMPATH=$(pwd)/WebODM
cd -

function exec_k8s()
{
  #Runs kubectl exec in a loop until it succeeds or 10 attempts
  #ARGS: pod container command
  for i in {1..10}
  do
    if kubectl exec --stdin --tty webapp-worker-0 -c webapp -- bash -c "$1"
    then
      echo "OK"
      break
    fi
    echo "Failed: Attempting again ($i)"
  done
}

function cp_k8s()
{
  #Runs kubectl cp ARGS in a loop until it succeeds or 10 attempts
  #ARGS: pod container command
  echo "COPYING"
  for i in {1..10}
  do
    if kubectl cp --no-preserve=true "$1" "webapp-worker-0:$2" -c webapp
    then
      echo "OK"
      break
    fi
    echo "Failed: Attempting again ($i)"
  done
  echo "COPY DONE"
}

#exec_k8s webapp-worker-0 webapp "ls | wc"
#exit()

if [ $HOSTNAME != 'webapp-worker-0' ]; then

  exec_k8s "mkdir -p /webodm/app/media/patch/"
  exec_k8s "mkdir -p /webodm/app/media/plugins/"
  #COPY PATCHED FILES TO POD VOLUME
  echo "ON DEV PC"
  source $BASEPATH/settings.env
  cd $BASEPATH/patch/
  cp_k8s "apply.sh" "/webodm/app/media/patch/"
  for f in $FILELIST
  do
    DIR="$(dirname "${f}")"
    echo "Creating dir $DIR..."
    exec_k8s "mkdir -p /webodm/app/media/patch/$DIR"
    echo "Copying file $f..."
    cp_k8s "$WEBODMPATH/$f" "/webodm/app/media/patch/$f"
  done
  
  #Update plugin (clone / pull if exists)
  echo "Updating plugin"
  exec_k8s "cd /webodm/app/media/plugins/; git -C asdc pull || git clone https://github.com/auscalabledronecloud/asdc_plugin.git asdc"

  #To install patch, kill and restart main processes in pod...
  #echo "Kill celery"
  #kubectl exec --stdin --tty webapp-worker-0 -c worker -- celery -A worker control shutdown

  #kubectl exec --stdin --tty webapp-worker-0 -c webapp -- killall webpack
  #kubectl exec --stdin --tty webapp-worker-0 -c webapp -- killall celery
  echo "Kill nginx"
  #kubectl exec --stdin --tty webapp-worker-0 -c webapp -- killall nginx
  exec_k8s "killall nginx"
  echo "Kill gunicorn"
  #kubectl exec --stdin --tty webapp-worker-0 -c webapp -- killall gunicorn
  exec_k8s "killall gunicorn"
else

  #INSTALL PATCHED FILES IN POD
  echo "ON WEBAPP"
  cd /webodm/app/media/patch/
  mkdir /webodm/auth0 #Missing dir
  for f in $FILELIST
  do
    echo "Installing patch file: $f..."
    cp "$f" "/webodm/$f"
  done
  cd /webodm
  pip install -r requirements.txt
fi

