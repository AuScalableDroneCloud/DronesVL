#!/bin/bash
#This runs on database pod to initialise and check the database
cd $PGDATA

# Give postgres user (id 999) ownership of mounted volume
chown -R 999:999 $PGDATA
chmod -R 700 $PGDATA

# run resize2fs in case volume has been expanded
DEVICE=$(df "/var/lib/postgresql/data" | tail -1 | awk '{ print $1 }');
echo "Ensuring fs size correct for $DEVICE"
resize2fs ${DEVICE};

#Example of fix to postgresql.conf (this was a temporary fix)
#sed -i "s/dynamic_shared_memory_type = posix/dynamic_shared_memory_type = none/g" $PGDATA/postgresql.conf;

#Start PostgreSQL
su -m postgres -c "/usr/local/bin/docker-entrypoint.sh"
su -m postgres -c "/usr/local/pgsql/bin/postgres" &
sleep 5

USED=$(df -h --output=pcent /var/lib/postgresql/data | sed 's/[^0-9]//g' | tr -d " \t\n\r";)
BIGFILE=$PGDATA/DO_NOT_REMOVE_THIS_FILE
echo "$DEVICE : $USED % in use"
if [ ${USED} -gt 90 ]; then 
  echo "WARNING: Database volume running low on space..."
  #Remove the reserve file in case space is critically low
  rm $BIGFILE
  # Run vacuum full on the webodm db
  psql -d webodm_dev -c 'vacuum full'
fi

# Create a 1GB file to reserve space
# this can be deleted if the disk fills up to
# allow fixing the issues and running commands
# https://www.endpointdev.com/blog/2014/09/pgxlog-disk-space-problem-on-postgres/
if [ ! -f "$BIGFILE" ]; then
  dd if=/dev/zero of=$BIGFILE bs=1MB count=1024
fi

# Create a local backup of the database too
pg_dump -U postgres -F c webodm_dev > webodm_dev.dump

echo "FINISHED"
#chmod -R 1777 /dev/shm

#sleep 5000
