# Kubernetes Setup with kubeadm

This guide provides step-by-step instructions to set up a Kubernetes cluster using kubeadm on Arch Linux.

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

## Install and Enable Containerd

```bash
sudo pacman -S containerd
sudo systemctl enable --now containerd
```

## Apply sysctl Settings

```bash
sudo sysctl --system
```

## Initialize the Kubernetes Cluster

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
```

## Set up kubeconfig

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## Install Flannel Network Plugin

```bash
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```