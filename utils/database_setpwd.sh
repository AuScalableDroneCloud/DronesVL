#!/bin/bash
DBPOD=$(kubectl get pods | grep db- | awk '{print $1}')

CMDS="ALTER USER postgres PASSWORD '${POSTGRES_PASSWORD}';"
#CMDS="\l"
echo $CMDS

#kubectl exec --stdin --tty ${DBPOD} -- bash -c "export PATH=$PATH:/usr/local/pgsql/bin/; psql -c '$CMDS'"
#echo kubectl exec --stdin --tty ${DBPOD} -- bash -c "/usr/local/pgsql/bin/psql -c '$CMDS'"
#kubectl exec --stdin --tty ${DBPOD} -- /usr/local/pgsql/bin/psql -c "$CMDS"

#echo kubectl exec --stdin --tty ${DBPOD} -- /usr/local/pgsql/bin/psql -c \"$CMDS\"
#kubectl exec --stdin --tty ${DBPOD} -- /usr/local/pgsql/bin/psql -c \"$CMDS\"

#Instead of password, limit host
#sed -i 's/host all all all trust/host all all webapp-worker-0.webapp-service.default.svc.cluster.local trust/g' /var/lib/postgresql/data/pg_hba.conf
#sed -i 's/webapp-worker-0//g' /var/lib/postgresql/data/pg_hba.conf


#sed -i 's/host all all all trust/host all all .webapp-service.default.svc.cluster.local trust/g' /var/lib/postgresql/data/pg_hba.conf
