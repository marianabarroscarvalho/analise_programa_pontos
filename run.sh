#!/usr/bin/env bash
# Cria o venv (se preciso), instala dependências e executa a ingestão.
# Uso: ./run.sh [WRITE_TRUNCATE|WRITE_APPEND]
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Crie o .env a partir de .env.example" >&2; exit 2; }
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
if [ $# -gt 0 ]; then
  .venv/bin/python ingestao_bigquery.py --write-disposition "$1"
else
  .venv/bin/python ingestao_bigquery.py
fi
