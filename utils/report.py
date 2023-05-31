import query
from kubernetes.stream import stream
from kubernetes import client, config

config.load_kube_config('../secrets/kubeconfig')

v1 = client.CoreV1Api()

#help(v1.connect_get_namespaced_pod_exec)

def get_disk_usage(pid):
    exec_command = [
        '/bin/sh',
        '-c',
        'du -s /webodm/app/media/project/{pid}'.format(pid=pid)]

    resp = stream(v1.connect_get_namespaced_pod_exec, 'webapp-worker', 'default',
                  container='webapp',
                  command=exec_command,
                  stderr=True, stdin=False,
                  stdout=True, tty=False)

    return resp.strip()



output = query.do_query("select id from auth_user order by id;").split('\n')

#print(len(output), output)
totalonly = False #True
for u in output:
    if not len(u): continue
    userid = int(u)
    print("================================================================================")
    name_email = query.do_query("select username,email from auth_user where id={0};".format(userid))
    print("USER: ", userid, name_email)
    projects = query.do_query("select id from app_project where owner_id={0};".format(userid))
    if not totalonly:
        print(" PROJECTS...")
        print("----------")
    total = 0
    for p in projects.split('\n'):
        if not len(p): continue
        pid = int(p)
        pname = query.do_query("select name from app_project where id={0};".format(pid))
        if not totalonly: print(" NAME: ", pname)
        res = get_disk_usage(pid)
        for r in res.split('\n'):
            if not len(r): continue;
            if not totalonly: print("   ", r)
            try:
                total += float(r.split()[0])
            except:
                pass
    if not totalonly:
        print("TOTAL: ", total / 1024 / 1024, "GB, ", total)
    else:
        print(total / 1024 / 1024, " GB of storage used")


