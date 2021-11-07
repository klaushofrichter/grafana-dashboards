#!/bin/bash
set -e

source ./config.sh

#
# remove existing cluster
if [[ ! -z $(k3d cluster list | grep "^${CLUSTER}") ]]; then
  echo
  echo "==== $0: remove existing cluster"
  read -p "K3D cluster \"${CLUSTER}\" exists. Ok to delete it and restart? (y/n) " -n 1 -r
  echo
  if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "bailing out..."
    exit 1
  fi
  k3d cluster delete ${CLUSTER}
fi  

echo
echo "==== $0: Install app packages"
npm install
export APP=`cat package.json | grep '^  \"name\":' | cut -d ' ' -f 4 | tr -d '",'`         # extract app name from package.json
export VERSION=`cat package.json | grep '^  \"version\":' | cut -d ' ' -f 4 | tr -d '",'`  # extract version from package.json

echo "==== $0: Create new cluster ${CLUSTER} for app ${APP}:${VERSION}"
./slack.sh "Cluster ${CLUSTER} setup in progress...."
cat k3d-config.yaml.template | envsubst "${ENVSUBSTVAR}" > /tmp/k3d-config.yaml
k3d cluster create --config /tmp/k3d-config.yaml
export KUBECONFIG=$(k3d kubeconfig write mycluster)
echo "export KUBECONFIG=${KUBECONFIG}"
rm /tmp/k3d-config.yaml

echo
echo "==== $0: Running helm for ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
kubectl create namespace ingress-nginx
helm install -f ingress-nginx-values.yaml ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx

echo
echo "==== $0: Waiting for ingress-nginx-controller deployment to be ready"
kubectl rollout status deployment.apps ingress-nginx-controller -n ingress-nginx --request-timeout 5m
kubectl rollout status daemonset.apps svclb-ingress-nginx-controller -n ingress-nginx --request-timeout 5m
x="0"
echo -n "Waiting for ingress-nginx-controller to get an IP address.."
while [ true ]; do
  LBIP=$(kubectl get svc ingress-nginx-controller --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}" -n ingress-nginx)
  [ ! -z "${LBIP}" ] && break
  echo -n "."
  x=$(( ${x} + 2 ))
  [ $x -gt "100" ] && echo "ingress-nginx-controller not ready after ${x} seconds. Exit" && exit 1
  sleep 2
done
echo

echo
echo "==== $0: Show info about the cluster ${CLUSTER}"
kubectl cluster-info
echo
kubectl get all -A

echo "==== $0: Showing ingress-nginx-controller info in the namespace \"ingress-nginx\""
NGINXCONTROLLERPOD=$(kubectl get pods -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}' -n ingress-nginx)
kubectl exec -it ${NGINXCONTROLLERPOD} -n ingress-nginx -- /nginx-ingress-controller --version

echo
echo "==== $0: Build app image ${APP}:${VERSION}"
chmod a+rx node_modules/node-jq/bin/jq  # odd
docker build -t ${APP}:${VERSION} .

echo
echo "==== $0: Import new image ${APP}:${VERSION} to k3d ${CLUSTER} (this may take a while)"
k3d image import ${APP}:${VERSION} -c ${CLUSTER} --keep-tools 

echo
echo "==== $0: Deploy application (namespace, pods, service, ingress)"
cat app.yaml.template | envsubst "${ENVSUBSTVAR}" | kubectl create -f - --save-config

echo
echo "==== $0: Wait for ${app} deployment to finish"
kubectl rollout status deployment.apps ${APP}-deploy -n ${APP} --request-timeout 5m

echo
echo "==== $0: Show Ingresses:"
kubectl get ing -A

echo
echo "==== $0: Install prometheus-community stack (this may show warnings related to beta APIs)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
./prom.sh

echo "==== $0: Various information"
echo "export KUBECONFIG=${KUBECONFIG}"
echo "${APP} info API: http://localhost:${HTTPPORT}/service/info"
echo "${APP} random API: http://localhost:${HTTPPORT}/service/random"
echo "${APP} metrics API: http://localhost:${HTTPPORT}/service/metrics"
echo "Lens: monitoring/prom-kube-prometheus-stack-prometheus:9090/prom"
./slack.sh "Cluster ${CLUSTER} running."
