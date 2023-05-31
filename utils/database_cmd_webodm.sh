#!/bin/bash
DBPOD=$(kubectl get pods | grep db- | awk '{print $1}')

kubectl exec --stdin --tty ${DBPOD} -- bash -c "export PATH=$PATH:/usr/local/pgsql/bin/; psql -d webodm_dev -t -c '$@'"

