#!/bin/bash
# this installs kube-prometheus-stack
# https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

set -e

source ./config.sh

echo
echo "==== $0:  Require KUBECONFIG"
[[ -z "${KUBECONFIG}" ]] && echo "KUBECONFIG not defined. Exit." && exit 1
echo "export KUBECONFIG=${KUBECONFIG}"

#
# remove exiting prometheus installation
./unprom.sh

echo
echo "==== $0: install prometheus-community stack (this may show warnings related to beta APIs)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
cat prom-values.yaml.template ${AMVALUES} | envsubst "${ENVSUBSTVAR}" | helm install --values - prom prometheus-community/kube-prometheus-stack -n monitoring

echo
echo "==== $0: installing custom dashboard"
cat dashboard.json.template | envsubst "${ENVSUBSTVAR}" > /tmp/dashboard.json
kubectl create configmap ${APP}-dashboard-configmap -n monitoring --from-file="/tmp/dashboard.json"
kubectl patch configmap ${APP}-dashboard-configmap -n monitoring -p '{"metadata":{"labels":{"grafana_dashboard":"1"}}}'
rm /tmp/dashboard.json

echo
echo "==== $0: installing ingress-nginx dashboards"
wget https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/grafana/dashboards/nginx.json
kubectl create configmap ingress-nginx -n monitoring --from-file="nginx.json"
kubectl patch configmap ingress-nginx -n monitoring -p '{"metadata":{"labels":{"grafana_dashboard":"1"}}}'
rm nginx.json
wget https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/grafana/dashboards/request-handling-performance.json
kubectl create configmap ingress-nginx-perf -n monitoring --from-file="request-handling-performance.json"
kubectl patch configmap ingress-nginx-perf -n monitoring -p '{"metadata":{"labels":{"grafana_dashboard":"1"}}}'
rm request-handling-performance.json

echo 
echo "==== $0: Remove dashboards that may not work in K3D"
kubectl delete configmap -n monitoring prom-kube-prometheus-stack-proxy || true
kubectl delete configmap -n monitoring prom-kube-prometheus-stack-persistentvolumesusage || true

echo 
echo "==== $0: Patch existing dashboards to use browser timezone"
MAPS=$(kubectl get configmaps -l grafana_dashboard=1 -n monitoring | tail -n +2 | awk '{print $1}')
for m in ${MAPS}
do
  echo -n "Processing map ${m}: "
  kubectl get configmap ${m} -n monitoring -o yaml | sed 's/"timezone": ".*"/"timezone": "browser"/g' | kubectl apply -f - -n monitoring
done

echo
echo "==== $0: Wait for everything to roll out"
kubectl rollout status deployment.apps prom-grafana -n monitoring --request-timeout 5m
kubectl rollout status deployment.apps prom-kube-state-metrics -n monitoring --request-timeout 5m
kubectl rollout status deployment.apps prom-kube-prometheus-stack-operator -n monitoring --request-timeout 5m
kubectl rollout status statefulset.apps/alertmanager-prom-kube-prometheus-stack-alertmanager -n monitoring --request-timeout 5m

echo
echo "==== $0: wait for prom-grafana ingress to be available"
while [ "$(kubectl get ing prom-grafana -n monitoring -o json | npx jq -r .status.loadBalancer.ingress[0].ip)" = "null" ]
do
  i=$[$i+1]
  [ "$i" -gt "60" ] && echo "this took too long... exit." && exit 1
  echo -n "."
  sleep 2
done
sleep 1
echo "done"

#
# running a simple test
./test.sh
./slack.sh "Cluster ${CLUSTER}: kube-prometheus-stack installed using ${AMVALUES} values file."

echo 
echo "==== $0: Various information"
echo "export KUBECONFIG=${KUBECONFIG}"
echo "Lens: monitoring/prom-kube-prometheus-stack-prometheus:9090/prom"
echo "prometheus: http://localhost:${HTTPPORT}/prom/targets"
echo "alertmanager: http://localhost:${HTTPPORT}/alert"
echo "grafana: http://localhost:${HTTPPORT}  (use admin/${GRAFANA_PASS} to login)"
[ -x ${AMTOOL} ] && sleep 4 && ${AMTOOL} config routes
