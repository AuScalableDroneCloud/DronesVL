#!/bin/bash
# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.
set -e

#Setting PYTHONPATH for asdc and defining the server traitlets seems to fix the server load issues
#(if either are removed things don't seem to work reliably)
# - PYTHONPATH fixes the import error when jupyter_server_proxy starts
# - jupyter_server_config.py entry allows the server to start as the setup.py entrypoint
#   no longer seems to work
echo "Launching ASDC Jupyter Server"
export PYTHONPATH=${PYTHONPATH}:$(python -c "import asdc; import os; print(os.path.dirname(asdc.__file__))")

rm -rf .jupyter
mkdir -p ~/.jupyter
echo "c.ServerProxy.servers = {
  'asdc': {
    'command': ['python', '-m', 'asdc.server', '{port}', '{base_url}'],
    'timeout' : 20,
  }
}" > ~/.jupyter/jupyter_server_config.py

# set default ip to 0.0.0.0
if [[ "${NOTEBOOK_ARGS} $*" != *"--ip="* ]]; then
    NOTEBOOK_ARGS="--ip=0.0.0.0 ${NOTEBOOK_ARGS}"
fi

echo "ARGS: ${NOTEBOOK_ARGS} $@"

# shellcheck disable=SC1091,SC2086
. /usr/local/bin/start.sh jupyterhub-singleuser ${NOTEBOOK_ARGS} "$@"
