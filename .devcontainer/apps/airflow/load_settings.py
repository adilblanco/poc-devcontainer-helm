"""Load connections & variables into the Airflow metadata DB.

Reads airflow_settings.yaml (Astronomer format) and upserts each connection
and variable. Run *inside* a running Airflow pod (scheduler/webserver), which
already has the DB connection and Fernet key, e.g.:

    kubectl exec -n airflow <scheduler-pod> -- python /tmp/load_settings.py

The apache-airflow Helm chart has no native connections/variables support, so
this replaces the Astronomer CLI behaviour for the local Kind dev loop.
"""

import logging

import yaml
from airflow import settings
from airflow.models import Connection, Variable

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("load_settings")

SETTINGS_PATH = "/tmp/airflow_settings.yaml"

# Astronomer field name -> Connection() kwarg
CONN_FIELDS = {
    "conn_type": "conn_type",
    "conn_host": "host",
    "conn_schema": "schema",
    "conn_login": "login",
    "conn_password": "password",
    "conn_port": "port",
    "conn_extra": "extra",
}

with open(SETTINGS_PATH) as fh:
    data = (yaml.safe_load(fh) or {}).get("airflow", {}) or {}

session = settings.Session()

conn_count = 0
for entry in data.get("connections") or []:
    conn_id = entry.get("conn_id")
    if not conn_id:
        continue
    kwargs = {
        kwarg: entry[field]
        for field, kwarg in CONN_FIELDS.items()
        if entry.get(field) is not None
    }
    # Upsert: drop any existing connection with this id, then re-add.
    session.query(Connection).filter_by(conn_id=conn_id).delete()
    session.add(Connection(conn_id=conn_id, **kwargs))
    conn_count += 1
    log.info("Upserted connection %s", conn_id)

var_count = 0
for entry in data.get("variables") or []:
    name = entry.get("variable_name")
    if not name:
        continue
    Variable.set(name, entry.get("variable_value"))
    var_count += 1
    log.info("Set variable %s", name)

session.commit()
log.info("Loaded %d connections, %d variables", conn_count, var_count)
