#Arbitrary python code appended to jupyterhub_config.py
#custom_auth:
def asdc_auth_state_hook(spawner, auth_state):
    if auth_state:
        spawner.environment = {
          "ASDC_USER_REFRESH_TOKEN": auth_state.get("refresh_token"),
          "ASDC_USER_ACCESS_TOKEN": auth_state.get("access_token"),
          "ASDC_USER_ID_TOKEN": auth_state.get("id_token"),
          "ASDC_API_ACCESS_TOKEN": auth_state.get("api_access_token"),
          "ASDC_AUTH0_USER": str(auth_state.get("auth0_user"))
        }
    else:
        print('auth_state not set!')
c.KubeSpawner.auth_state_hook = asdc_auth_state_hook

from jupyterhub.auth import Authenticator
from oauthenticator.auth0 import Auth0OAuthenticator
from tornado.httpclient import HTTPRequest
import json
class ASDCAuth(Auth0OAuthenticator):
    async def authenticate(self, handler, data=None):
        res = await super().authenticate(handler, data)

        import secrets
        nonce = secrets.token_urlsafe(nbytes=8)
        params = {
            'response_type' : 'token id_token',
            'client_id': self.client_id,
            #'client_secret': self.client_secret,
            'audience' : "https://${WEBAPP_HOST}/api",
            #'code': code,
            'redirect_uri': self.get_callback_url(handler),
            'nonce' : nonce,
            'state' : 'auth0,' + nonce,
        }
        print(params)

        url = self.token_url

        req = HTTPRequest(
            url,
            method="POST",
            headers={"Content-Type": "application/json"},
            body=json.dumps(params),
        )

        resp_json = await self.fetch(req)
        print(resp_json)

        api_access_token = resp_json['access_token']

        res['auth_state']['api_access_token'] = api_access_token
        return res

# and then declare the authenticator to be used, i don't remember how, see reference:
#c.JupyterHub.authenticator_class = 'ASDCAuth'
c.JupyterHub.authenticator_class = ASDCAuth
# https://jupyterhub.readthedocs.io/en/latest/reference/authenticators.html

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
    branch = "development" if "dev." in "${WEBAPP_HOST}" else "main"
    default_commands = [
      #Clean up previous mount dirs and links...
      "find /mnt/project -type d -empty -delete",
      "find /home/jovyan -type l -delete",
      "find /home/jovyan/ -type d -empty -delete",
      "rm -rf /home/jovyan/projects",
      #Save all checkpoints here
      "mkdir -p /home/jovyan/checkpoints",
      #Still have broken duplicate numpy, probably should install with conda install instead...
      "rm -rf /opt/conda/lib/python3.10/site-packages/numpy-1.23.4.dist-info || true",
      #Without a gitpuller command here the asdc server entrypoint fails to start,
      #it doesn't matter what repo is pulled, this makes completely no sense
      #but this must remain until I find out why
      'gitpuller https://github.com/auscalabledronecloud/test "" /tmp/test',
      #Install the asdc python utils module
      "pip uninstall --yes asdc",
      f"pip install --no-cache-dir https://github.com/auscalabledronecloud/asdc_python/archive/{branch}.zip",
      #Run the module, sets up project links etc
      "python -m asdc"
    ]

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
          #'default_url': '/lab'
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
      }
    ]

    #Get profiles from pipeline repo
    import requests
    username = self.user.name
    #if webodm is available, load the custom url
    try:
        url = f"https://${WEBAPP_HOST}/api/plugins/asdc/userpipelines?email={username}"
        response = requests.get(url, timeout=5)
        for pipeline in response.json():
            commands = []
            if ':' in pipeline['source']:
                #Pull provided source repo
                repo_dir = pipeline['tag']
                commands += [f'rm -rf {repo_dir}', f'git clone --depth 1 {pipeline["source"]} {pipeline["tag"]}']
            else:
                #Pull default pipelines-jupyter source repo
                #TODO: make this repo a var
                repo_dir = f"pipelines/{pipeline['source']}"
                commands += ['rm -rf pipelines', 'git clone --depth 1 https://github.com/AuScalableDroneCloud/pipelines-jupyter.git pipelines']
                commands += ['rm -rf pipelines', 'git clone --depth 1 https://github.com/AuScalableDroneCloud/pipelines-jupyter.git pipelines']

            commands += [f"pip install -r {repo_dir}/requirements.txt --quiet --no-cache-dir || true"]

            new_profile = {
                'display_name': pipeline['name'],
                'description': pipeline['description'],
                'slug' : pipeline['tag'],
                'kubespawner_override': {
                  'image': images[pipeline['image']],
                  'lifecycle_hooks': {
                    'postStart': {
                      'exec': {
                        'command': ["/bin/sh", "-c", ';'.join(default_commands + commands)]
                      }
                    }
                  }
                }
            }

            if pipeline['entrypoint']:
                #This works, but opens in old notebook interface, and jupytext still not working for .py files
                #new_profile['kubespawner_override']['default_url'] = f'/notebooks/{repo_dir}/{pipeline["entrypoint"]}'
                #Try to open in default lab workspace
                new_profile['kubespawner_override']['default_url'] = f'/lab/tree/{repo_dir}/{pipeline["entrypoint"]}'

            profile_list.extend([new_profile])

    except (Exception) as e:
        print("Exceptions:",e)

    return profile_list

async def dynamic_options_form(self):
    #https://github.com/jupyterhub/kubespawner/blob/main/kubespawner/spawner.py#L2908
    form = self._options_form_default()
    if callable(form):
        form = await form(self)
    #Tweaking form css
    form = form.replace('padding-bottom: 12px;', '')
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

c.KubeSpawner.profile_list = get_profiles
c.KubeSpawner.options_form = dynamic_options_form
c.JupyterHub.spawner_class = KubeFormSpawner

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
        response = requests.get(url, timeout=5)
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

    #Dump to file for debugging
    import json
    with open('debug.json', 'w') as file:
        file.write(json.dumps(spawner.user_options, indent=2))
        file.write(f'User name: {user_name}\n')
        file.write(json.dumps(spawner.volumes, indent=2))
        file.write(json.dumps(spawner.volume_mounts, indent=2))

    #Update the env here as singleuser.extraEnv does nothing
    spawner.environment.update({
        "ASDC_PROJECTS": ','.join(plist),
        "ASDC_TASKS": tasks,
        "JUPYTERHUB_URL": "https://jupyter.${WEBAPP_HOST}",
        "JUPYTER_OAUTH2_API_AUDIENCE": "https://${WEBAPP_HOST}/api",
        "JUPYTER_OAUTH2_CLIENT_ID": "${WO_AUTH0_KEY}",
        "JUPYTER_OAUTH2_DEVICE_CLIENT_ID": "${WO_AUTH0_DEVICE_KEY}",
        "JUPYTER_OAUTH2_SCOPE": "openid profile email",
        "JUPYTER_OAUTH2_AUTH_PROVIDER_URL": "https://${WO_AUTH0_SUBDOMAIN}.auth0.com"
    })

c.KubeSpawner.pre_spawn_hook = profile_pvc

