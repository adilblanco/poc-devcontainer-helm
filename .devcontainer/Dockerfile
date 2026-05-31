FROM apache/airflow:2.11.0

# Copy requirements as the airflow user to avoid permission issues.
COPY --chown=airflow:root requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy DAGs and plugins into the image.
# Note: requires a Rebuild Container to pick up changes.
COPY --chown=airflow:root dags/ /opt/airflow/dags/
COPY --chown=airflow:root plugins/ /opt/airflow/plugins/

# Makes 'from plugins.operators...' resolvable — mirrors the production setup
# where PYTHONPATH points to the project root (gitSync uses /opt/airflow/dags/repo).
ENV PYTHONPATH=/opt/airflow
