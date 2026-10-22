"""Aplica sql/pontua_modelagem_v5.sql no BigQuery: stg -> dw -> mart -> ai + view de testes.

O script SQL é idempotente (CREATE OR REPLACE). Ajustes feitos em memória, sem editar o arquivo:
  * 'location' dos datasets pontua_* = location do dataset bruto (joins exigem a mesma região);
  * o dataset bruto referenciado como `brain003.` passa a ser o configurado em BIGQUERY_DATASET_ID.
"""
import logging
import re
import sys
import time
from pathlib import Path

from google.cloud import bigquery

from ingestao_bigquery import load_config

SQL_FILE = Path(__file__).parent / "sql" / "pontua_modelagem_v5.sql"
log = logging.getLogger("modelagem")


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    try:
        cfg = load_config()
        client = bigquery.Client(project=cfg.project_id)
        location = client.get_dataset(f"{cfg.project_id}.{cfg.dataset_id}").location
    except Exception as exc:
        log.error("Falha na inicialização (rode a ingestão antes): %s", exc)
        return 2
    sql = SQL_FILE.read_text(encoding="utf-8")
    sql = sql.replace("location='US'", f"location='{location}'")
    sql = re.sub(r"\bbrain003\.", f"{cfg.dataset_id}.", sql)
    log.info("Aplicando %s (location=%s, dataset bruto=%s)", SQL_FILE.name, location, cfg.dataset_id)
    start = time.perf_counter()
    try:
        job = client.query(sql, location=location)
        job.result()
    except Exception as exc:
        log.error("Modelagem falhou: %s", exc)
        return 1
    log.info("Modelagem concluída em %.1fs", time.perf_counter() - start)
    return 0


if __name__ == "__main__":
    sys.exit(main())
