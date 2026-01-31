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
    --set falco.syscallEventDrops.actions="log\,alert" \
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

### Reloader (Riavvio Automatico su Modifiche ConfigMap/Secret)
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

### Sealed Secrets (Secret Cifrati in Git)
```bash
# Aggiungi repository
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

# Crea namespace
kubectl create namespace sealed-secrets

# Installa Sealed Secrets Controller
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace sealed-secrets \
    --set resources.limits.memory=256Mi \
    --set resources.requests.memory=128Mi \
    --set resources.requests.cpu=50m \
    --timeout=5m

# Installa kubeseal CLI (client-side)
# Per Arch Linux
yay -S kubeseal-bin

# Oppure download manuale
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -c 2-)
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal

# Verifica installazione
kubeseal --version

# Backup della chiave privata del controller (IMPORTANTE!)
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-master-key.yaml
# Conserva questo file in un luogo sicuro!
```

### Uso Sealed Secrets
```bash
# Crea un secret normale (NON committare questo!)
kubectl create secret generic mysecret \
    --from-literal=username=admin \
    --from-literal=password=supersecret \
    --dry-run=client -o yaml > mysecret.yaml

# Cifra il secret con kubeseal
kubeseal -f mysecret.yaml -w mysealedsecret.yaml

# Ora mysealedsecret.yaml può essere committato in Git
# Applica il sealed secret
kubectl apply -f mysealedsecret.yaml

# Il controller decifrerà automaticamente e creerà il secret normale
kubectl get secret mysecret -o yaml

# Cleanup file non cifrato
rm mysecret.yaml

# Esempio con scope namespace-wide (default)
echo -n supersecret | kubectl create secret generic mysecret2 \
    --dry-run=client --from-file=password=/dev/stdin -o yaml | \
    kubeseal -o yaml > mysealedsecret2.yaml

# Esempio con scope cluster-wide (può essere usato in qualsiasi namespace)
echo -n supersecret | kubectl create secret generic mysecret3 \
    --dry-run=client --from-file=password=/dev/stdin -o yaml | \
    kubeseal --scope cluster-wide -o yaml > mysealedsecret3.yaml

# Esempio con scope strict (legato a nome e namespace specifici)
echo -n supersecret | kubectl create secret generic mysecret4 \
    --dry-run=client --from-file=password=/dev/stdin -o yaml | \
    kubeseal --scope strict -o yaml > mysealedsecret4.yaml
```

### Ripristino Sealed Secrets (Disaster Recovery)
```bash
# Se devi ripristinare il controller su un nuovo cluster
# Applica la chiave privata salvata in precedenza
kubectl apply -f sealed-secrets-master-key.yaml

# Riavvia il controller per caricare la chiave
kubectl rollout restart deployment sealed-secrets -n sealed-secrets

# Verifica che il controller sia pronto
kubectl get pods -n sealed-secrets

# Ora puoi applicare i sealed secrets esistenti
kubectl apply -f mysealedsecret.yaml
```

## Gestione Cluster

### ArgoCD (GitOps Continuous Delivery)
```bash
# Aggiungi repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Crea namespace
kubectl create namespace argocd

# Installa ArgoCD
helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --set server.service.type=NodePort \
    --set server.service.nodePortHttp=30080 \
    --set server.service.nodePortHttps=30443 \
    --set configs.params."server\.insecure"=true \
    --set redis.enabled=true \
    --set controller.replicas=1 \
    --set server.replicas=1 \
    --set repoServer.replicas=1 \
    --set applicationSet.replicas=1 \
    --set server.resources.limits.memory=512Mi \
    --set server.resources.requests.memory=256Mi \
    --set controller.resources.limits.memory=1Gi \
    --set controller.resources.requests.memory=512Mi \
    --set repoServer.resources.limits.memory=512Mi \
    --set repoServer.resources.requests.memory=256Mi \
    --timeout=10m

# Installa ArgoCD CLI
# Per Arch Linux
yay -S argocd-bin

# Oppure download manuale
ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64

# Verifica installazione
argocd version --client

# Ottieni password iniziale admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

### Configurazione ArgoCD
```bash
# Login via CLI (dopo aver ottenuto la password)
argocd login localhost:30443 --username admin --password <password-ottenuta> --insecure

# Cambia password admin
argocd account update-password

# Aggiungi repository Git
argocd repo add https://github.com/your-org/your-repo.git \
    --username your-username \
    --password your-token

# Oppure con SSH
argocd repo add git@github.com:your-org/your-repo.git \
    --ssh-private-key-path ~/.ssh/id_rsa

# Lista repository configurati
argocd repo list

# Crea un'applicazione da CLI
argocd app create my-app \
    --repo https://github.com/your-org/your-repo.git \
    --path manifests \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace default \
    --sync-policy automated \
    --auto-prune \
    --self-heal

# Lista applicazioni
argocd app list

# Sincronizza manualmente un'applicazione
argocd app sync my-app

# Visualizza dettagli applicazione
argocd app get my-app

# Elimina un'applicazione
argocd app delete my-app
```

### Esempio Applicazione ArgoCD (Manifest)
```bash
# Crea un'applicazione tramite manifest YAML
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: HEAD
    path: manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
```

### ArgoCD con Kustomize
```bash
# Esempio applicazione con Kustomize
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-kustomize-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: HEAD
    path: kustomize/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

### ArgoCD con Helm
```bash
# Esempio applicazione con Helm chart
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-helm-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/helm-charts.git
    targetRevision: HEAD
    path: charts/my-app
    helm:
      valueFiles:
      - values-production.yaml
      parameters:
      - name: image.tag
        value: "v1.2.3"
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

### ArgoCD Projects
```bash
# Crea un progetto ArgoCD per organizzare le applicazioni
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: Production applications
  sourceRepos:
  - 'https://github.com/your-org/*'
  destinations:
  - namespace: 'production'
    server: https://kubernetes.default.svc
  - namespace: 'staging'
    server: https://kubernetes.default.svc
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
EOF

# Lista progetti
argocd proj list

# Visualizza dettagli progetto
argocd proj get production
```

### Notifiche ArgoCD
```bash
# Installa ArgoCD Notifications
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-notifications/release-1.0/manifests/install.yaml

# Configura notifiche Slack (esempio)
kubectl patch configmap argocd-notifications-cm -n argocd --patch '
data:
  service.slack: |
    token: $slack-token
  template.app-deployed: |
    message: |
      Application {{.app.metadata.name}} is now running new version.
    slack:
      attachments: |
        [{
          "title": "{{ .app.metadata.name}}",
          "title_link":"{{.context.argocdUrl}}/applications/{{.app.metadata.name}}",
          "color": "#18be52",
          "fields": [
          {
            "title": "Sync Status",
            "value": "{{.app.status.sync.status}}",
            "short": true
          }]
        }]
  trigger.on-deployed: |
    - when: app.status.operationState.phase in ["Succeeded"]
      send: [app-deployed]
'

# Aggiungi secret per token Slack
kubectl create secret generic argocd-notifications-secret -n argocd \
    --from-literal=slack-token=xoxb-your-slack-token
```

### Accesso ArgoCD UI
```bash
# Via NodePort (configurato durante installazione)
# http://<NODE-IP>:30080
# https://<NODE-IP>:30443

# Oppure via port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
# Accedi a: https://localhost:8080

# Username: admin
# Password: ottenuta con il comando precedente
```

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

## Network Policy

### Applicazione Network Policy
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

# ArgoCD
kubectl port-forward -n argocd svc/argocd-server 8080:443 &
```

## Verifica e Diagnostica

### Stato Componenti
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
kubectl get pods -n sealed-secrets
kubectl get pods -n argocd

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

### Test Funzionalità Reloader
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
# ArgoCD NodePort: http://<NODE-IP>:30080 o https://<NODE-IP>:30443
# ArgoCD Port-Forward: https://localhost:8080
# ArgoCD Credenziali: admin / <password da secret>
# Falco logs: kubectl logs -n falco -l app.kubernetes.io/name=falco
# Reloader logs: kubectl logs -n reloader -l app=reloader
# Sealed Secrets logs: kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets

# Audit logs API server: sudo tail -f /var/log/kubernetes/audit/audit.log
# Encryption key location: /etc/kubernetes/encryption/encryption-key
# Sealed Secrets master key backup: sealed-secrets-master-key.yaml (conservare in luogo sicuro!)
```

### Uso ArgoCD
```bash
# Login CLI
argocd login <ARGOCD-SERVER> --username admin --password <password>

# Sincronizza applicazione
argocd app sync <app-name>

# Visualizza stato applicazione
argocd app get <app-name>

# Visualizza differenze
argocd app diff <app-name>

# Rollback a revisione precedente
argocd app rollback <app-name> <revision-id>

# Visualizza cronologia sincronizzazioni
argocd app history <app-name>

# Abilita auto-sync
argocd app set <app-name> --sync-policy automated

# Disabilita auto-sync
argocd app set <app-name> --sync-policy none

# Forza hard refresh (ignora cache)
argocd app get <app-name> --hard-refresh
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

### Uso Sealed Secrets
```bash
# Verifica che il controller sia in esecuzione
kubectl get pods -n sealed-secrets

# Ottieni la chiave pubblica del controller
kubeseal --fetch-cert > pub-cert.pem

# Cifra un secret usando la chiave pubblica (offline)
kubeseal --cert pub-cert.pem -f mysecret.yaml -w mysealedsecret.yaml

# Lista sealed secrets
kubectl get sealedsecrets -A

# Verifica che il secret sia stato creato dal controller
kubectl get secrets -A | grep mysecret

# Ruota le chiavi di cifratura (ogni 30 giorni di default)
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets | grep "New key"

# Forza rotazione manuale (crea una nuova chiave)
kubectl delete secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key=active
kubectl rollout restart deployment sealed-secrets -n sealed-secrets
```

## Configurazioni Aggiuntive

### Bash Completion
```bash
echo 'source <(kubectl completion bash)' >>~/.bashrc
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -F __start_kubectl k' >>~/.bashrc
```

### Configurazione Nodo Singolo
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

# Problemi ArgoCD
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server

# ArgoCD applicazione out of sync
argocd app get <app-name>
argocd app diff <app-name>
argocd app sync <app-name> --force
```

### Reset Completo
```bash
sudo kubeadm reset
sudo rm -rf /etc/kubernetes/
sudo rm -rf ~/.kube/
sudo rm -rf /var/lib/etcd/
```

### K3S
curl -sfL https://get.k3s.io | sh -s - --cluster-init --secrets-encryption --write-kubeconfig-mode 644

