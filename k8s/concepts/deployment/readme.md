get all cluster resources: - kubectl get all

update container image on deployment:

- kubectl edit deploy/[deploymentname]
  or
- kubectl set image deploy/[deploymentname] \ nginx=nginx:1.9.1

scale replicas:

- kubectl scale --replicas=3 deployment/nginx-deploy

check deployment history:

- kubectl rollout history deploy/nginx-deploy

revert last changes:

- kubectl rollout undo deploy/nginx-deploy
- kubectl rollout undo deploy/nginx-deploy --to-revision <revision_number>

create deployment using imperative command:

- kubectl create deploy nginx --image=nginx:latest
  kubectl run -i --tty load-generator --rm \ --image=busybox:1.28 --restart=Never -- /bin/sh -c \ "while sleep 0.01;
  do wget -q -O- \ http://php-apache; done"
