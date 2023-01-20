#!/bin/bash
# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.
set -e

echo "Launching ASDC Jupyter Server"

#-- previously in postStart hook from jupyterhub_config.py
#Clean up previous mount dirs and links...
find /mnt/project -type d -empty -delete || true
#"find /home/jovyan -type l -delete",
#"find /home/jovyan/ -type d -empty -delete",
rm -rf /home/jovyan/projects || true
#Fix package leftovers installed in .local and remove inputs.json
rm -rf /home/jovyan/.local/* || true
rm /home/jovyan/.jupyter/* || true
#Save all checkpoints here
mkdir -p /home/jovyan/checkpoints || true

#Update asdc_python module
BRANCH="main"
echo JUPYTERHUB_URL: ${JUPYTERHUB_URL}
if [ "${JUPYTERHUB_URL}" == "https://jupyter.dev.asdc.cloud.edu.au" ]; then
  BRANCH="development"
fi
echo Using asdc_python branch: $BRANCH
python -m pip uninstall --yes asdc
python -m pip install --no-cache-dir https://github.com/auscalabledronecloud/asdc_python/archive/${BRANCH}.zip

#Run the module, sets up project links etc
python -m asdc

# set default ip to 0.0.0.0
if [[ "${NOTEBOOK_ARGS} $*" != *"--ip="* ]]; then
    NOTEBOOK_ARGS="--ip=0.0.0.0 ${NOTEBOOK_ARGS}"
fi

echo "ARGS: ${NOTEBOOK_ARGS} $@"

# shellcheck disable=SC1091,SC2086
. /usr/local/bin/start.sh jupyterhub-singleuser ${NOTEBOOK_ARGS} "$@"

