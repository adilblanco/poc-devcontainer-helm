apiVersion: v2
name: airflow-local
description: Helm chart wrapper for local Kind development — pins the apache-airflow chart version.

type: application

# Version of this wrapper chart (bump when devcontainer infra changes).
version: 0.1.0

# Airflow application version running inside the pods.
appVersion: "${AIRFLOW_VERSION}"

dependencies:
  - name: airflow
    version: "${AIRFLOW_CHART_VERSION}"
    repository: https://airflow.apache.org
