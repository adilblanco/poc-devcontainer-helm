# poc-devcontainer-helm

## Chargement d'images Docker dans Kind (KubernetesPodOperator)

Le `KubernetesPodOperator` d'Airflow lance des Pods dans le cluster Kind. Ces Pods ont besoin que leurs images soient présentes **dans containerd** (le runtime interne de Kind), et non dans le daemon Docker du devcontainer.

### Pourquoi `kind load docker-image` ne fonctionne pas ici

Dans un devcontainer avec DinD, la chaîne de transmission est plus longue :

```
devcontainer → socket Docker (hôte) → kind load → Kind (containerd)
```

Cette conversion échoue sur ARM64 en raison d'un problème de détection d'architecture entre Docker et containerd.

### Méthode incorrecte (ne fonctionne pas)

`kind load docker-image` échoue sur ARM64 en devcontainer DinD — la conversion entre Docker et containerd ne détecte pas correctement l'architecture :

```bash
# Ne pas utiliser dans ce contexte
docker pull --platform linux/arm64 <image>:<tag>
docker tag <image>:<tag> <image>:<nouveau-tag>
kind load docker-image <image>:<nouveau-tag> --name local
```

### Méthode correcte

Passer directement par `ctr`, le CLI de containerd à l'intérieur du nœud Kind, en contournant Docker :

```bash
# 1. Télécharger l'image directement dans containerd (namespace k8s.io)
docker exec local-control-plane ctr --namespace=k8s.io images pull docker.io/library/<image>:<tag>

# 2. Créer un tag supplémentaire si nécessaire
docker exec local-control-plane ctr --namespace=k8s.io images tag \
  docker.io/library/<image>:<tag> \
  docker.io/library/<image>:<nouveau-tag>
```

**Exemple avec `hello-world` :**

```bash
docker exec local-control-plane ctr --namespace=k8s.io images pull docker.io/library/hello-world:latest
docker exec local-control-plane ctr --namespace=k8s.io images tag \
  docker.io/library/hello-world:latest \
  docker.io/library/hello-world:1.0
```

### Vérifier que l'image est bien chargée

```bash
docker exec local-control-plane ctr --namespace=k8s.io images list | grep hello-world
```

### Utilisation dans un DAG avec KubernetesPodOperator

Une fois l'image chargée, configurer `image_pull_policy: Never` pour que Kubernetes utilise l'image locale sans tenter de la télécharger :

```python
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator

task = KubernetesPodOperator(
    task_id="hello_world",
    name="hello-world-pod",
    namespace="airflow",
    image="docker.io/library/hello-world:1.0",
    image_pull_policy="Never",
    ...
)
```
