"""Lê pontua_mart.testes e falha (exit 1) se algum teste de severidade ERRO não passar.

Testes ALERTA são achados de dados (sempre exibidos, nunca bloqueiam).
TESTES_IGNORADOS (env, separado por vírgula; padrão 'tabelas_sem_expiracao') lista testes ERRO tolerados:
esse falha em projetos BigQuery sandbox (expiração padrão de 60 dias imposta pelo ambiente).
"""
import logging
import os
import sys

from google.cloud import bigquery

from ingestao_bigquery import load_config

log = logging.getLogger("testes")


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    cfg = load_config()
    ignorados = {t.strip() for t in os.getenv("TESTES_IGNORADOS", "tabelas_sem_expiracao").split(",") if t.strip()}
    client = bigquery.Client(project=cfg.project_id)
    rows = list(client.query(
        f"select severidade, teste, ok, detalhe from `{cfg.project_id}.pontua_mart.testes` "
        "order by ok, severidade, teste").result())
    bloqueantes = 0
    log.info("%-8s %-6s %-46s %s", "STATUS", "SEV", "TESTE", "DETALHE")
    for r in rows:
        if r.ok:
            status = "OK"
        elif r.severidade == "ERRO" and r.teste in ignorados:
            status = "IGNORADO"
        elif r.severidade == "ERRO":
            status, bloqueantes = "FALHA", bloqueantes + 1
        else:
            status = "ALERTA"
        log.info("%-8s %-6s %-46s %s", status, r.severidade, r.teste, r.detalhe)
    erros = sum(1 for r in rows if r.severidade == "ERRO")
    alertas = sum(1 for r in rows if r.severidade == "ALERTA" and not r.ok)
    log.info("Testes: %d (ERRO=%d) | falhas bloqueantes=%d | alertas de dados=%d | ignorados=%s",
             len(rows), erros, bloqueantes, alertas, sorted(ignorados))
    return 1 if bloqueantes else 0


if __name__ == "__main__":
    sys.exit(main())
