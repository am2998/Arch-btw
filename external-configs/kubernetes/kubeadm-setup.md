# Setup Kubernetes con kubeadm

Questa guida fornisce istruzioni passo-passo per configurare un cluster Kubernetes utilizzando kubeadm su Arch Linux. Puoi scegliere tra Containerd o CRI-O come container runtime, e Flannel o Cilium come plugin di rete.

## Installazione Docker

```bash
sudo pacman -S docker
sudo systemctl enable --now docker
```

## Installazione Componenti Kubernetes

```bash
sudo pacman -S kubeadm kubelet kubectl
sudo systemctl enable --now kubelet
sudo swapoff -a
```

## Configurazione Network Bridge

```bash
sudo modprobe br_netfilter
```

## Configurazione Parametri sysctl

Crea il file di configurazione sysctl:

```bash
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
```

## Scelta e Installazione Container Runtime

### Opzione 1: Containerd (Raccomandato)

```bash
sudo pacman -S containerd
sudo systemctl enable --now containerd

# Configurazione containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
```

### Opzione 2: CRI-O

```bash
sudo pacman -S cri-o crun
sudo systemctl enable --now crio
```

## Applicazione Impostazioni sysctl

```bash
sudo sysctl --system
```

## Disabilitazione Swap Permanente

```bash
# Disabilita swap temporaneamente
sudo swapoff -a

# Disabilita swap permanentemente
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

## Inizializzazione Cluster Kubernetes

### Per Containerd:

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket unix:///var/run/containerd/containerd.sock
```

### Per CRI-O:

```bash
sudo kubeadm init --cri-socket unix:///var/run/crio/crio.sock --pod-network-cidr=10.244.0.0/16
```

## Configurazione kubeconfig

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Verifica Installazione

```bash
kubectl cluster-info
kubectl get nodes
```

## Scelta e Installazione Plugin di Rete

### Opzione 1: Flannel (Semplice)

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

### Opzione 2: Cilium (Avanzato)

```bash
# Installazione Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# Installazione Cilium
cilium install
```

## Rimozione Taint dal Nodo Master (Solo per Single-Node)

Se vuoi eseguire pod sul nodo master (utile per cluster single-node):

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Verifica Cluster

```bash
# Verifica stato nodi
kubectl get nodes -o wide

# Verifica pod di sistema
kubectl get pods -n kube-system

# Verifica connettività di rete (se usi Cilium)
cilium status
```

## Installazione Helm

```bash
sudo pacman -S helm
```

## Troubleshooting

### Problema: kubelet non si avvia

```bash
# Controlla log
sudo journalctl -xeu kubelet

# Riavvia servizi
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

### Problema: Pod in stato Pending

```bash
# Verifica eventi
kubectl get events --sort-by='.lastTimestamp'

# Verifica risorse
kubectl describe nodes
```

### Problema: Rete non funziona

```bash
# Per Flannel
kubectl get pods -n kube-flannel

# Per Cilium
cilium status
cilium connectivity test
```

### Reset Completo del Cluster

```bash
sudo kubeadm reset
sudo rm -rf /etc/kubernetes/
sudo rm -rf ~/.kube/
sudo rm -rf /var/lib/etcd/
```

## Configurazioni Aggiuntive

### Abilitazione Completamento Bash

```bash
echo 'source <(kubectl completion bash)' >>~/.bashrc
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -F __start_kubectl k' >>~/.bashrc
```

### Configurazione Firewall (se necessario)

```bash
# Porte necessarie per Kubernetes
sudo ufw allow 6443/tcp  # API Server
sudo ufw allow 2379:2380/tcp  # etcd
sudo ufw allow 10250/tcp  # kubelet
sudo ufw allow 10251/tcp  # kube-scheduler
sudo ufw allow 10252/tcp  # kube-controller-manager
sudo ufw allow 10255/tcp  # kubelet read-only
```