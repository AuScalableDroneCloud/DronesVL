#Arbitrary python code appended to jupyterhub_config.py
#https://jupyterhub.readthedocs.io/en/stable/api/app.html

#hub: |
c.JupyterHub.tornado_settings = { 'headers': { 'Content-Security-Policy': 'frame-ancestors self https://${WEBAPP_HOST}'}}
c.JupyterHub.allow_named_servers = True #Allow named servers: https://jupyterhub.readthedocs.io/en/stable/reference/rest.html

#spawner: |
#Allow iframe (still doesn't support iframe for auth0 unfortunately)
c.Spawner.args = ['--NotebookApp.tornado_settings={"headers":{"Content-Security-Policy": "frame-ancestors * self https://${WEBAPP_HOST}"}}',
                  '--FileCheckpoints.checkpoint_dir="/home/jovyan/checkpoints"']

#options_form:
#https://github.com/neurohackademy/nh2020-jupyterhub/blob/da35049a93d372fe501b7968687e703a5e048e30/deployments/hub-neurohackademy-org/config/prod.yaml#L213-L289
# Configure what spawn options users should see
# ---------------------------------------------
#
# NOTE: setting c.KubeSpawner.profile_list directly is easier, but then
#       we don't have the option to adjust it based on the individual
#       user at a later point in time if we want.
#
# NOTE: c.KubeSpawner.options_form, defined in the Spawner base class,
#       can be set to a fixed value, but it can also be a callable
#       function that returns a value. If this returned value is falsy,
#       no form will be rendered. In this case, we setup a callable
#       function that relies on KubeSpawner's internal logic to create
#       an options_form from the profile_list configuration.
#
#       ref: https://github.com/jupyterhub/jupyterhub/pull/2415
#       ref: https://github.com/jupyterhub/jupyterhub/issues/2390
#
def get_profiles(self):
    import z2jh
    images = z2jh.get_config('custom.images')
    #WARNING: These commands run asynchronously to those in asdc-start-notebook.sh
    #k8s runs the postStart hook as a process in the new container, while the entrypoint
    #script is progressing. Avoid doing anything here that could break the startup
    #(like uninstalling and re-installing the asdc package for instance)
    default_commands = []

    #Default profiles, no pipeline just open the dev environment
    #NOTE: can set affinity for GPU pods here, for now let the cpu image run on gpu nodes
    # as they have more memory etc
    #c.KubeSpawner.node_affinity_preferred
    #c.KubeSpawner.node_affinity_required
    #c.KubeSpawner.node_selector
    profile_list = [
      {
        'display_name': 'ASDC base environment, CPU only',
        'description': 'Python with ASDC base libraries but no cuda/gpu access.',
        'slug' : 'base',
        #'default': 'true',
        'kubespawner_override': {
          'image': images['base'],
          #'cpu_guarantee': 2,
          #'cpu_limit': 2,
          #'mem_guarantee': '2096M',
          #'mem_limit': '8192M',
          'lifecycle_hooks': {
            'postStart': {
              'exec': {
                'command': ["/bin/sh", "-c", ';'.join(default_commands)]
              }
            }
          }
        }
      }, {
        'display_name': 'GPU + ASDC base environment',
        'description': 'Python with ASDC base libraries and examples and GPU support.',
        'slug' : 'gpu',
        'kubespawner_override': {
          'image': images['gpu'],
          'lifecycle_hooks': {
            'postStart': {
              'exec': {
                'command': ["/bin/sh", "-c", ';'.join(default_commands)]
              }
            }
          }
        }
      }, {
        'display_name': 'ML + GPU + ASDC base environment',
        'description': 'Python with ASDC base libraries and examples and GPU support, with additional ML libraries.',
        'slug' : 'ml',
        'kubespawner_override': {
          'image': images['ml'],
          'lifecycle_hooks': {
            'postStart': {
              'exec': {
                'command': ["/bin/sh", "-c", ';'.join(default_commands)]
              }
            }
          }
        }
      }
    ]

    return profile_list

async def dynamic_options_form(self):
    #https://github.com/jupyterhub/kubespawner/blob/main/kubespawner/spawner.py#L2908
    form = self._options_form_default()
    if callable(form):
        form = await form(self)
    #Tweaking form css
    form = form.replace('padding-bottom: 12px;', '')
    return form
    #SKIP PROJECT/TASK FIELDS HERE, LEAVING CODE FOR FUTURE REFERENCE
    #Custom fields
    form += """
    <div>
      <label class="profile" for="asdc_prj_list">Projects to mount (comma separated ID)</label>
      <input type="text" id="asdc_prj_list" name="projects">
    </div>
    <div>
      <label class="profile" for="asdc_task_list">Tasks to process (comma separated)</label>
      <input type="text" id="asdc_task_list" name="tasks">
    </div>
    """
    return form

#To support custom user_data, we have to override options_from_form to parse the form data
from kubespawner import KubeSpawner
class KubeFormSpawner(KubeSpawner):
    def options_from_form(self, formdata):
        #Get defaults ("profile" and "profile-option-{profile}-*")
        options = self._options_from_form(formdata)
        if 'projects' in formdata:
            options['projects'] = formdata['projects'][0]
        if 'tasks' in formdata:
            options['tasks'] = formdata['tasks'][0]
        #options['select'] = formdata['select'] # list already correct
        return options

#https://github.com/jupyterhub/jupyterhub/blob/main/jupyterhub/handlers/base.py#L1667
from urllib.parse import parse_qs, parse_qsl, urlencode, urlparse, urlunparse
from tornado.httputil import url_concat
from jupyterhub.utils import url_path_join
async def user_redirect_hook(path, request, user, base_url):
    #Support our built-in server names for user-redirect
    user_url = user.url
    if '/' in path:
        server, path = path.split('/', 1)
    else:
        server = ''
        path = path
    if server in ['base', 'gpu', 'ml']:
        user_url = url_path_join(user_url, server, path)
        if request.query:
            user_url = url_concat(user_url, parse_qsl(request.query))

        url = url_concat(
            url_path_join(
                base_url,
                "spawn",
                user.escaped_name,
                server,
            ),
            {"next": user_url},
        )
        return url

    #Just use the default action
    return None

c.KubeSpawner.profile_list = get_profiles
c.KubeSpawner.options_form = dynamic_options_form
c.JupyterHub.spawner_class = KubeFormSpawner
c.JupyterHub.user_redirect_hook = user_redirect_hook

#volumes: |
#Here we setup custom volume mounts
async def profile_pvc(spawner):
    #https://github.com/DigiKlausur/e2x-jupyterhub/blob/master/kubernetes/jupyterhub/config-e2x-exam.yaml
    await spawner.load_user_options()
    #Get our username (email)
    user_name = spawner.user.name
    # clear spawner attributes as Python spawner objects are peristent
    # if you dont clear them, they will be persistent across restarts
    # there may be duplicate mounts
    # (need to leave the first element though as is the default mount)
    #spawner.volumes = spawner.volumes[0:1]
    #spawner.volume_mounts = spawner.volume_mounts[0:1]

    #Per-user object storage mount
    spawner.volume_mounts.extend([
        {
            #"mountPath": "/mnt/user_data",
            "mountPath": f"/home/jovyan/{user_name}",
            "subPath": f"home/{user_name}",
            "name": "asdc-store-s3",
        }
    ])
    spawner.volumes.extend([
        {
            "name": "asdc-store-s3",
            "persistentVolumeClaim": {"claimName": "asdc-store-s3-pvc"},
        }
    ])

    #Get spawner args
    # eg: https://jupyter.${WEBAPP_HOST}/hub/spawn?profile=exp&projects=ID1-ID2
    import re
    plist = re.split('\W+', spawner.user_options.get("projects", ""))
    tasks = spawner.user_options.get("tasks", "")
    if len(plist):
        #Get project ids we have access to
        import requests
        url = f"https://${WEBAPP_HOST}/api/plugins/asdc/userprojects?email={user_name}"
        response = requests.get(url, timeout=15)
        projects = []
        if response.ok:
           projects = response.json()

        for pr_id in plist:
            #Important: check id is in user's project list
            if pr_id in projects:
                #If it is a view only shared project, mount as read only
                readonly = projects[pr_id]["readonly"]
                subpath = f'project/{pr_id}'
                #Add the mount
                spawner.volume_mounts.extend([
                    {
                        "mountPath": f"/mnt/{subpath}",
                        "subPath": subpath,
                        "name": "asdc-store-s3",
                        "readOnly": readonly,
                    }
                ])

    #Update the env here as singleuser.extraEnv does nothing
    spawner.environment.update({
        "ASDC_PROJECTS": ','.join(plist),
        "ASDC_TASKS": tasks,
        "ASDC_INPUT_FILE": "/home/jovyan/.local/inputs.json",
        "ODM_TOKEN_PREFIX": "Bearer",
        "JUPYTERHUB_URL": "https://jupyter.${WEBAPP_HOST}",
        "JUPYTER_OAUTH2_API_AUDIENCE": "https://${WEBAPP_HOST}/api",
        "JUPYTER_OAUTH2_CLIENT_ID": "${WO_AUTH0_KEY}",
        "JUPYTER_OAUTH2_API_CLIENT_ID": "${WO_AUTH0_API_KEY}",
        "JUPYTER_OAUTH2_DEVICE_CLIENT_ID": "${WO_AUTH0_DEVICE_KEY}",
        "JUPYTER_OAUTH2_SCOPE": "openid profile email",
        "JUPYTER_OAUTH2_AUTH_PROVIDER_URL": "https://${WO_AUTH0_SUBDOMAIN}.auth0.com"
    })

    #Dump to file for debugging
    #import json
    #with open('debug.json', 'w') as file:
    #    file.write(json.dumps(spawner.environment, indent=2))
    #    file.write(json.dumps(spawner.user_options, indent=2))
    #    file.write(f'User name: {user_name}\n')
    #    file.write(json.dumps(spawner.volumes, indent=2))
    #    file.write(json.dumps(spawner.volume_mounts, indent=2))

c.KubeSpawner.pre_spawn_hook = profile_pvc

#Increased timeouts to 10min
c.KubeSpawner.http_timeout = 600
c.KubeSpawner.start_timeout = 600

