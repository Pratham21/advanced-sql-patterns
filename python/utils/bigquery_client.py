# ============================================================
# bigquery_client.py — Reusable BigQuery connection & query utilities
# Author: Pratham Bharadwaj
# Use case: Used across Intuit & eBay pipelines for BQ data extraction
# ============================================================

from google.cloud import bigquery
from google.oauth2 import service_account
import pandas as pd
import logging
import os

logging.basicConfig(level=logging.INFO, format="%(asctime)s — %(levelname)s — %(message)s")
logger = logging.getLogger(__name__)


class BigQueryClient:
    """
    Reusable BigQuery client wrapper.
    Handles authentication, query execution, and results as DataFrames.
    """

    def __init__(self, project_id: str, credentials_path: str = None):
        self.project_id = project_id
        if credentials_path:
            credentials = service_account.Credentials.from_service_account_file(
                credentials_path,
                scopes=["https://www.googleapis.com/auth/cloud-platform"]
            )
            self.client = bigquery.Client(project=project_id, credentials=credentials)
        else:
            # Uses Application Default Credentials (ADC) — works on GCP VMs and local gcloud auth
            self.client = bigquery.Client(project=project_id)
        logger.info(f"BigQuery client initialised for project: {project_id}")

    def run_query(self, sql: str, params: dict = None) -> pd.DataFrame:
        """Execute a SQL query and return results as a Pandas DataFrame."""
        try:
            logger.info("Executing BigQuery query...")
            job_config = bigquery.QueryJobConfig()
            if params:
                job_config.query_parameters = [
                    bigquery.ScalarQueryParameter(k, "STRING", v)
                    for k, v in params.items()
                ]
            query_job = self.client.query(sql, job_config=job_config)
            df = query_job.to_dataframe()
            logger.info(f"Query returned {len(df):,} rows")
            return df
        except Exception as e:
            logger.error(f"Query failed: {e}")
            raise

    def load_dataframe(self, df: pd.DataFrame, dataset: str, table: str,
                       write_mode: str = "WRITE_APPEND") -> None:
        """Load a Pandas DataFrame into a BigQuery table."""
        table_ref = f"{self.project_id}.{dataset}.{table}"
        write_disposition = getattr(bigquery.WriteDisposition, write_mode)
        job_config = bigquery.LoadJobConfig(write_disposition=write_disposition)
        try:
            job = self.client.load_table_from_dataframe(df, table_ref, job_config=job_config)
            job.result()
            logger.info(f"Loaded {len(df):,} rows into {table_ref}")
        except Exception as e:
            logger.error(f"Load failed: {e}")
            raise

    def run_query_to_table(self, sql: str, destination_dataset: str,
                           destination_table: str) -> None:
        """Run a query and write results directly to a BQ table (no local memory needed)."""
        destination = f"{self.project_id}.{destination_dataset}.{destination_table}"
        job_config = bigquery.QueryJobConfig(
            destination=destination,
            write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE
        )
        try:
            query_job = self.client.query(sql, job_config=job_config)
            query_job.result()
            logger.info(f"Query results written to {destination}")
        except Exception as e:
            logger.error(f"Query-to-table failed: {e}")
            raise
