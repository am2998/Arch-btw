# Kubernetes Setup e Configurazione Ambiente

Raccolta di comandi per configurare un cluster Kubernetes completo con monitoring, sicurezza e gestione.

## Prerequisiti

### Installazione Base
```bash
# Docker
sudo pacman -S docker
sudo systemctl enable --now docker

# Componenti Kubernetes
sudo pacman -S kubeadm kubelet kubectl
sudo systemctl enable --now kubelet

# Helm
sudo pacman -S helm
```

### Configurazione Sistema
```bash
# Network bridge
sudo modprobe br_netfilter

# Parametri sysctl
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

# Disabilita swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

## Container Runtime

### Containerd (Raccomandato)
```bash
sudo pacman -S containerd
sudo systemctl enable --now containerd

# Configurazione
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
```

### CRI-O (Alternativo)
```bash
sudo pacman -S cri-o crun
sudo systemctl enable --now crio
```

## Inizializzazione Cluster

### Setup Base
```bash
# Con Containerd
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket unix:///var/run/containerd/containerd.sock

# Con CRI-O
sudo kubeadm init --cri-socket unix:///var/run/crio/crio.sock --pod-network-cidr=10.244.0.0/16

# Configurazione kubeconfig
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Plugin di Rete

#### Flannel (Semplice)
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

#### Cilium (Avanzato)
```bash
# Installazione CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# Installazione Cilium
cilium install
```

## Sicurezza Avanzata

### Audit Logging API Server
```bash
# Crea directory per audit logs
sudo mkdir -p /var/log/kubernetes/audit
sudo chmod 755 /var/log/kubernetes/audit

# Copia policy di audit (da security/audit-policy.yaml)
sudo cp security/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
sudo chmod 644 /etc/kubernetes/audit-policy.yaml

# Backup configurazione API server
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.backup

# Aggiungi parametri audit alla configurazione API server
sudo sed -i '/- kube-apiserver/a\    - --audit-log-path=/var/log/kubernetes/audit/audit.log' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i '/- kube-apiserver/a\    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i '/- kube-apiserver/a\    - --audit-log-maxage=30' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i '/- kube-apiserver/a\    - --audit-log-maxbackup=10' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i '/- kube-apiserver/a\    - --audit-log-maxsize=100' /etc/kubernetes/manifests/kube-apiserver.yaml

# Aggiungi volume mounts per audit
sudo sed -i '/volumeMounts:/a\    - mountPath: /var/log/kubernetes/audit\n      name: audit-log\n      readOnly: false' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i '/volumeMounts:/a\    - mountPath: /etc/kubernetes/audit-policy.yaml\n      name: audit-policy\n      readOnly: true' /etc/kubernetes/manifests/kube-apiserver.yaml

# Aggiungi volumes
sudo sed -i '/volumes:/a\  - hostPath:\n      path: /var/log/kubernetes/audit\n      type: DirectoryOrCreate\n    name: audit-log' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i '/volumes:/a\  - hostPath:\n      path: /etc/kubernetes/audit-policy.yaml\n      type: File\n    name: audit-policy' /etc/kubernetes/manifests/kube-apiserver.yaml

# API server si riavvierà automaticamente
# Verifica i log con: sudo tail -f /var/log/kubernetes/audit/audit.log
```

### Cifratura etcd
```bash
# Crea directory per configurazione cifratura
sudo mkdir -p /etc/kubernetes/encryption

# Genera chiave di cifratura
ENCRYPTION_KEY=$(sudo head -c 32 /dev/urandom | base64)
echo "$ENCRYPTION_KEY" | sudo tee /etc/kubernetes/encryption/encryption-key > /dev/null

# Crea configurazione di cifratura dal template
# (da security/encryption-config-template.yaml)
sed "s/ENCRYPTION_KEY_PLACEHOLDER/$ENCRYPTION_KEY/" security/encryption-config-template.yaml | \
sudo tee /etc/kubernetes/encryption/encryption-config.yaml > /dev/null

# Proteggi i file di cifratura
sudo chmod 600 /etc/kubernetes/encryption/encryption-config.yaml
sudo chmod 600 /etc/kubernetes/encryption/encryption-key

# Backup configurazione API server
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.pre-encryption

# Aggiungi parametro di cifratura
sudo sed -i '/- kube-apiserver/a\    - --encryption-provider-config=/etc/kubernetes/encryption/encryption-config.yaml' /etc/kubernetes/manifests/kube-apiserver.yaml

# Aggiungi volume mount per encryption config
sudo sed -i '/volumeMounts:/a\    - mountPath: /etc/kubernetes/encryption\n      name: encryption-config\n      readOnly: true' /etc/kubernetes/manifests/kube-apiserver.yaml

# Aggiungi volume
sudo sed -i '/volumes:/a\  - hostPath:\n      path: /etc/kubernetes/encryption\n      type: DirectoryOrCreate\n    name: encryption-config' /etc/kubernetes/manifests/kube-apiserver.yaml

# API server si riavvierà automaticamente
# Attendi che API server sia disponibile
until kubectl get nodes &> /dev/null; do
  echo "Attendo che API server sia disponibile..."
  sleep 5
done

# Re-cifratura dati esistenti
echo "Re-cifratura dati esistenti..."

# Cifra tutti i secret esistenti
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
echo "Tutti i secret sono stati ri-cifrati"

# Cifra tutti i configmap esistenti
kubectl get configmaps --all-namespaces -o json | kubectl replace -f -
echo "Tutti i configmap sono stati ri-cifrati"

echo "Cifratura etcd configurata con successo!"
```

### Verifica Configurazioni Sicurezza
```bash
# Verifica audit logs
sudo ls -la /var/log/kubernetes/audit/
sudo tail -f /var/log/kubernetes/audit/audit.log

# Verifica che la cifratura sia attiva
kubectl get secrets -o yaml | grep -q "apiVersion: v1" && echo "Cifratura attiva"

# Test cifratura: crea un secret e verifica che sia cifrato in etcd
kubectl create secret generic test-encryption --from-literal=key=value
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/test-encryption | hexdump -C

# Cleanup test
kubectl delete secret test-encryption
```

## Monitoring Stack

### Prometheus e Grafana
```bash
# Aggiungi repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Crea namespace
kubectl create namespace monitoring

# Installa stack completo
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
    --set prometheus.prometheusSpec.retention=15d \
    --set grafana.persistence.enabled=true \
    --set grafana.persistence.size=5Gi \
    --set grafana.adminPassword=admin123 \
    --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=5Gi \
    --set nodeExporter.enabled=false \
    --timeout=15m
```

### Accesso Grafana NodePort
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: grafana-external
  namespace: monitoring
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 3000
    nodePort: 30300
  selector:
    app.kubernetes.io/name: grafana
EOF
```

### New Relic (Opzionale)
```bash
# Imposta license key
export NEW_RELIC_LICENSE_KEY=your_license_key

# Aggiungi repository
helm repo add newrelic https://helm-charts.newrelic.com
helm repo update

# Crea namespace
kubectl create namespace newrelic

# Installa bundle
helm upgrade --install newrelic-bundle newrelic/nri-bundle \
    --namespace newrelic \
    --set global.licenseKey="$NEW_RELIC_LICENSE_KEY" \
    --set global.cluster="$(kubectl config current-context)" \
    --set newrelic-infrastructure.privileged=true \
    --set global.lowDataMode=true \
    --set kube-state-metrics.enabled=true \
    --set kubeEvents.enabled=true \
    --set newrelic-prometheus-agent.enabled=true \
    --set newrelic-prometheus-agent.lowDataMode=true \
    --set logging.enabled=true \
    --set newrelic-logging.lowDataMode=true \
    --timeout=10m
```

## Sicurezza

### Falco (Runtime Security)
```bash
# Aggiungi repository
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

# Crea namespace
kubectl create namespace falco

# Installa Falco
helm upgrade --install falco falcosecurity/falco \
    --namespace falco \
    --set falco.grpc.enabled=true \
    --set falco.grpcOutput.enabled=true \
    --set falco.httpOutput.enabled=true \
    --set falco.jsonOutput=true \
    --set falco.logLevel=info \
    --set falco.syscallEventDrops.actions="log,alert" \
    --set falco.priority=debug \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=512Mi \
    --set resources.limits.memory=1Gi \
    --timeout=10m
```

### Kyverno (Policy Engine)
```bash
# Aggiungi repository
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

# Crea namespace
kubectl create namespace kyverno

# Installa Kyverno
helm upgrade --install kyverno kyverno/kyverno \
    --namespace kyverno \
    --set replicaCount=1 \
    --set resources.limits.memory=512Mi \
    --set resources.requests.memory=256Mi \
    --timeout=10m

# Applica tutte le policy presenti nella directory security/kyverno-policies/
kubectl apply -f security/kyverno-policies/
```

### Reloader (Auto-restart on ConfigMap/Secret changes)
```bash
# Aggiungi repository
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update

# Crea namespace
kubectl create namespace reloader

# Installa Reloader
helm upgrade --install reloader stakater/reloader \
    --namespace reloader \
    --set reloader.watchGlobally=false \
    --set reloader.ignoreSecrets=false \
    --set reloader.ignoreConfigMaps=false \
    --set reloader.logLevel=info \
    --set resources.limits.memory=128Mi \
    --set resources.requests.memory=64Mi \
    --set resources.requests.cpu=10m \
    --timeout=5m
```

## Gestione Cluster

### Rancher (Container Docker)
```bash
# Ferma container esistente
docker stop rancher 2>/dev/null || true
docker rm rancher 2>/dev/null || true

# Crea directory audit logs
mkdir -p /tmp/rancher-audit-logs

# Avvia Rancher con audit logging
docker run -d --restart=unless-stopped \
    --name rancher \
    -p 80:80 -p 443:443 \
    -v /tmp/rancher-audit-logs:/var/log/audit \
    -e CATTLE_FEATURES="audit-log=true" \
    -e AUDIT_LEVEL=2 \
    -e AUDIT_LOG_PATH=/var/log/audit/audit.log \
    -e AUDIT_LOG_MAXAGE=30 \
    -e AUDIT_LOG_MAXBACKUP=10 \
    -e AUDIT_LOG_MAXSIZE=100 \
    --privileged \
    rancher/rancher:latest
```

## Network Policies

### Applicazione Policy di Rete
```bash
# Applica tutte le network policy
kubectl apply -f network-policies/
```

## Storage

### Configurazione Storage Classes
```bash
# Applica storage classes
kubectl apply -f storage/
```

## Port Forwarding

### Avvio Servizi Monitoring
```bash
# Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 &

# Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80 &

# Alertmanager
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-alertmanager 9093:9093 &

# Falco (se disponibile)
kubectl port-forward -n falco svc/falco 8765:8765 &
```

## Verifica e Diagnostica

### Status Componenti
```bash
# Verifica cluster
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods --all-namespaces

# Verifica monitoring
kubectl get pods -n monitoring
kubectl get pods -n newrelic
kubectl get pods -n falco
kubectl get pods -n kyverno
kubectl get pods -n reloader

# Verifica policy
kubectl get networkpolicy --all-namespaces
kubectl get cpol

# Verifica storage
kubectl get storageclass
```

### Test Policy Kyverno
```bash
# Test container privilegiato (dovrebbe essere bloccato)
kubectl run test-privileged --image=nginx --dry-run=server -o yaml \
    --overrides='{"spec":{"containers":[{"name":"nginx","image":"nginx","securityContext":{"privileged":true}}]}}'

# Test deployment che usa ConfigMap (dovrebbe ricevere automaticamente annotazioni Reloader)
kubectl apply --dry-run=server -o yaml -f testing/test-configmap-user.yaml

# Test deployment con esenzione (non dovrebbe ricevere annotazioni Reloader)
kubectl apply --dry-run=server -o yaml -f testing/test-exempt.yaml

# Verifica policy attive
kubectl get cpol

# Verifica policy reports
kubectl get polr -A

# Cleanup test
kubectl delete pod test-privileged --ignore-not-found=true
kubectl delete deployment test-configmap-user test-exempt --ignore-not-found=true
```

### Test Reloader Functionality
```bash
# Crea un ConfigMap di test
kubectl create configmap test-config --from-literal=key1=value1

# Crea un Deployment che usa il ConfigMap con annotazione Reloader
kubectl apply -f testing/test-reloader-app.yaml

# Verifica che il pod sia in running
kubectl get pods -l app=test-reloader-app

# Modifica il ConfigMap (dovrebbe triggerare un restart)
kubectl patch configmap test-config --patch '{"data":{"key1":"value2"}}'

# Verifica che il deployment sia stato riavviato (controlla RESTART count)
sleep 10
kubectl get pods -l app=test-reloader-app

# Cleanup
kubectl delete deployment test-reloader-app
kubectl delete configmap test-config
```

## Accesso Servizi

### URL e Credenziali
```bash
# Grafana
# NodePort: http://<NODE-IP>:30300
# Port-Forward: http://localhost:3000
# Credenziali: admin/admin123

# Prometheus: http://localhost:9090
# Alertmanager: http://localhost:9093
# New Relic: https://one.newrelic.com
# Rancher: https://localhost
# Falco logs: kubectl logs -n falco -l app.kubernetes.io/name=falco
# Reloader logs: kubectl logs -n reloader -l app=reloader

# Audit logs API server: sudo tail -f /var/log/kubernetes/audit/audit.log
# Encryption key location: /etc/kubernetes/encryption/encryption-key
```

### Uso Reloader
```bash
# Annotazioni per auto-reload su qualsiasi ConfigMap/Secret
metadata:
  annotations:
    reloader.stakater.com/auto: "true"

# Annotazioni per reload specifici ConfigMap
metadata:
  annotations:
    configmap.reloader.stakater.com/reload: "config1,config2"

# Annotazioni per reload specifici Secret
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "secret1,secret2"

# Verifica eventi Reloader
kubectl get events --field-selector reason=Reloaded
```

## Configurazioni Aggiuntive

### Bash Completion
```bash
echo 'source <(kubectl completion bash)' >>~/.bashrc
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -F __start_kubectl k' >>~/.bashrc
```

### Single-Node Setup
```bash
# Rimuovi taint dal master per permettere scheduling
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### Firewall (se necessario)
```bash
sudo ufw allow 6443/tcp    # API Server
sudo ufw allow 2379:2380/tcp  # etcd
sudo ufw allow 10250/tcp   # kubelet
sudo ufw allow 10251/tcp   # kube-scheduler
sudo ufw allow 10252/tcp   # kube-controller-manager
sudo ufw allow 10255/tcp   # kubelet read-only
```

## Troubleshooting

### Problemi Comuni
```bash
# kubelet non si avvia
sudo journalctl -xeu kubelet
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Pod in Pending
kubectl get events --sort-by='.lastTimestamp'
kubectl describe nodes

# Problemi di rete
kubectl get pods -n kube-flannel  # Per Flannel
cilium status                     # Per Cilium
cilium connectivity test          # Test connettività Cilium

# Problemi audit logging
sudo journalctl -u kubelet | grep audit
sudo ls -la /var/log/kubernetes/audit/
sudo tail /var/log/kubernetes/audit/audit.log

# Problemi cifratura etcd
kubectl get events | grep -i encryption
sudo journalctl -u kubelet | grep encryption
# Verifica che i secret siano cifrati
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/ --prefix=true
```

### Reset Completo
```bash
sudo kubeadm reset
sudo rm -rf /etc/kubernetes/
sudo rm -rf ~/.kube/
sudo rm -rf /var/lib/etcd/
```