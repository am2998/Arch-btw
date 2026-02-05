### K3S
curl -sfl https://get.k3s.io | sh -s - \
  --cluster-init \
  --secrets-encryption \
  --etcd-snapshot-schedule-cron="0 */6 * * *" \
  --etcd-snapshot-retention=10 \
  --etcd-snapshot-dir=/var/lib/rancher/k3s/server/db/snapshots \
  --flannel-backend=none \
  --disable-network-policy \
  --write-kubeconfig-mode 644

curl -sSl https://github.com/cilium/cilium-cli/releases/download/v0.19.0/cilium-linux-amd64.tar.gz
cilium install --version 1.18.6 --set=ipam.operator.clusterpoolipv4podcidrlist="10.42.0.0/16"
cilium status --wait
cilium connectivity test

echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc && source .bashrc

sudo mkdir -p /mnt/data/immich-postgres
sudo mkdir -p /mnt/data/immich-redis
sudo mkdir -p /mnt/data/immich-library  
sudo chown -R 1001:1001 /mnt/data/immich-postgres
sudo chown -R 1001:1001 /mnt/data/immich-redis
sudo chown -R 1001:1001 /mnt/data/immich-library
