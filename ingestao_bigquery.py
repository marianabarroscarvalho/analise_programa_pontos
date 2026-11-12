"""Ingestão de CSVs para o BigQuery via load jobs (não linha a linha)."""
import argparse
import csv
import logging
import os
import re
import sys
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv
from google.api_core.exceptions import NotFound
from google.cloud import bigquery

log = logging.getLogger("ingestao")

VALID_DISPOSITIONS = {"WRITE_TRUNCATE", "WRITE_APPEND"}


@dataclass(frozen=True)
class Config:
    project_id: str
    dataset_id: str
    csv_folder: Path
    write_disposition: str
    location: str | None  # só usada na criação do dataset


@dataclass
class Result:
    file: str
    table: str
    csv_rows: int = 0
    loaded_rows: int = 0
    bq_rows: int = 0
    ok: bool = False
    error: str = ""
    seconds: float = 0.0


def require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"Variável de ambiente obrigatória ausente: {name}")
    return value


def load_config(write_disposition: str | None = None) -> Config:
    load_dotenv()
    project = require_env("GCP_PROJECT_ID")
    # Aceita "projeto.dataset" ou apenas "dataset".
    dataset = require_env("BIGQUERY_DATASET_ID").split(".")[-1]
    creds = Path(require_env("GOOGLE_APPLICATION_CREDENTIALS"))
    if not creds.is_file():
        raise ValueError(f"Arquivo de credenciais não encontrado: {creds}")
    folder = Path(require_env("CSV_FOLDER_PATH"))
    if not folder.is_dir():
        raise ValueError(f"Pasta de CSVs não encontrada: {folder}")
    disposition = (write_disposition or os.getenv("WRITE_DISPOSITION", "WRITE_TRUNCATE")).upper()
    if disposition not in VALID_DISPOSITIONS:
        raise ValueError(f"WRITE_DISPOSITION inválido: {disposition} (use {sorted(VALID_DISPOSITIONS)})")
    return Config(project, dataset, folder, disposition, os.getenv("BIGQUERY_LOCATION") or None)


def sanitize_table_name(path: Path) -> str:
    name = unicodedata.normalize("NFKD", path.stem).encode("ascii", "ignore").decode()
    name = re.sub(r"[^0-9a-zA-Z_]+", "_", name).strip("_").lower()
    if not name or name[0].isdigit():
        name = f"t_{name}"
    return name[:1024]


def find_csvs(folder: Path) -> list[Path]:
    return sorted(p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() == ".csv")


def count_csv_rows(path: Path) -> int:
    """Conta registros (sem cabeçalho) respeitando campos com quebra de linha entre aspas."""
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        next(reader, None)
        return sum(1 for _ in reader)


def ensure_dataset(client: bigquery.Client, cfg: Config) -> str:
    """Garante o dataset e devolve sua location real (os jobs devem usá-la)."""
    ref = f"{cfg.project_id}.{cfg.dataset_id}"
    try:
        dataset = client.get_dataset(ref)
        log.info("Dataset %s já existe (location=%s)", ref, dataset.location)
        return dataset.location
    except NotFound:
        dataset = bigquery.Dataset(ref)
        if cfg.location:
            dataset.location = cfg.location
        created = client.create_dataset(dataset)
        log.info("Dataset %s criado (location=%s)", ref, created.location)
        return created.location


def build_job_config(write_disposition: str) -> bigquery.LoadJobConfig:
    return bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
        autodetect=True,  # datas/timestamps ISO e inteiros inferidos automaticamente
        write_disposition=write_disposition,
        allow_quoted_newlines=True,
        null_marker="",  # campos vazios viram NULL
        encoding="UTF-8",
    )


def load_file(client: bigquery.Client, cfg: Config, path: Path, location: str) -> Result:
    table = sanitize_table_name(path)
    result = Result(file=str(path), table=table)
    start = time.perf_counter()
    table_id = f"{cfg.project_id}.{cfg.dataset_id}.{table}"
    try:
        log.info("[%s] início do job -> %s (%s)", path.name, table_id, cfg.write_disposition)
        result.csv_rows = count_csv_rows(path)
        with path.open("rb") as f:
            job = client.load_table_from_file(
                f, table_id, job_config=build_job_config(cfg.write_disposition), location=location
            )
        job.result()
        result.loaded_rows = job.output_rows or 0
        result.bq_rows = client.get_table(table_id).num_rows
        expected = result.csv_rows if cfg.write_disposition == "WRITE_TRUNCATE" else None
        if result.loaded_rows != result.csv_rows:
            raise RuntimeError(f"Linhas carregadas ({result.loaded_rows}) != linhas no CSV ({result.csv_rows})")
        if expected is not None and result.bq_rows != expected:
            raise RuntimeError(f"Linhas na tabela ({result.bq_rows}) != linhas no CSV ({expected})")
        result.ok = True
        log.info("[%s] OK: csv=%d carregadas=%d total_na_tabela=%d", path.name,
                 result.csv_rows, result.loaded_rows, result.bq_rows)
    except Exception as exc:  # isolamento por arquivo: um erro não derruba os demais
        result.error = f"{type(exc).__name__}: {exc}"
        log.error("[%s] ERRO: %s", path.name, result.error)
    finally:
        result.seconds = time.perf_counter() - start
    return result


def print_summary(results: list[Result], total_seconds: float) -> None:
    log.info("=" * 78)
    log.info("%-28s %-8s %10s %10s %10s", "tabela", "status", "csv", "carregadas", "bq_total")
    for r in results:
        log.info("%-28s %-8s %10d %10d %10d", r.table, "OK" if r.ok else "FALHA",
                 r.csv_rows, r.loaded_rows, r.bq_rows)
    failures = [r for r in results if not r.ok]
    log.info("Arquivos: %d | sucesso: %d | falhas: %d | tempo total: %.1fs",
             len(results), len(results) - len(failures), len(failures), total_seconds)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ingestão de CSVs para o BigQuery")
    parser.add_argument("--write-disposition", choices=sorted(VALID_DISPOSITIONS),
                        help="Sobrescreve WRITE_DISPOSITION do .env")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s",
                        datefmt="%H:%M:%S")
    start = time.perf_counter()
    try:
        cfg = load_config(args.write_disposition)
        files = find_csvs(cfg.csv_folder)
        if not files:
            raise ValueError(f"Nenhum .csv encontrado em {cfg.csv_folder}")
        client = bigquery.Client(project=cfg.project_id)
        location = ensure_dataset(client, cfg)
    except Exception as exc:
        log.error("Falha na inicialização: %s", exc)
        return 2
    log.info("%d CSV(s) encontrados em %s", len(files), cfg.csv_folder)
    results = [load_file(client, cfg, p, location) for p in files]
    print_summary(results, time.perf_counter() - start)
    return 0 if all(r.ok for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
