#!/bin/bash
source settings.env
kubectl get nodes
#kubectl get pods
#Show pods with nodes
kubectl get pod -o=custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName #--all-namespaces

kubectl get svc

SCRIPT="top -n1 | head -n 12  | tail -n 5"
SCRIPT="${SCRIPT}; free"
SCRIPT="${SCRIPT}; cd data; ls -d */"
SCRIPT="${SCRIPT}; ps aux | grep Z | wc"
SCRIPT="${SCRIPT}; cat tasks.json; echo ''"

#for (( n=0; n<=$NODE_ODM+$NODE_MICMAC; n++ ))
for (( n=0; n<$NODES_P4; n++ ))
do
  echo "--- P4 Node $n --------------------------------------------------------------- ";
  kubectl exec --stdin --tty nodeodm-p4-$n -- /bin/bash -c "${SCRIPT}";
done

for (( n=0; n<$NODES_A40; n++ ))
do
  echo "--- A40 Node $n --------------------------------------------------------------- ";
  kubectl exec --stdin --tty nodeodm-a40-$n -- /bin/bash -c "${SCRIPT}";
done

for (( n=0; n<$NODES_A100; n++ ))
do
  echo "--- A100 Node $n --------------------------------------------------------------- ";
  kubectl exec --stdin --tty nodeodm-a100-$n -- /bin/bash -c "${SCRIPT}";
done
