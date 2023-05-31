#Example of using the django models interface to query the WebODM database
#Needs to be run in the WebODM container
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "webodm.settings")
application = get_wsgi_application()

from app.models import Project, Task
from django.db import models
from django.contrib.auth.models import User

email = "owen.kaluza@monash.edu"
user = User.objects.get(email = email)



print(user)
#print(dir(user))

projects = Project.objects.filter(owner_id = user.id)
print(projects)
#plist = [{"id": p.id, "name": p.name, "description": p.description} for p in projects]
plist = {p.id: True for p in projects}
print(plist)

print(user.projectuserobjectpermission_set)
print(dir(user.projectuserobjectpermission_set))

#Permission codenames:
"""
# Have the proper permissions been set?
self.assertTrue(user.has_perm("view_project", p))
self.assertTrue(user.has_perm("add_project", p))
self.assertTrue(user.has_perm("change_project", p))
self.assertTrue(user.has_perm("delete_project", p))
"""
#for e in user.projectuserobjectpermission_set.filter(permission=38):
for e in user.projectuserobjectpermission_set.all():
    print("PERM: ", e.permission, e.permission.id, e.permission.codename)
    print("USER: ", e.user, e.user_id)
    print("CONTENT:", e.content_object_id, e.content_object)
    if e.permission.codename == "change_project":
        plist[e.content_object_id] = True
    elif e.permission.codename == "view_project" and not e.content_object_id in plist:
        plist[e.content_object_id] = False

print(plist)

def get_user_projects(email, detail=True):
    try:
        user = User.objects.get(email = email)
        #Get users own projects
        projects = Project.objects.filter(owner_id = user.id)
        if detail:
            plist = {p.id: {"name": p.name, "description": p.description, "readonly": False} for p in projects}
        else:
            plist = {p.id: {"readonly": False} for p in projects}

        #Get the shared projects this user has access to (including view only)
        for e in user.projectuserobjectpermission_set.all():
            entry = {"readonly": False}
            if detail:
                entry = {"name": e.content_object.name, "description": e.content_object.description, "readonly": False}
            if e.permission.codename == "change_project":
                plist[e.content_object_id] = entry
            elif e.permission.codename == "view_project" and not e.content_object_id in plist:
                entry["readonly"] = True
                plist[e.content_object_id] = entry
    except:
        plist = {}
    return plist

import json
print(json.dumps(get_user_projects(email), indent=2))
