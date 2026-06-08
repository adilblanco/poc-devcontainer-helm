# Default value used only if --build-arg is not provided.
# In normal workflow, this is always overridden by AIRFLOW_VERSION from config.env
# via the --build-arg flag in post-create.sh.
ARG AIRFLOW_VERSION=2.10.5
FROM apache/airflow:${AIRFLOW_VERSION}

# Copy requirements as the airflow user to avoid permission issues.
COPY --chown=airflow:root requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
