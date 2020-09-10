# DronesVL

## ASDC service deployment with OpenStack and Kubernetes

Owen Kaluza, Monash University, 2020

A set of kubernetes pods / services / deployments for the Australia's Scalable Drone Cloud project

Initial implementation for Monash *DronesVL*:
 - Run a WebODM web frontend and OpenDroneMap service
 - Run a ClusterODM cluster and linked NodeODM processing nodes

The starting point .yaml files was the output of conversion from the docker-compose.yml provided with WebODM with the Kompose tool, but this did not produce a working configuration and they have been heavily modified since.

This is orchestrated using OpenStack Container Orchestration Engine (openstack magnum) to run on the ARDC Nectar Cloud.

The cluster could run on other services using the same Kubernetes setup, but all the deployment scripts would need to be heavily modified to work on each platform, using a different API for the provisioning of instances, volumes, load-balancers and ips etc.

### Requirements / dependencies

This was build on an Ubuntu 20.04 based system, on a similar Debian based system you can try running the included `install.sh` to install dependencies.

Alternatively, inspect `install.sh` to see required packages and install equivalents for your system.

### Configuration

Configuration is stored in `settings.env`

To setup OpenStack API access you'll need your .rc file, either source it before using the scripts or put it in the working directory and set `RC_FILE` in `settings.env`

The Kubernetes config for the cluster will be managed automatically using openstack coe.

### Usage

To launch / configure the cluster, source the main initialisation script:

`source asdc_run.sh`

This will attempt to bring up the cluster from scratch, but if it is already running will check each stage and deploy components or configure them as necessary until everything checks out as up and running.

To just connect to an existing cluster to run openstack / kubectl commands, just load the settings file:

`source settings.env`

To destroy the cluster:

`./asdc_stop.sh`

This will delete all instances but leave the volumes as they hold the user data.

To restart the WebODM instance only:

`./asdc_update.sh webapp`

NOTE: Warning: due to an issue with how openstack coe and kubernetes interact, it is important to never delete the `webapp-service` kubernetes service manually, as it will release the external floating ip used to access the cluster from the internet and there is no way to grab this same IP again, which means the DNS records will need updating!

If changes to this service need to be tested, run the update script as follows to un-link the ip from the webapp-service:

`./asdc_update.sh ip`

If it completes without errors then is will be safe to run `kubectl delete service webapp-service`.

Re-run `source asdc_run.sh` to re-activate the service as just recreating it is not enough, it needs the reserved floating ip to be assigned again to replace the new automatically assigned ip once it comes up.

