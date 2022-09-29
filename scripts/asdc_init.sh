#!/bin/bash
#This runs on webapp-worker pod to initialise the webapp

#- Added patch script to copy in selected patched files
#- Added loop to apply patches and restart if main gunicorn process is killed 

#pip error fixed by adding to PATH:
export PATH=$PATH:/home/webodm/.local/bin

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
  #Uses different branches for production/development
  if [ "${ASDC_ENV}" = "PRODUCTION" ]; then
    BRANCH=main
  else
    BRANCH=development
  fi
  git reset origin/${BRANCH} --hard
  git branch --set-upstream-to=origin/${BRANCH} ${BRANCH}
fi

#Update the init files
git submodule update --init --recursive
git pull --recurse-submodules 

#Setup project storage link to s3 store
ln -s /webodm/app/store/project /webodm/app/media/project

#Wait for db server
/webodm/wait-for-postgres.sh db

# Main loop
# - apply patch (on dev only)
# - run webodm
# (by killing nginx process, patch update will be applied)
while :
do
  #Update the patch files
  cd /webodm/app/media
  git pull --recurse-submodules 

  cd /webodm

  echo Running patch on $HOSTNAME
  /webodm/app/media/patch/apply.sh

  /webodm/start.sh
done
