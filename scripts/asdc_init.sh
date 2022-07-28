#!/bin/bash
#This runs on webapp-worker pod to initialise the webapp

#- Added patch script to copy in selected patched files
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
  #TODO: different branches for production/development!
  #need to set an env var 
  git reset origin/main --hard
  git branch --set-upstream-to=origin/main main
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

  #Applying patch on dev/prod for now as some changes are neccessary
  #Only patch on dev, production changes need to be in image
  echo Running patch on $HOSTNAME
  /webodm/app/media/patch/apply.sh

  /webodm/start.sh
done
