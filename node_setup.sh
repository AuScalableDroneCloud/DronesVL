#!/bin/bash
#Run on a node to do setup tasks
# - fix ./tmp
# - wait for ClusterODM
# - register self with ClusterODM
#
#Designed to use builtin shell features so
#no packages required (telnet/netcat/nslookup etc)

#Fix the tmp path storage issue
#(writes to ./tmp in /var/www, which fills ethemeral storage of docker image and node)
#(replace this with symlink to the persistent volume)
if ! [ -L /var/www/tmp ] ; then
  rm -rf /var/www/tmp;
  mkdir /var/www/data/tmp;
  ln -s /var/www/data/tmp /var/www/tmp;
fi

#Loop until clusterodm is running
CLUSTERODM=clusterodm
CLUSTERODM_PORT=8080
until getent hosts ${CLUSTERODM}
do
  echo "Waiting for ClusterODM to start"
  sleep 2
done
echo "ClusterODM is running : $1"

#Check if added already
exec {fd}<>/dev/tcp/${CLUSTERODM}/${CLUSTERODM_PORT}
sleep 0.1
echo -e "NODE LIST" >&${fd}
sleep 0.1
echo -e "QUIT" >&${fd}
if cat <&${fd} | grep $HOSTNAME; then
  echo "Node already added..."
else
  echo "Adding node to cluster..."
  exec {fd}<>/dev/tcp/${CLUSTERODM}/${CLUSTERODM_PORT}
  sleep 0.1
  echo -e "NODE ADD $HOSTNAME.nodeodm-svc 3000" >&${fd}
  sleep 0.1
  echo -e "QUIT" >&${fd}
fi



