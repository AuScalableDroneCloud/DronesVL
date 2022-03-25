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
nginx/proxy.conf
nginx/letsencrypt-autogen.sh
auth0/urls.py
auth0/utils.py
auth0/views.py
auth0/pipeline.py
auth0/middleware.py
package.json
requirements.txt
webodm/settings.py
webodm/urls.py
app/models/task.py
app/api/authentication.py
"

#Run from the DronesVL repo base
BASEPATH=$(pwd)
#Default is to assume reference WebODM install in parent dir
WEBODMPATH=$(pwd)/../WebODM

if [ $HOSTNAME != 'webapp-worker' ]; then

  #COPY PATCHED FILES TO POD VOLUME
  echo "ON DEV PC"
  source $BASEPATH/settings.env
  cd $BASEPATH/patch/
  kubectl cp "apply.sh" "webapp-worker:/webodm/app/media/patch/" -c webapp
  for f in $FILELIST
  do
    DIR="$(dirname "${f}")"
    echo "Creating dir $DIR..."
    kubectl exec --stdin --tty webapp-worker -c webapp -- mkdir -p /webodm/app/media/patch/$DIR
    echo "Copying file $f..."
    kubectl cp "$WEBODMPATH/$f" "webapp-worker:/webodm/app/media/patch/$f" -c webapp
  done

  #To install patch, kill and restart main processes in pod...
  #echo "Kill celery"
  #kubectl exec --stdin --tty webapp-worker -c worker -- celery -A worker control shutdown

  #kubectl exec --stdin --tty webapp-worker -c webapp -- killall webpack
  #kubectl exec --stdin --tty webapp-worker -c webapp -- killall celery
  echo "Kill nginx"
  kubectl exec --stdin --tty webapp-worker -c webapp -- killall nginx
  echo "Kill gunicorn"
  kubectl exec --stdin --tty webapp-worker -c webapp -- killall gunicorn

else

  #INSTALL PATCHED FILES IN POD
  echo "ON WEBAPP"
  mkdir -p /webodm/app/media/patch/
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

