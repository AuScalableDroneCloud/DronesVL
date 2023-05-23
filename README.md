# DronesVL

## ASDC service deployment with OpenStack and Kubernetes

Owen Kaluza, Monash University, 2020-22

A set of kubernetes pods / services / deployments for the Australia's Scalable Drone Cloud project

Initial implementation for Monash *DronesVL*:
 - Run a WebODM web frontend and OpenDroneMap service
 - Run a ClusterODM cluster and linked NodeODM processing nodes

This is orchestrated using OpenStack Container Orchestration Engine (openstack magnum) to run on the ARDC Nectar Cloud.

The cluster could run on other services using the same Kubernetes setup, but all the deployment scripts would need to be modified to work on each platform, using a different API for the provisioning of cluster and storage volumes.

All the deployments are now managed by [FluxCD](https://fluxcd.io/) v2, using the asdc-infra repo.

### Requirements / dependencies

This was build on an Ubuntu based system, on a similar Debian based system you can try running the included `install.sh` to install dependencies.

Alternatively, inspect `install.sh` to see required packages and install equivalents for your system.

### Configuration

Configuration is stored in `settings.env`

To setup OpenStack API access you'll need your .rc file, either source it before using the scripts or put it in the working directory and set `RC_FILE` in `settings.env`. (Due to limitations in OpenStack, only the admin that creates clusters can administer them, so you will not be able to use these features unless you are bringing up the cluster from scratch, but you can connect with kubectl and administer the cluster that way.)

The Kubernetes config for the cluster will be managed automatically using openstack coe. The kubeconfig files are kept in the secrets repo and can thus be accessed by other admins.

Secrets are encrypted in a private repo and will be retrieved automatically if the keyfile is present.

Key file is shared via [keybase](https://keybase.io/) [team folder](https://keybase.io/team/asdc), and will be copied from this folder automatically if keybase CLI is installed.

### Basic Usage

To just connect to an existing cluster to run openstack / kubectl commands, just load the settings file:

`source settings.env`

This will attempt to install and configure everything necessary if you have just cloned this repo, but only tested on an Ubuntu 20.04+ environment.

### Administration

To launch / configure the cluster, source the main initialisation script:

`source asdc_run.sh`

This will attempt to bring up the cluster from scratch, but if it is already running will check each stage and deploy components or configure them as necessary until everything checks out as up and running.

To update changes to variables in settings.env and secrets/secret.env:

`./asdc_update.sh`

To destroy the cluster:

`./asdc_stop.sh`

The default is to deploy/modify the development environment.
To modify the production environment, before running any of above, set:

`export ASDC_ENV=PRODUCTION`

Current production configuration is in the 'master' branch of this repo, changes to development deployment are in the 'development' branch, merged to master when released.

