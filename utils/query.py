#pip install kubernetes
#https://github.com/kubernetes-client/python
from kubernetes import client, config

# Configs can be set in Configuration class directly or using helper utility
import os
config.load_kube_config(os.environ['KUBECONFIG'])

v1 = client.CoreV1Api()
#print("Listing pods with their IPs:")
ret = v1.list_pod_for_all_namespaces(watch=False)
dbpod = None
for i in ret.items:
    #print("%s\t%s\t%s" % (i.status.pod_ip, i.metadata.namespace, i.metadata.name))
    if i.metadata.namespace == 'default' and i.metadata.name[0:2] == 'db':
        print("%s\t%s\t%s" % (i.status.pod_ip, i.metadata.namespace, i.metadata.name))
        dbpod = i.metadata.name
        break

#https://github.com/kubernetes-client/python/blob/master/examples/pod_exec.py
from kubernetes.stream import stream
def do_query(query):
    exec_command = [
        'bash',
        '-c',
        'export PATH=$PATH:/usr/local/pgsql/bin; psql -x -P pager=off -d webodm_dev -t -c \"{query}\"'.format(query=query)]

    print(exec_command)
    resp = stream(v1.connect_get_namespaced_pod_exec, dbpod, 'default',
                  command=exec_command,
                  stderr=True, stdin=False,
                  stdout=True, tty=False,
                  _preload_content=False) #With preload_content will return string of all output

    #print("Response: " + resp)
    output = ""
    while resp.is_open():
        output += resp.read_stdout()
    resp.close()
    return output.strip()


#tables = do_query("\dt")
#print(tables)


