#!/bin/bash  
#source settings.env

#VOLUME_ID
#VOLUME_SIZE
#VOLUME_IDX

#Runs envsubst but skips vars not defined in env https://unix.stackexchange.com/a/492778/17168
cat volume_check_template.yaml | envsubst "$(env | cut -d= -f1 | sed -e 's/^/$/')" > volume_check.yaml
kubectl apply -f volume_check.yaml

printf "Waiting for pod to start"
until [ "$(kubectl get pod test-${VOLUME_INDEX} --template={{.status.phase}})" == "Running" ]
do
  printf "."
  sleep 2
done
echo ""
echo "Checking files..."

#kubectl logs test

#kubectl exec -i -t test-${VOLUME_INDEX} -- du -s /mnt/data
#kubectl exec -i -t test-${VOLUME_INDEX} -- ls -lh /mnt/data

echo "Done."
