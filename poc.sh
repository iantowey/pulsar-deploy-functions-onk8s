tmux

ds pull apachepulsar/pulsar:4.0.10
ds pull apachepulsar/pulsar-all:4.0.10

## init system and teardown env
sudo rm -rf conf-pulsar/ data/ conf-sb1/ pulsar-ca/

IMAGE="apachepulsar/pulsar-all:4.0.10"
CONF_DIR="pulsar-conf"
# This needs to be routable from the pod. eg real interface IP (not loopback)
IP_ADDR="$(hostname -I | awk '{print $1}')"
ZK1="${IP_ADDR}"
BK1="${IP_ADDR}"
BRK1="${IP_ADDR}"
FWRK="${IP_ADDR}"
PRXY="${IP_ADDR}"
CLUSTER="pulsar-local"

minikube stop --profile=k8s-pulsar-functions
minikube delete --profile=k8s-pulsar-functions
docker network disconnect pulsar_network pulsar
ds stop ZK1 BK1 BRK1 FWRK PRXY nginx pulsar-dns socat-proxy
ds network rm pulsar_network

minikube start --cni calico --profile=k8s-pulsar-functions --apiserver-names=k8s-pulsar-functions,*.k8s-pulsar-functions --kubernetes-version=v1.34.0 --memory=8000 --cpus=2 --nodes=1
minikube profile k8s-pulsar-functions

#init local pulsar conf dir
sudo rm -rf data ${CONF_DIR}
ds run --rm --user=0:0 --volume=${PWD}:/host $IMAGE cp -r "/pulsar/conf" /host/${CONF_DIR}

# Zookeeper
echo "server.1=${ZK1}:2888:3888" | sudo tee -a ${CONF_DIR}/zookeeper.conf
mkdir -p data/zookeeper
echo 1 > data/zookeeper/myid
ds run \
    --rm \
    --detach \
    --user=0:0 \
    --name=ZK1 \
    --network=k8s-pulsar-functions \
    --volume=${PWD}/${CONF_DIR}:/pulsar/conf \
    --volume=${PWD}/data:/pulsar/data \
    ${IMAGE} \
    bin/pulsar zookeeper
sleep 1

ds exec \
    --interactive \
    --tty \
    ZK1 \
    bin/pulsar initialize-cluster-metadata \
        --cluster ${CLUSTER} \
        --zookeeper ZK1:2181 \
        --configuration-store ZK1:2181 \
        --web-service-url http://BRK1:8080 \
        --web-service-url-tls https://BRK1:8443 \
        --broker-service-url pulsar://BRK1:6650 \
        --broker-service-url-tls pulsar+ssl://BRK1:6651

sudo sed -i -e "s/^zkServers=.*/zkServers=ZK1:2181/" ${CONF_DIR}/bookkeeper.conf
sudo sed -i -e "s/^allowLoopback=.*/allowLoopback=true/" ${CONF_DIR}/bookkeeper.conf
sudo sed -i -e "s/^prometheusStatsHttpPort=.*/prometheusStatsHttpPort=8001/" ${CONF_DIR}/bookkeeper.conf
ds run \
    --rm \
    --detach \
    --user=0:0 \
    --name=BK1 \
    --network=k8s-pulsar-functions \
    --volume=${PWD}/${CONF_DIR}:/pulsar/conf \
    --volume=${PWD}/data:/pulsar/data \
    ${IMAGE} \
    bin/bookkeeper bookie

echo "superUserRoles=superuser,admin,proxy" | sudo tee -a ${CONF_DIR}/broker.conf

sudo sed -i -e "s/^zookeeperServers=.*/zookeeperServers=ZK1:2181/" ${CONF_DIR}/broker.conf
sudo sed -i -e "s/^configurationStoreServers=.*/configurationStoreServers=ZK1:2181/" ${CONF_DIR}/broker.conf
sudo sed -i -e "s/^clusterName=.*/clusterName=${CLUSTER}/" ${CONF_DIR}/broker.conf
sudo sed -i -e "s/^managedLedgerDefaultEnsembleSize=.*/managedLedgerDefaultEnsembleSize=1/" ${CONF_DIR}/broker.conf
sudo sed -i -e "s/^managedLedgerDefaultWriteQuorum=.*/managedLedgerDefaultWriteQuorum=1/" ${CONF_DIR}/broker.conf
sudo sed -i -e "s/^managedLedgerDefaultAckQuorum=.*/managedLedgerDefaultAckQuorum=1/" ${CONF_DIR}/broker.conf
sudo sed -i -e "s/^functionsWorkerEnabled=.*/functionsWorkerEnabled=false/" ${CONF_DIR}/broker.conf
sudo sed -i -e "s/^proxyRoles=.*/proxyRoles=proxy/" ${CONF_DIR}/broker.conf


ds run \
    --rm \
    --detach \
    --user=0:0 \
    --name=BRK1 \
    --network=k8s-pulsar-functions \
    --volume=${PWD}/${CONF_DIR}:/pulsar/conf \
    --volume=${PWD}/data:/pulsar/data \
    ${IMAGE} \
    bin/pulsar broker


#instll contour whioch provides an implementation of k8s gateway API
kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.1.0"
kubectl get crd | grep gateway
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.1.0/config/crd/experimental/gateway.networking.k8s.io_tcproutes.yaml
kubectl apply -f https://projectcontour.io/quickstart/contour.yaml
kubectl get pods -n projectcontour
kubectl apply -f https://projectcontour.io/quickstart/contour-gateway-provisioner.yaml
cat << 'EOF' | kubectl apply -f -
kind: GatewayClass
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: contour
spec:
  controllerName: projectcontour.io/gateway-controller
EOF

k create ns pulsar-functions-ns
cat << 'EOF' | kubectl apply -f -
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: pulsar-functions-gateway
  namespace: pulsar-functions-ns
spec:
  gatewayClassName: contour
  listeners:
    - name: grpc-functions
      protocol: HTTP
      port: 80
EOF

# get thje nodeport for the envoy gateway - used by the functions worker and functions for grpc port
k get svc envoy-pulsar-functions-gateway -n pulsar-functions-ns -o yaml | yq '.spec.ports[] | select(.protocol == "TCP") | .nodePort'
GATEWAY_NODE_PORT_FW=$(k get svc envoy-pulsar-functions-gateway -n pulsar-functions-ns -o yaml | yq '.spec.ports[] | select(.protocol == "TCP") | .nodePort')

#setup dns
cat > dnsmasq.conf <<'EOF'
address=/pulsar-functions.midgard.acme.com/192.168.49.2
EOF

docker run \
    --rm \
    --detach \
    --name=pulsar-dns \
    --network=k8s-pulsar-functions \
    --ip=192.168.49.10 \
    --cap-add=NET_ADMIN \
    --volume=/tmp/dnsmasq.conf:/etc/dnsmasq.conf \
    andyshinn/dnsmasq:2.78


sudo mkdir ${CONF_DIR}/k8s/


cat <<EOF | sudo tee ${CONF_DIR}/k8s/config
apiVersion: v1
clusters:
- cluster:
    certificate-authority: /pulsar/conf/k8s/ca.crt
    extensions:
    - extension:
        provider: minikube.sigs.k8s.io
        version: v1.30.1
      name: cluster_info
    server: https://k8s-pulsar-functions:8443
  name: k8s-pulsar-functions
contexts:
- context:
    cluster: k8s-pulsar-functions
    extensions:
    - extension:
        provider: minikube.sigs.k8s.io
        version: v1.30.1
      name: context_info
    namespace: default
    user: k8s-pulsar-functions
  name: k8s-pulsar-functions
current-context: k8s-pulsar-functions
kind: Config
preferences: {}
users:
- name: k8s-pulsar-functions
  user:
    client-certificate: /pulsar/conf/k8s/client.crt
    client-key: /pulsar/conf/k8s/client.key
EOF

sudo cp  /home/itowey/.minikube/ca.crt ${CONF_DIR}/k8s/
sudo cp  /home/itowey/.minikube/profiles/k8s-pulsar-functions/client.crt ${CONF_DIR}/k8s/
sudo cp  /home/itowey/.minikube/profiles/k8s-pulsar-functions/client.key ${CONF_DIR}/k8s/

sudo openssl x509 -in ${CONF_DIR}/k8s/ca.crt -text -noout


#sudo cp functions_worker.yml ${CONF_DIR}
sudo sed -i -e "s/^workerId.*/workerId: FWRK/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^workerHostname.*/workerHostname: FWRK/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^configurationStoreServers.*/configurationStoreServers: ZK1:2181/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^pulsarFunctionsCluster.*/pulsarFunctionsCluster: ${CLUSTER}/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^pulsarServiceUrl.*/pulsarServiceUrl: pulsar:\/\/BRK1:6650/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^pulsarWebServiceUrl.*/pulsarWebServiceUrl: http:\/\/BRK1:8080/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^configurationMetadataStoreUrl.*/configurationMetadataStoreUrl: zk:ZK1:2181/" ${CONF_DIR}/functions_worker.yml


#sudo sed -i -e "s/^functionRuntimeFactoryClassName.*//" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e '/^functionRuntimeFactoryClassName:.*/,/extraFunctionDependenciesDir:/ s/^/# /' ${CONF_DIR}/functions_worker.yml

sudo sed -i -e "s/^#functionRuntimeFactoryClassName.*KubernetesRuntimeFactory/functionRuntimeFactoryClassName: org.apache.pulsar.functions.runtime.kubernetes.KubernetesRuntimeFactory/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^#functionRuntimeFactoryConfigs:.*/functionRuntimeFactoryConfigs:/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/#    k8Uri:.*/    k8Uri: null/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/#    jobNamespace:.*/    jobNamespace: \"pulsar-functions-ns\"/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/#    pulsarDockerImageName:/    pulsarDockerImageName: \"apachepulsar\/pulsar:4.0.10\"/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/#    pulsarAdminUrl:/    pulsarAdminUrl: http:\/\/FWRK:6750\//" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/#    pulsarServiceUrl:/    pulsarServiceUrl: pulsar:\/\/BRK1:6650\//" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/#    grpcPort: 9093/    grpcPort: ${GATEWAY_NODE_PORT_FW}/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/#    metricsPort: 9094/    metricsPort: 9094/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/#    submittingInsidePod: false/    submittingInsidePod: false/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^tlsTrustStore:.*/tlsTrustStore: \/pulsar\/conf\/auth\/functionWorkerTrustStore.jks/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^tlsTrustStorePassword:/tlsTrustStorePassword: changeit/" ${CONF_DIR}/functions_worker.yml
sudo sed -i -e "s/^tlsAllowInsecureConnection.*/tlsAllowInsecureConnection: true/" ${CONF_DIR}/functions_worker.yml
echo "additionalEnabledFunctionsUrlPatterns:" | sudo tee -a ${CONF_DIR}/functions_worker.yml
echo "  - \"http://nginx/.*\"" | sudo tee -a ${CONF_DIR}/functions_worker.yml

# add to functionRuntimeFactoryConfigs
kubernetesServiceDomainSuffix: "pulsar-functions.midgard.acme.com"

ds run \
    --rm \
    --detach \
    --user=0:0 \
    --name=FWRK \
    --network=k8s-pulsar-functions \
    --dns=192.168.49.10 \
    --dns=8.8.8.8 \
    --env "KUBECONFIG=/pulsar/conf/k8s/config" \
    --env "JAVA_TOOL_OPTIONS=-Djdk.internal.httpclient.disableHostnameVerification=true" \
    --volume=${PWD}/${CONF_DIR}:/pulsar/conf \
    --volume=${PWD}/data:/pulsar/data \
    --volume=/home/itowey/.m2/repository/org/apache/pulsar/pulsar-functions-runtime/4.0.10/pulsar-functions-runtime-4.0.10.jar:/pulsar/lib/org.apache.pulsar-pulsar-functions-runtime-4.0.10.jar \
    ${IMAGE} \
    bin/pulsar functions-worker


echo "brokerProxyAllowedTargetPorts=6650,6651" | sudo tee -a ${CONF_DIR}/proxy.conf
echo "authenticateMetricsEndpoint=false" | sudo tee -a ${CONF_DIR}/proxy.conf

sudo sed -i -e "s/^authenticationProviders=/authenticationProviders=org.apache.pulsar.broker.authentication.AuthenticationProviderToken/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^brokerServiceURL=/brokerServiceURL=pulsar:\/\/BRK1:6650/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^brokerServiceURLTLS=/brokerServiceURLTLS=pulsar+ssl:\/\/BRK1:6651/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^brokerWebServiceURL=/brokerWebServiceURL=http:\/\/BRK1:8080/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^brokerWebServiceURLTLS=/brokerWebServiceURLTLS=https:\/\/BRK1:8443/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^configurationStoreServers.*/configurationStoreServers=ZK1:2181/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^functionWorkerWebServiceURL=/functionWorkerWebServiceURL=http:\/\/FWRK:6750/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^functionWorkerWebServiceURLTLS=/functionWorkerWebServiceURLTLS=https:\/\/FWRK:6751/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^zookeeperServers=.*/zookeeperServers=ZK1:2181/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^clusterName=.*/clusterName=${CLUSTER}/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^webServicePort=.*/webServicePort=18080/" ${CONF_DIR}/proxy.conf
#sudo sed -i -e "s/^webServicePortTls=.*/webServicePortTls=18443/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^servicePort=.*/servicePort=16650/" ${CONF_DIR}/proxy.conf
#sudo sed -i -e "s/^servicePortTls=.*/servicePortTls=16651/" ${CONF_DIR}/proxy.conf
sudo sed -i -e "s/^superUserRoles=.*/superUserRoles=superuser,admin,proxy/" ${CONF_DIR}/proxy.conf


ds run \
    --rm \
    --detach \
    --user=0:0 \
    --name=PRXY \
    -p 18080:18080 \
    -p 16650:16650 \
    --network=k8s-pulsar-functions \
    --volume=${PWD}/${CONF_DIR}:/pulsar/conf \
    --volume=${PWD}/data:/pulsar/data \
    ${IMAGE} \
    bin/pulsar proxy



docker run \
    --rm \
    --detach \
    --name=nginx \
    --network=k8s-pulsar-functions \
    nginx:1.19.4

ds cp /home/itowey/acme/projects/DEDEV/jvm-func-pantry/functions/pass-through-function/target/pass-through-function-1.9.174-SNAPSHOT-java17-jar-with-dependencies.jar nginx:/usr/share/nginx/html
ds cp /home/itowey/acme/projects/DEDEV/jvm-func-pantry/functions/pass-through-function/target/pass-through-function-1.9.174-SNAPSHOT-java17-jar-with-dependencies.jar nginx:/usr/share/nginx/html/pass-through-function.jar

ds exec nginx ls -al /usr/share/nginx/html/



## iunstall kyverno
#https://github.com/kyverno/kyverno
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno-gateway-api-access
  labels:
    # These labels automatically merge these permissions into Kyverno's service accounts
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
rules:
- apiGroups:
  - gateway.networking.k8s.io
  resources:
  - grpcroutes
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
EOF


k apply -n pulsar-functions-ns -f /tmp/patch-function-svc-for-metrics.yaml

cat > /tmp/pulsar-kyverno-policy.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: auto-generate-pulsar-grpc-route
spec:
  rules:
  - name: generate-pulsar-grpc-route
    match:
      any:
      - resources:
          kinds:
          - Service
          namespaces:
          - pulsar-functions-ns
    # Only trigger for Pulsar function services (they start with pf-)
    preconditions:
      all:
      - key: "{{ request.object.metadata.name }}"
        operator: Equals
        value: "pf-*"
    generate:
      apiVersion: gateway.networking.k8s.io/v1
      kind: GRPCRoute
      name: "{{ request.object.metadata.name }}-route"
      namespace: pulsar-functions-ns
      synchronize: true # If the Pulsar service is deleted, Kyverno automatically deletes this Route!
      data:
        spec:
          parentRefs:
          - name: pulsar-functions-gateway
          hostnames:
          # Automatically injects the service name into the wildcard domain
          - "*.{{ request.object.metadata.name }}.pulsar-functions-ns.pulsar-functions.midgard.acme.com"
          rules:
          - backendRefs:
            - name: "{{ request.object.metadata.name }}"
              # Automatically grabs the port from the service definition
              port: "{{ request.object.spec.ports[0].port }}"
EOF

kubectl apply -f /tmp/pulsar-kyverno-policy.yaml



/home/itowey/acme/sandbox/apache_apps/apache-pulsar-2.8.3/bin/pulsar-admin functions create  \
    --tenant public  \
	--namespace default  \
	--name pass-through1 \
	--inputs persistent://public/default/pass-through1-in  \
	--output persistent://public/default/pass-through1-out  \
	--parallelism 1  \
	--jar http://nginx/pass-through-function.jar  \
	--className com.acme.dataeng.FuncPantry.PassThroughFunction

/home/itowey/acme/sandbox/apache_apps/apache-pulsar-2.8.3/bin/pulsar-admin functions delete --fqfn public/default/pass-through1


/home/itowey/acme/sandbox/apache_apps/apache-pulsar-2.8.3/bin/pulsar-client consume -n 0 -s sub persistent://public/default/pass-through1-out

/home/itowey/acme/sandbox/apache_apps/apache-pulsar-2.8.3/bin/pulsar-client produce persistent://public/default/pass-through1-in -m '{"id":1,"name":"ian"}' -s ';'

/home/itowey/acme/sandbox/apache_apps/apache-pulsar-2.8.3/bin/pulsar-admin functions status --fqfn public/default/pass-through1 | jq .

ds network inspect k8s-pulsar-functions | jq -c '.[].Containers[] | {host:.Name,ip:.IPv4Address}'
{"host":"pulsar-dns","ip":"192.168.49.10/24"}
{"host":"PRXY","ip":"192.168.49.7/24"}
{"host":"k8s-pulsar-functions","ip":"192.168.49.2/24"}
{"host":"nginx","ip":"192.168.49.8/24"}
{"host":"FWRK","ip":"192.168.49.6/24"}
{"host":"BK1","ip":"192.168.49.4/24"}
{"host":"BRK1","ip":"192.168.49.5/24"}
{"host":"ZK1","ip":"192.168.49.3/24"}
