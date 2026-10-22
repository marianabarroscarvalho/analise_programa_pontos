-- =====================================================================
-- PONTUA+ | Queries de analise (Passo 2) - BigQuery
-- Rodar DEPOIS de pontua_modelagem_v3.sql. Cada bloco responde a uma
-- pergunta do case; salvar o resultado (CSV ou print) para a apresentacao.
-- Fonte unica dos numeros: pontua_mart / pontua_dw (nada calculado a mao).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. VALIDACAO E DIAGNOSTICO
-- ---------------------------------------------------------------------

-- 0.0 Testes de qualidade (esperado: nenhum ERRO falhando)
SELECT * FROM pontua_mart.testes WHERE NOT ok;

-- 0.1 Diagnostico do ledger: por que nao ha expiracao organica (op 3)?
SELECT operation_code, operation_name, direction, COUNT(*) AS n, SUM(pontos_abs) AS pts,
  MIN(movement_at) AS mov_ini, MAX(movement_at) AS mov_fim,
  MIN(valid_until) AS validade_min, MAX(valid_until) AS validade_max
FROM pontua_dw.fct_ledger GROUP BY 1,2,3 ORDER BY 1;

-- 0.2 Reconciliacao ledger x redeemed_points (itens pagos com 2 contas)
SELECT (SELECT COUNTIF(has_resgate_multiconta) FROM pontua_dw.fct_resgate_item) AS itens_multiconta,
       (SELECT SUM(n_resgate_rows) FROM pontua_stg.resgate_por_item) AS linhas_resgate_redeemed,
       (SELECT COUNTIF(operation_code=2) FROM pontua_dw.fct_ledger) AS linhas_ledger_op2;

-- ---------------------------------------------------------------------
-- 1. O QUE ACONTECEU APOS O PIX
-- ---------------------------------------------------------------------

-- 1.1 Mix mensal e metas
SELECT mes, pts_total, ROUND(pct_aereas,1) AS pct_aereas, ROUND(pct_varejo,1) AS pct_varejo,
  ROUND(pct_pix,1) AS pct_pix, ROUND(pct_outros,1) AS pct_outros,
  meta_aereas_ok, meta_varejo_ok, usuarios_resgatando, usuarios_pix, transacoes_pix
FROM pontua_mart.kpi_mensal ORDER BY mes;

-- 1.2 Antes vs depois do lancamento (media diaria de pontos)
-- ATENCAO: o periodo pre-Pix inclui janeiro/2026 (outlier da migracao)
SELECT IF(d.data < c.pix_launch_date,'pre_pix','pos_pix') AS periodo, COUNT(*) AS dias_com_resgate,
  ROUND(AVG(d.pts_aereas+d.pts_varejo+d.pts_pix)) AS pts_dia_medio,
  ROUND(AVG(d.pts_aereas)) AS aereas_dia, ROUND(AVG(d.pts_varejo)) AS varejo_dia, ROUND(AVG(d.pts_pix)) AS pix_dia
FROM pontua_mart.kpi_diario_pix d CROSS JOIN pontua_dw.cfg c GROUP BY 1;

-- 1.3 Curva de adocao do Pix (primeiros 45 dias)
SELECT data, dias_desde_lancamento, pts_pix, transacoes_pix, novos_adotantes, novos_com_envio_previo
FROM pontua_mart.kpi_diario_pix WHERE dias_desde_lancamento BETWEEN 0 AND 45 ORDER BY data;

-- 1.4 Metas: folga e pontos faltantes
SELECT mes, ROUND(gap_aereas_pp,1) AS gap_aereas_pp, ROUND(gap_varejo_pp,1) AS gap_varejo_pp,
  ROUND(pts_faltantes_aereas) AS pts_falt_aereas, ROUND(pts_faltantes_varejo) AS pts_falt_varejo,
  ROUND(teto_pix_pct_compativel,1) AS teto_pix_pct, ROUND(folga_pix_pp,1) AS folga_pix_pp
FROM pontua_mart.metas_contratuais ORDER BY mes;

-- 1.5 Canibalizacao (antes/depois por adotante; nao causal, sem grupo de controle)
SELECT * FROM pontua_mart.pix_canibalizacao;

-- 1.6 Perfil de quem usa Pix (por classe de cartao)
SELECT card_class, SUM(usuarios) AS usuarios, SUM(adotantes_pix) AS adotantes,
  ROUND(100*SAFE_DIVIDE(SUM(adotantes_pix),SUM(usuarios)),1) AS penetracao_pct, SUM(pts_pix) AS pts_pix
FROM pontua_mart.pix_perfil GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 2. AFIRMACAO 1 (CRM): "a comunicacao de lancamento explica o sucesso do Pix"
-- ---------------------------------------------------------------------

-- 2.1 Conversao observacional por nivel de exposicao e faixa de saldo (sem grupo de controle)
SELECT * FROM pontua_mart.crm_lift_resumo ORDER BY faixa_saldo, nivel_exposicao;

-- 2.2 Adotantes com envio previo e qualidade do join CRM x dim_user
SELECT SUM(novos_adotantes) AS adotantes, SUM(novos_com_envio_previo) AS com_envio_previo,
  ROUND(100*SAFE_DIVIDE(SUM(novos_com_envio_previo),SUM(novos_adotantes)),1) AS pct_com_envio_previo
FROM pontua_mart.kpi_diario_pix;

SELECT teste, ok, detalhe FROM pontua_mart.testes WHERE teste='crm_user_id_casa_com_dim_user';

-- ---------------------------------------------------------------------
-- 3. AFIRMACAO 2 (operador): "o Pix sai a ~R$ 0,016/ponto, abaixo dos R$ 0,019"
-- ---------------------------------------------------------------------

-- 3.1 Taxa efetiva do Pix por definicao
SELECT mes, tx_confirmadas, ROUND(taxa_confirmada,4) AS taxa_confirmada,
  ROUND(taxa_todos_pedidos,4) AS taxa_todos_pedidos, ROUND(taxa_incluindo_estornos,4) AS taxa_incl_estornos,
  ROUND(taxa_liquida_estornos,4) AS taxa_liquida, ROUND(taxa_media_simples,4) AS taxa_media_simples,
  ROUND(taxa_p10,4) AS p10, ROUND(taxa_p50,4) AS p50, ROUND(taxa_p90,4) AS p90,
  ROUND(taxa_relatorio_operador,4) AS taxa_relatorio, ROUND(gap_vs_anunciada,4) AS gap_vs_019
FROM pontua_mart.pix_taxa_efetiva ORDER BY mes;

-- 3.2 Reconciliacao relatorio do operador x recalculo
SELECT mes, rel_pix_pontos, calc_pix_pontos, rel_pix_reais, ROUND(calc_pix_reais) AS calc_pix_reais,
  rel_pix_tx, calc_pix_tx, ROUND(rel_taxa_pix,4) AS rel_taxa, ROUND(calc_taxa_pix,4) AS calc_taxa,
  ROUND(dif_aereas_pp,1) AS dif_aereas_pp, ROUND(dif_varejo_pp,1) AS dif_varejo_pp, ROUND(dif_pix_pp,1) AS dif_pix_pp
FROM pontua_mart.reconciliacao_relatorio ORDER BY mes;

-- 3.3 Pedidos Pix: todos x confirmados (explica o 0,016: relatorio usa pts_pedidos)
SELECT mes, tx_todas, tx_confirmadas, pts_pedidos, pts_confirmados, pts_estornados
FROM pontua_mart.pix_taxa_efetiva ORDER BY mes;

-- 3.4 Pedidos Pix NAO confirmados, por status
SELECT mes, item_status, order_status, COUNT(*) AS n, SUM(pts_pedidos) AS pts
FROM pontua_dw.fct_resgate_item
WHERE categoria='PIX' AND NOT is_confirmado
GROUP BY 1,2,3 ORDER BY 1,2,3;

-- ---------------------------------------------------------------------
-- 4. AFIRMACAO 3 (diretor): "nosso breakage esta em 40%; meta maxima 20%"
-- ---------------------------------------------------------------------

-- 4.1 Breakage: todas as variantes lado a lado
SELECT * FROM pontua_mart.breakage_resumo;

-- 4.2 Usuarios que emitiram e nunca resgataram
SELECT COUNT(DISTINCT l.user_id) AS usuarios_com_earn,
  COUNT(DISTINCT IF(r.user_id IS NULL, l.user_id, NULL)) AS nunca_resgataram,
  ROUND(100*SAFE_DIVIDE(COUNT(DISTINCT IF(r.user_id IS NULL, l.user_id, NULL)), COUNT(DISTINCT l.user_id)),1) AS pct_nunca_resgataram
FROM pontua_dw.fct_ledger l
LEFT JOIN (SELECT DISTINCT user_id FROM pontua_dw.fct_resgate_item WHERE is_confirmado) r ON r.user_id = l.user_id
WHERE l.operation_code = 1;

-- 4.3 Evolucao mensal de emissao, resgate e expiracao
SELECT mes, earn, resgatado, expirado, expirado_migracao, ROUND(pct_resgatado_acum,1) AS pct_resgatado_acum
FROM pontua_mart.breakage_mensal ORDER BY mes;

-- ---------------------------------------------------------------------
-- 5. ESTIMULAR OU COIBIR? ECONOMIA DO PIX E CENARIOS
-- Custos de aereas/varejo = PROXY (valor entregue); preco do banco = PENDENTE
-- ---------------------------------------------------------------------

-- 5.1 Custo por ponto por categoria
SELECT mes, categoria, pts, ROUND(custo_r_por_ponto,4) AS custo_r_ponto, origem_custo,
  ROUND(custo_menos_custo_pix,4) AS custo_menos_pix
FROM pontua_mart.economia_categoria WHERE categoria IN ('PIX','AEREAS','VAREJO') ORDER BY mes, categoria;

-- 5.2 Breakeven do Pix e impacto de realocar 1 p.p. do volume
SELECT mes, ROUND(preco_banco_breakeven_pix,4) AS breakeven_pix, ROUND(pix_menos_aereas_r_por_ponto,4) AS pix_menos_aereas,
  ROUND(pix_menos_varejo_r_por_ponto,4) AS pix_menos_varejo, ROUND(impacto_r_por_pp_vindo_de_aereas) AS impacto_pp_de_aereas,
  ROUND(impacto_r_por_pp_vindo_de_varejo) AS impacto_pp_de_varejo, origem_custo_aereas, origem_custo_varejo
FROM pontua_mart.pix_breakeven ORDER BY mes;

-- 5.3 Cenarios: share de Pix x metas x menor preco do banco sem prejuizo
-- Premissa: o Pix sai proporcionalmente de aereas e varejo (comparar com 1.5)
SELECT ROUND(pix_share_pct) AS pix_share_pct, ANY_VALUE(meta_aereas_ok) AS meta_aereas_ok, ANY_VALUE(meta_varejo_ok) AS meta_varejo_ok,
  ROUND(ANY_VALUE(pct_aereas),1) AS pct_aereas, ROUND(ANY_VALUE(pct_varejo),1) AS pct_varejo,
  MIN(IF(resultado_estimado_r >= 0, preco_banco_r_por_ponto, NULL)) AS preco_banco_minimo_sem_prejuizo,
  ANY_VALUE(mes_base) AS mes_base, ANY_VALUE(origem_custo_aereas) AS origem_custo
FROM pontua_mart.cenarios_pix
WHERE MOD(CAST(ROUND(pix_share_pct) AS INT64),5)=0 GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 6. INFRAESTRUTURA (rodar uma vez, se o teste tabelas_sem_expiracao falhar)
-- ---------------------------------------------------------------------

ALTER SCHEMA pontua_stg  SET OPTIONS(default_table_expiration_days=NULL);
ALTER SCHEMA pontua_dw   SET OPTIONS(default_table_expiration_days=NULL);
ALTER SCHEMA pontua_mart SET OPTIONS(default_table_expiration_days=NULL);
ALTER SCHEMA pontua_ai   SET OPTIONS(default_table_expiration_days=NULL);

FOR t IN (
  SELECT table_schema, table_name FROM pontua_dw.INFORMATION_SCHEMA.TABLE_OPTIONS   WHERE option_name='expiration_timestamp'
  UNION ALL SELECT table_schema, table_name FROM pontua_mart.INFORMATION_SCHEMA.TABLE_OPTIONS WHERE option_name='expiration_timestamp'
  UNION ALL SELECT table_schema, table_name FROM pontua_ai.INFORMATION_SCHEMA.TABLE_OPTIONS   WHERE option_name='expiration_timestamp'
) DO
  EXECUTE IMMEDIATE FORMAT('ALTER TABLE `%s.%s` SET OPTIONS(expiration_timestamp=NULL)', t.table_schema, t.table_name);
END FOR;
