kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      # Maps port 8080 on the DevContainer to NodePort 31080 on the Kind node.
      # Airflow webserver service uses NodePort 31080.
      - containerPort: 31080
        hostPort: 8080
        protocol: TCP
      # MinIO console — consoleService uses NodePort 30901 on the node, mapped to
      # the natural console port 9001 on the host (http://localhost:9001).
      - containerPort: 30901
        hostPort: 9001
        protocol: TCP
    extraMounts:
      # Bind-mount local dags/ and plugins/ into the Kind node so that
      # hostPath PersistentVolumes can expose them to Airflow pods.
      # hostPath = path on the DevContainer (Docker host for DinD).
      # containerPath = path inside the Kind node container.
      # WORKSPACE_DIR is injected by envsubst in post-create.sh — no hardcoded project name.
      - hostPath: ${WORKSPACE_DIR}/dags
        containerPath: /mnt/airflow-dags
      - hostPath: ${WORKSPACE_DIR}/plugins
        containerPath: /mnt/airflow-plugins
