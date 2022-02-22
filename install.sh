#!/bin/bash
#Install openstack python packages, use virtual env or user 
if env |grep VIRTUAL_ENV;
then
  echo "pip installing in virtualenv $VIRTUAL_ENV"
  pip install -r requirements.txt
else
  echo "pip installing with --user"
  pip install --user -r requirements.txt
fi

#Install kubectl + helm if not present
if [ "$1" == "force" ] || [ ! command -v kubectl &> /dev/null ]
then
  #Add cwd to path so kubectl can be run without dir
  PATH=$PATH:$(pwd)
  if [ "$1" == "force" ] || [! command -v kubectl &> /dev/null ]
  then
    echo "kubectl could not be found! attempting to download..."
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x ./kubectl
  fi
fi

#Install helm if not found
if [ "$1" == "force" ] || [ ! command -v helm &> /dev/null ]
then
  echo "helm could not be found! attempting to download..."
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
  chmod 700 get_helm.sh
  ./get_helm.sh
fi

#Install flux if not found
if [ "$1" == "force" ] || [ ! command -v flux &> /dev/null ]
then
  echo "flux could not be found! attempting to download..."
  curl -s https://fluxcd.io/install.sh -o flux_install.sh
  chmod 700 flux_install.sh
  ./flux_install.sh
fi
