# Argo CD - App of Apps

## Structure
- `root-application.yaml`: parent app that syncs all child applications.
- `apps/`: child `Application` manifests managed by the root app.

## Bootstrap
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f external-configs/kubernetes/k3s/argocd/root-application.yaml
```

## Notes
- Root app points to `https://github.com/am2998/Arch-Lab.git` on `HEAD`.
- Child apps use sync waves for deterministic ordering.
