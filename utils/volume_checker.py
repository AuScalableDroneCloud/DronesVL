#!/usr/bin/env python

#FIX : just because a volume is available, doesn't mean it is not in use (pv exists)
# need to check the PV for volumeHandle that matches this volume id

#TODO: for future, before stopping the cluster we need to use this script to backup PV data for JupyterHub users
# - iterate all jupyterhub pvcs
# - launch a pod with this pvc + s3 mount
# - copy data to [asdc-store/asdc-dev-store]/home/[username]/autobackup/[servername]
#Claim names are of the form: 'claim-username' and 'claim-usernameservername'
#Annotations/labels:
#hub.jupyter.org/username=user-40email-2eedu-2eau
#hub.jupyter.org/servername=base
#import re
#s = 'user-40email-2eedu-2eau'
#s2 = re.sub('-[\dabcdef][\dabcdef]', lambda x: bytes.fromhex(x.group()[1:]).decode("utf-8"), s)
#print(s2)
            #For this to work for backup, will need to 
            # - get attached volumes of size 10,
            # - find their matching pv/pvc to get username and servername by labels
            # - decode the username
            # - create the backup pod, using the existing pv/pvc
            # - execute the backup with username/servername
            #servername = 'default'
            #username = 'chris.peters@csiro.au'
            #vidx = 60
            #cmd = f'kubectl exec -i -t test-{vidx} -- bash -c \'rsync -vz --no-perms --no-owner --no-group "/mnt/data/wheathub" "/mnt/store/home/{username}/autobackup/{servername}/"\''
            #cmd1 = f'kubectl exec -i -t test-{vidx} -- bash -c \'mkdir -p "/mnt/store/home/{username}/autobackup/{servername}/"\''
            #cmd2 = f'kubectl exec -i -t test-{vidx} -- bash -c \'cp -R "/mnt/data/wheathub" "/mnt/store/home/{username}/autobackup/{servername}/"\''
#exit()

#Get available volumes, start a pod and get a file listing for each
import subprocess
import os
import json
import dateutil.parser
import datetime

#Set this to only process a specific volume
use_vol_id = None
#use_vol_id = 'e68ef6b3-650e-4a39-bab0-9d998162935a'

def run_output(cmd, show=True):
    if show:
        print(cmd)
    output = subprocess.check_output(cmd, shell=True, text=True)
    if show:
        print(output)
    return output

cfile = 'cached_output.json'
j = {}
try:
    os.remove(cfile) #REMOVE THE CACHE - was only used to speed up testing but we want live data
    with open(cfile, 'r') as f:
        j = json.load(f)
except:
    output = run_output("openstack volume list --status 'Available' -f json", show=False)
    #openstack volume list --sort-column created_at
    j = json.loads(output)
    #'''
    #Get created / updated timestamps - THIS TAKES AGES
    print(f"Getting timestamps for {len(j)} volumes")
    for vidx in range(len(j)):
        if int(j[vidx]['Size']) != 10: continue
        vid = j[vidx]['ID']
        print(vid)
        output = run_output(f"openstack volume show {vid} -f json", show=False)
        j2 = json.loads(output)
        j[vidx]['created_at'] = j2['created_at']
        j[vidx]['updated_at'] = j2['updated_at']
        print(j[vidx])
        name = j[vidx]['Name']
        try:
            output = run_output(f"kubectl get pv {name}", show=False)
            print(" - KUBECTL GET PV EXISTS:",output)
            #TODO, Do not delete this volume
            j[vidx]['has_pv'] = True
        except (subprocess.CalledProcessError) as e:
            print(" - No pv exists")
            j[vidx]['has_pv'] = False
    #'''

    #print(output)
    with open(cfile, 'w') as f:
        json.dump(j, f)

for vidx in range(len(j)):
    vid = j[vidx]['ID']
    vsz = j[vidx]['Size']
    if use_vol_id is not None and use_vol_id != vid:
        #Skip until we find the right volume
        continue
    print(f'- [{vidx}] --------------------------------------------------------------------------------------------------------------------')
    print(j[vidx])
    if j[vidx]['has_pv']:
        print("Skipping volume, has kubernetes PV")
        continue

    #Inspect content of the 10GB jupyterhub volumes
    if int(vsz) == 10:
        dt = dateutil.parser.isoparse(j[vidx]['updated_at'])
        if dt < datetime.datetime(2022, 11, 1):
            print('Old volume!')
            print(j[vidx])
            print('-- Deleting unused volume...')
            run_output(f"openstack volume delete {vid}")
        else:
            print(f"Recent {j[vidx]['updated_at']}, launching pod...")

            output = run_output(f"export VOLUME_ID={vid}; export VOLUME_SIZE={vsz}; export VOLUME_INDEX={vidx}; ./volume_check.sh")
            print(output)
            output = run_output(f'kubectl exec -i -t test-{vidx} -- bash -c "du -s /mnt/data"')
            kb = int(output.split()[0])
            print(f"{kb:,} kbytes")
            if kb < 1500:
                print('EMPTY VOLUME, deleting')
                #Delete pod etc first, but wait for processes to finish
                run_output(f"kubectl delete pod test-{vidx}; kubectl delete pvc test-pvc-{vidx}; kubectl delete pv test-volume-{vidx};")
                run_output(f"openstack volume delete {vid}")

            #Delete the resources in background
            #print('Cleaning up...')
            #subprocess.Popen(f"kubectl delete pod test-{vidx}; kubectl delete pvc test-pvc-{vidx}; kubectl delete pv test-volume-{vidx};", shell=True)

    #Delete all other available volumes
    else:
        print('-- Deleting unused volume...')
        run_output(f"openstack volume delete {vid}")

