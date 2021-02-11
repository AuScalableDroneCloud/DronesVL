#!/bin/bash
source settings.env
kubectl get nodes
#kubectl get pods
#Show pods with nodes
kubectl get pod -o=custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName #--all-namespaces

kubectl get svc
#for i in 1 2 3 4;
#do
#  echo "--- Node $i ------ ";
#  kubectl exec node$i -- /bin/bash -c "top -n1 | head -n 12  | tail -n 5";
#done
#for (( n=0; n<=$NODE_ODM+$NODE_MICMAC; n++ ))
for (( n=1; n<=$NODE_ODM; n++ ))
do
  echo "--- Node $n ------ ";
  kubectl exec --stdin --tty nodeodm$n -- /bin/bash -c "top -n1 | head -n 12  | tail -n 5"; #First 6 lines are header
  #kubectl exec --stdin --tty node$n -- /bin/bash -c "cat data/tasks.json";
  kubectl exec --stdin --tty nodeodm$n -- /bin/bash -c "cd data; ls -d */";
  kubectl exec --stdin --tty nodeodm$n -- /bin/bash -c "ps aux | grep Z | wc";
done

