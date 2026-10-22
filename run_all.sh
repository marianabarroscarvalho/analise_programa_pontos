#!/usr/bin/env bash
# Pipeline ponta a ponta: venv -> ingestão dos CSVs -> modelagem SQL -> testes -> dashboard.
# Pré-requisito: .env preenchido (cp .env.example .env) e a chave JSON da service account.
# Uso: ./run_all.sh                    (sobe o dashboard ao final)
#      ./run_all.sh --sem-dashboard    (termina após os testes)
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "ERRO: crie o .env (cp .env.example .env) e ajuste GCP_PROJECT_ID e GOOGLE_APPLICATION_CREDENTIALS." >&2; exit 2; }

echo "==> 1/5 Ambiente virtual e dependências"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt

echo "==> 2/5 Ingestão dos CSVs (dados/ -> BigQuery, WRITE_TRUNCATE)"
.venv/bin/python -W ignore ingestao_bigquery.py --write-disposition WRITE_TRUNCATE

echo "==> 3/5 Modelagem SQL (stg -> dw -> mart -> ai)"
.venv/bin/python -W ignore modelagem_bigquery.py

echo "==> 4/5 Testes de integridade (pontua_mart.testes)"
.venv/bin/python -W ignore testes_bigquery.py

if [ "${1:-}" = "--sem-dashboard" ]; then
  echo "==> Concluído (dashboard não iniciado). Para abrir: .venv/bin/streamlit run dashboard.py"
  exit 0
fi
echo "==> 5/5 Dashboard em http://localhost:8501"
exec .venv/bin/streamlit run dashboard.py
