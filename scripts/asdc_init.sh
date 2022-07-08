#!/bin/bash
#This runs on webapp-worker pod to initialise the webapp and setup SSL

#- Added loop to wait for hostname to respond, we need to wait for the service to come up and the load-balancer IP to be changed
#to allow SSL before running start.sh
#- Added patch/apply.sh to copy in selected patched files
#- Added loop to apply patches and restart if main gunicorn process is killed 

cd /webodm/app/media/
#Clone the init files if not yet a git repo
if [ ! -s ".git/config" ]
then
  #This will work even if /webodm/app/media is not empty dir
  git config --global init.defaultBranch main
  git config pull.rebase false
  git init
  git remote add origin https://github.com/auscalabledronecloud/asdc-init.git
  git fetch
  git reset origin/main --hard
  git branch --set-upstream-to=origin/main main
fi

#Update the init files
git submodule update --init --recursive
git pull --recurse-submodules 

#Setup project storage link to s3 store
ln -s /webodm/app/store/project /webodm/app/media/project
#Copy certs if any
mkdir -p /webodm/app/media/ssl/
cp -R /webodm/app/store/ssl/* /webodm/app/media/ssl/

#Wait for db server
/webodm/wait-for-postgres.sh db

#Wait for host to be resolvable
echo "Waiting for" ${WO_HOST}
while :
do
  printf '.'
  timeout 5.0 curl -sL ${WO_HOST}:443 &> /dev/null
  RES=$?
  if [[ "$RES" != '124' ]]
  then
    break
  fi
done

echo $WO_SSL
echo $WO_SSL_KEY
echo $WO_SSL_CERT
mkdir -p /webodm/nginx/ssl/${WO_HOST}

function start_server()
{
  #Runs a test server on given port
  #Args:
  PORT=$1 #Internal port
  echo "Starting test server {PORT}"
  python -m http.server ${PORT} &
}

function test_server()
{
  #Wait for a response from test server
  #Args:
  URL=$1  #External URL:port

  echo "Waiting for access via load balancer at ${URL}"
  while ! timeout 2.0 curl ${URL} &> /dev/null;
    do printf '*';
    sleep 5;
  done;
  echo ""

}

# Main loop
# - check certs, create if required
# - apply patch
# - run webodm
# (by killing nginx process, patch update will be applied)
while :
do
  #Now keeping ssl certs in /webodm/app/store/ssl
  CERT_STORE=/webodm/app/media/ssl/${WO_HOST}
  #CERT_STORE=/webodm/app/store/ssl/${WO_HOST}
  #CERT_STORE=/webodm/app/media/ssl
  if [ ! -s "${CERT_STORE}/cert.pem" ]
  then
    mkdir -p ${CERT_STORE}
    cd ${CERT_STORE}

    #By default, webodm will attempt to setup SSL when enabled and no cert or key passed
    #This does not work until the loadbalancer is fully provisioned,
    #so initially we loop until the HTTPS port is open and responding,
    #Then manually run letsencrypt-autogen.sh to generate the certificates
    rm *.pem

    #Wait for the server to be reachable
    #(this can take a while while the service/load balancer starts)
    #Test both HTTPS (443:8000) and HTTP (80:8080) ports
    start_server 8000
    start_server 8080
    test_server http://${WO_HOST}:443
    test_server http://${WO_HOST}

    #Kill running servers
    killall python
    sleep 5;

    #Attempt up to 5 times to get certs
    for i in {0..5}
    do
      echo "~~~~~~~~~~~~~~~~~~~~~~ RUNNING CERTBOT TO GET CERTS ~~~~~~~~~~~~~~~~~~~~~~"
      WO_SSL_KEY='' /webodm/nginx/letsencrypt-autogen.sh
      if [ ! -s "/webodm/nginx/ssl/cert.pem" ];
      then
        sleep 60;
      else
        break
      fi
    done;

    #Copy new (symlinked) certs
    cp /webodm/nginx/ssl/*.pem ${CERT_STORE}
  fi

  # Replace symlinks if not present
  ln -s ${CERT_STORE}/cert.pem /webodm/nginx/ssl/cert.pem
  ln -s ${CERT_STORE}/key.pem /webodm/nginx/ssl/key.pem

  #Update the patch files
  cd /webodm/app/media
  git pull --recurse-submodules 
  cd /webodm
  /webodm/app/media/apply.sh
  /webodm/start.sh
done
