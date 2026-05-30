import datetime

from airflow.models import DAG
from plugins.operators.custom_kubernetes_operator import CustomKubernetesPodOperator


args = {
    'owner': 'airflow',
    'start_date': datetime.datetime(2026, 1, 1),
    'email_on_failure': True,
    'retries': 1,
    'retry_delay': datetime.timedelta(minutes=60)
}


with DAG(
    dag_id='example_dag_k8s', 
    default_args=args,
    schedule_interval=None,
    catchup=False,
    tags=['k8s']
) as dag:

    t1 = CustomKubernetesPodOperator(
            dag=dag,
            image="hello-world:1.0",
            name='hello-world'
        )

    t1
