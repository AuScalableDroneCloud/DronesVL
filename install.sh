#!/bin/bash
PYPACKAGES="python-openstackclient python-novaclient python-heatclient python-magnumclient python-manilaclient"
#PYPACKAGES="python-openstackclient python-novaclient python-heatclient python-magnumclient python-manilaclient python-keystoneclient"

#Install openstack python packages, use virtual env or user 
if env |grep VIRTUAL_ENV;
then
  echo "pip installing in virtualenv $VIRTUAL_ENV"
  pip install $PYPACKAGES
else
  echo "pip installing with --user"
  pip install --user $PYPACKAGES
fi

#Install kubectl?
if [ ! -f ./kubectl ] && ! which kubectl;
then
  # https://kubernetes.io/docs/tasks/tools/install-kubectl/
  curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"

  chmod +x ./kubectl
fi

