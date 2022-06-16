#!/bin/bash
#This runs on webapp-worker pod to initialise the webapp and setup SSL

#- Added loop to wait for hostname to respond, we need to wait for the service to come up and the load-balancer IP to be changed
#to allow SSL before running start.sh
#- Added patch/apply.sh to copy in selected patched files
#- Added loop to apply patches and restart if main gunicorn process is killed 

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
mkdir -p /webodm/nginx/ssl

#Now keeping ssl certs in /webodm/app/media/ssl
if [ ! -s "/webodm/app/media/ssl/cert.pem" ]
then
  mkdir -p /webodm/app/media/ssl
  cd /webodm/app/media/ssl

  #By default, webodm will attempt to setup SSL when enabled and no cert or key passed
  #This does not work until the loadbalancer is fully provisioned,
  #so initially we loop until the HTTPS port is open and responding,
  #Then manually run letsencrypt-autogen.sh to generate the certificates
  rm *.pem

  echo "Starting test server"
  python -m http.server 8000 & # listen on the https port 8000:443

  #Wait for the server to be reachable on https
  #(THIS CAN TAKE A WHILE)
  echo "Waiting for initial https port via load balancer at http://${WO_HOST}:443"
  while ! timeout 2.0 curl http://${WO_HOST}:443 &> /dev/null;
    do printf '*';
    sleep 5;
  done;
  echo ""
  #Kill running server
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
  cp /webodm/nginx/ssl/*.pem /webodm/app/media/ssl/
fi

# Replace symlinks if not present
ln -s /webodm/app/media/ssl/cert.pem /webodm/nginx/ssl/cert.pem
ln -s /webodm/app/media/ssl/key.pem /webodm/nginx/ssl/key.pem

cd /webodm

# Main loop
# - apply patch
# - run webodm
# (by killing nginx process, patch update will be applied)
while :
do
  /webodm/app/media/patch/apply.sh
  /webodm/start.sh
done
