#!/bin/bash
if [ "$#" -eq 0 ]; then
  echo List databases
  echo \# \\l

  echo Connect to database
  echo \# \\c webodm_dev

  echo List tables
  echo \# \\dt

  echo Describe table
  echo \# \\d app_imageupload

  echo SQL
  echo "# select * from app_theme;"
fi

#Default command is to open the postgres interpreter
CMD=${1:-psql}

DBPOD=$(kubectl get pods | grep db- | awk '{print $1}')

kubectl exec --stdin --tty ${DBPOD} -- bash -c "export PATH=$PATH:/usr/local/pgsql/bin/; ${CMD}"

#eg: dump a table
#./database_cmds.sh "pg_dump --table=yourTable --data-only --column-inserts yourDataBase"
#./database_cmds.sh "pg_dump --table=app_theme --data-only --column-inserts webodm_dev"

#select id,username from auth_user order by id;

#select * from app_project;

#./database_cmds.sh "psql -d webodm_dev -c 'select id,username from auth_user order by id;'"

