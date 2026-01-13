# Kubernetes Setup with kubeadm

This guide provides step-by-step instructions to set up a Kubernetes cluster using kubeadm on Arch Linux. You can choose between Containerd or CRI-O as the container runtime, and Flannel or Cilium as the network plugin.

## Install Docker

```bash
sudo pacman -S docker
```

## Install Kubernetes Components

```bash
sudo pacman -S kubeadm kubelet kubectl
sudo systemctl enable --now kubelet
```

## Configure Network Bridge

```bash
sudo modprobe br_netfilter
```

## Set sysctl Parameters

Create the sysctl configuration file:

```bash
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
```

## Choose and Install Container Runtime

### Option 1: Containerd (Recommended)

```bash
sudo pacman -S containerd
sudo systemctl enable --now containerd
```

### Option 2: CRI-O

```bash
sudo pacman -S --needed base-devel git
git clone https://aur.archlinux.org/cri-o.git
cd cri-o
makepkg -si
sudo systemctl enable --now crio
```

## Apply sysctl Settings

```bash
sudo sysctl --system
```

## Initialize the Kubernetes Cluster

### For Containerd:

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
```

### For CRI-O:

```bash
sudo kubeadm init --cri-socket /var/run/crio/crio.sock --pod-network-cidr=10.244.0.0/16
```

## Set up kubeconfig

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Choose and Install Network Plugin

### Option 1: Flannel

```bash
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```

### Option 2: Cilium

```bash
curl -L --remote-name https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
tar xzvf cilium-linux-amd64.tar.gz
sudo mv cilium /usr/local/bin/
cilium install
```
