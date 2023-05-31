# Collection of changelogs from tagged repos
import subprocess
import os
from pathlib import Path
from datetime import datetime
now = datetime.now() # current date and time
ts = now.strftime("%Y-%m-%d")


#Start the upgrade, stop flux etc
basedir = Path.home() / "Sync" / "ASDC"
reldir = basedir / f"RELEASE-{ts}"
repos = ['WebODM', 'pipelines', 'DronesVL', 'asdc-infra', 'asdc-init', 'asdc-python'] #, 'cesium-asdc', 'cesium-api', 'terria-asdc', ]
branches = ['master', 'main', 'master', 'production', 'main', 'main'] #, 'main', 'main', 'main', ]

#SETUP - get production env and stop flux
print("----------------------------------------")
os.makedirs(reldir, exist_ok=True)
for repo, branch in zip(repos, branches):
    if os.path.exists(basedir / repo):
        path = str(basedir / repo)
    else:
        #Try in home
        path = str(Path.home() / repo)
    print(f"-- Running in {path} --")
    cmd = f"""cd {path}
    #Get changelogs
    #Get most recent tag
    if TAG=$(git describe --tags --abbrev=0); then
        echo "-- {repo} : Change log since last tag: $TAG"
        #Ignoring merge commits (all commits since last tag)
        git log $TAG..@ --oneline | sed '/Merge/d'
    else
        git log --oneline {branch}..development | sed '/Merge/d'
    fi
    """
    output = subprocess.check_output(cmd, shell=True, text=True)
    #print(output)

    with open(reldir / f"CHANGELOG-{repo}-{ts}.txt", 'w') as of:
        of.write(output)
