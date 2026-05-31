ARG AIRFLOW_VERSION=2.11.0
FROM apache/airflow:${AIRFLOW_VERSION}

# Copy requirements as the airflow user to avoid permission issues.
COPY --chown=airflow:root requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
