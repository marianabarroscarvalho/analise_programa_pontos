-- =====================================================================
-- PONTUA+ | Modelagem analitica v5 (BigQuery) - dashboard + agente de IA
-- Fonte: dataset `brain003` (9 CSVs carregados como tabelas).
-- Camadas:
--   pontua_stg   views de limpeza (1 por fonte), sem regra de negocio de KPI
--   pontua_dw    fatos/dimensoes + premissas (versionadas, com status)
--   pontua_mart  tabelas de dashboard (grao declarado no description)
--   pontua_ai    catalogos semanticos e regras de resposta do agente
-- Executar na ordem, de uma vez so. Projeto padrao do job: stoked-outlook-303718.
--
-- v5: apenas as queries de modelagem. Sem DROP/ALTER/DML: delete as tabelas antigas pela
-- interface do BigQuery e rode este script inteiro, na ordem.
--   * Sem PARTITION BY nos fatos (evita expiracao de particao).
--   * user_id e cart_id em STRING em orders, ledger, crm e cards.
--   * premissas via CREATE TABLE AS SELECT (sem MERGE/UPDATE).
--   * Testes de cobertura novos em pontua_mart.testes.
-- Demais regras iguais a v3.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS pontua_stg  OPTIONS(location='US');
CREATE SCHEMA IF NOT EXISTS pontua_dw   OPTIONS(location='US');
CREATE SCHEMA IF NOT EXISTS pontua_mart OPTIONS(location='US');
CREATE SCHEMA IF NOT EXISTS pontua_ai   OPTIONS(location='US');

-- =====================================================================
-- 0. PREMISSAS (fonte unica de parametros; cada uma com status e fonte)
-- status: DADO (veio dos arquivos/enunciado) | DECLARADO (alguem afirmou) |
--         PROXY (estimado dos dados) | PENDENTE (precisa do negocio)
-- Sem DML: para preencher um PENDENTE, troque o NULL pelo valor e o status por 'DECLARADO' ou 'DADO'
-- na linha correspondente abaixo e rode o script de novo.
-- =====================================================================
CREATE OR REPLACE TABLE pontua_dw.premissas
OPTIONS(description='Grao: chave. Parametros de negocio com status de confiabilidade. O agente deve ler status antes de usar um valor.') AS
SELECT * FROM UNNEST([
  STRUCT('pix_launch_date' AS chave, CAST(NULL AS FLOAT64) AS valor, '2026-05-27' AS valor_texto, 'data' AS unidade, 'DADO' AS status, 'enunciado' AS fonte, 'Lancamento do Pontos no Pix' AS descricao),
  ('data_extracao', NULL, '2026-10-01', 'data', 'DADO', 'enunciado', 'Data de extracao dos dados; usada no lugar de CURRENT_DATE'),
  ('pix_taxa_anunciada', 0.019, NULL, 'R$/ponto', 'DADO', 'enunciado', 'Taxa anunciada do Pix'),
  ('pix_pontos_por_real', 53, NULL, 'pontos', 'DADO', 'enunciado', '53 pontos ~ R$1'),
  ('meta_aereas_min', 0.50, NULL, 'fracao', 'DADO', 'contrato', 'Aereas >= 50% dos pontos resgatados'),
  ('meta_varejo_min', 0.20, NULL, 'fracao', 'DADO', 'contrato', 'Varejo >= 20% dos pontos resgatados'),
  ('meta_breakage_max', 0.20, NULL, 'fracao', 'DECLARADO', 'diretor', 'Meta de breakage maximo; definicao de breakage nao documentada'),
  ('preco_banco_r_por_ponto', NULL, NULL, 'R$/ponto', 'PENDENTE', 'contrato com o banco', 'Quanto o banco paga ao programa por ponto emitido'),
  ('custo_aereas_r_por_ponto', NULL, NULL, 'R$/ponto', 'PENDENTE', 'financeiro', 'Custo real para o programa de 1 ponto resgatado em aereas (enunciado: > preco do banco)'),
  ('custo_varejo_r_por_ponto', NULL, NULL, 'R$/ponto', 'PENDENTE', 'financeiro', 'Custo real de 1 ponto em varejo (enunciado: parceiros do grupo, mais vantajoso)')
]);

CREATE OR REPLACE VIEW pontua_dw.cfg AS
SELECT
  MAX(IF(chave='pix_launch_date',  SAFE_CAST(valor_texto AS DATE), NULL)) AS pix_launch_date,
  MAX(IF(chave='data_extracao',    SAFE_CAST(valor_texto AS DATE), NULL)) AS data_extracao,
  MAX(IF(chave='pix_taxa_anunciada', valor, NULL))                        AS pix_taxa_anunciada,
  1 / MAX(IF(chave='pix_pontos_por_real', valor, NULL))                   AS pix_taxa_53pts,
  MAX(IF(chave='meta_aereas_min',  valor, NULL))                          AS meta_aereas_min,
  MAX(IF(chave='meta_varejo_min',  valor, NULL))                          AS meta_varejo_min,
  MAX(IF(chave='meta_breakage_max',valor, NULL))                          AS meta_breakage_max,
  MAX(IF(chave='preco_banco_r_por_ponto',   valor, NULL))                 AS preco_banco_r_por_ponto,
  MAX(IF(chave='custo_aereas_r_por_ponto',  valor, NULL))                 AS custo_aereas_r_por_ponto,
  MAX(IF(chave='custo_varejo_r_por_ponto',  valor, NULL))                 AS custo_varejo_r_por_ponto
FROM pontua_dw.premissas;

-- =====================================================================
-- 1. STAGING
-- =====================================================================
-- orders.user_id vem NULL no extrato: recupera via carts
CREATE OR REPLACE VIEW pontua_stg.orders AS
SELECT o.order_id, CAST(o.cart_id AS STRING) AS cart_id,
       COALESCE(CAST(o.user_id AS STRING), CAST(c.user_id AS STRING)) AS user_id, c.channel,
       o.created_at, o.status AS order_status, o.status_updated_at
FROM brain003.orders o
LEFT JOIN (SELECT CAST(cart_id AS STRING) AS cart_id, ANY_VALUE(CAST(user_id AS STRING)) AS user_id, ANY_VALUE(channel) AS channel
           FROM brain003.carts GROUP BY 1) c ON CAST(o.cart_id AS STRING) = c.cart_id;

-- ledger com sinal garantido pela direcao (nao depende do sinal gravado)
CREATE OR REPLACE VIEW pontua_stg.ledger AS
SELECT l.movement_id, CAST(l.user_id AS STRING) AS user_id, l.account_id, l.operation_code,
       d.operation_name, d.direction,
       IF(d.direction='CREDIT', ABS(l.points), -ABS(l.points)) AS pontos_assinados,
       ABS(l.points) AS pontos_abs,
       l.movement_at, CAST(l.valid_until AS DATE) AS valid_until,
       l.operation_code IN (100,103) AS is_migracao
FROM brain003.points_ledger l
LEFT JOIN brain003.dim_operation d ON d.operation_code = l.operation_code;

-- RESERVA e CANCELADO_RESERVA se anulam; so RESGATE e resgate efetivo
CREATE OR REPLACE VIEW pontua_stg.resgate_por_item AS
SELECT order_item_id,
  IF(COUNT(DISTINCT IF(movement_type='RESGATE', account_id, NULL))=1, MAX(IF(movement_type='RESGATE', account_id, NULL)), NULL) AS account_id,
  COUNT(DISTINCT IF(movement_type='RESGATE', account_id, NULL)) AS n_contas_resgate,
  SUM(IF(movement_type='RESGATE', ABS(points), 0)) AS pts_resgatado,  -- soma: 1 item pode ser pago com pontos de 2 contas (confirmado: soma das linhas = paid_points)
  COUNTIF(movement_type='RESGATE') AS n_resgate_rows,
  SUM(IF(movement_type='RESERVA',          ABS(points),0)) AS pts_reservado,
  SUM(IF(movement_type='CANCELADO_RESERVA',ABS(points),0)) AS pts_reserva_cancelada
FROM brain003.redeemed_points GROUP BY order_item_id;

-- CRM. HIPOTESE a validar: control_group verdadeiro/'controle' = grupo de controle
CREATE OR REPLACE VIEW pontua_stg.crm AS
SELECT event_ts, CAST(user_id AS STRING) AS user_id, device_id, event_name, campaign_type, campaign_id,
  IFNULL(LOWER(CAST(control_group AS STRING)) IN ('true','1','controle','control'), FALSE) AS is_control,
  CASE event_name WHEN 'Notification Sent' THEN 'ENVIO' WHEN 'Notification Failed' THEN 'FALHA'
    WHEN 'Notification Viewed' THEN 'VISUALIZACAO' WHEN 'Push Impressions' THEN 'VISUALIZACAO'
    WHEN 'Notification Clicked' THEN 'CLIQUE' WHEN 'Order Approved' THEN 'CONVERSAO_CRM' END AS evento_tipo,
  CASE WHEN campaign_type = 'Facebook Audiences' THEN 'MIDIA_PAGA'
    WHEN campaign_type = 'Email' THEN 'EMAIL' WHEN campaign_type = 'InApp' THEN 'INAPP'
    WHEN campaign_type IN ('Push','Mobile Push - Android','Mobile Push - iOS') THEN 'PUSH' END AS canal_grupo,
  JSON_VALUE(event_properties, '$.audience') AS audience
FROM brain003.crm_events;

-- =====================================================================
-- 2. DW
-- =====================================================================
-- FATO: grao order_item (sem PARTITION BY: evita expiracao de particao)
CREATE OR REPLACE TABLE pontua_dw.fct_resgate_item
CLUSTER BY categoria, user_id
OPTIONS(description='Grao: order_item_id. Resgates com categoria (AEREAS/VAREJO/PIX/OUTROS). Volume resgatado = pts_liquidos com is_confirmado=TRUE. Datas em America/Sao_Paulo.') AS
SELECT
  oi.order_item_id, oi.order_id, o.user_id, r.account_id, o.channel, oi.created_at,
  DATE(oi.created_at,'America/Sao_Paulo') AS data_resgate,
  FORMAT_DATE('%Y-%m', DATE(oi.created_at,'America/Sao_Paulo')) AS mes,
  CASE WHEN oi.supplier_responsible = 'Pix Pontua+' THEN 'PIX'
       WHEN oi.category_macro = 'Aereas' THEN 'AEREAS'
       WHEN oi.category_macro = 'Varejo' THEN 'VAREJO'
       ELSE 'OUTROS' END AS categoria,
  CASE WHEN oi.supplier_responsible = 'Pix Pontua+' THEN 'PIX'
       WHEN oi.category_macro = 'Aereas' THEN 'AEREAS_PASSAGEM'
       WHEN oi.category_macro = 'Varejo' AND oi.product_type = 'PRODUTO' THEN 'VAREJO_PRODUTO'
       WHEN oi.category_macro = 'Varejo' AND oi.product_type = 'TRANSFERENCIA' THEN 'VAREJO_TRANSFERENCIA_PARCEIRO'
       ELSE 'OUTROS' END AS subcategoria,
  oi.product_type, oi.supplier_name, oi.supplier_responsible,
  oi.status AS item_status, o.order_status, oi.quantity,
  oi.paid_points AS pts_pedidos,
  IFNULL(r.pts_resgatado,0) AS pts_confirmados,
  IF(oi.status = 'ESTORNADO', 0, GREATEST(IFNULL(r.pts_resgatado,0) - IFNULL(oi.refunded_points,0), 0)) AS pts_liquidos,
  oi.status = 'ESTORNADO' OR IFNULL(oi.refunded_points,0) > 0 AS is_estornado,
  IFNULL(oi.refunded_points,0) AS pts_estornados,
  IFNULL(oi.paid_currency,0)   AS reais_pagos_cliente,
  oi.product_value             AS valor_produto_reais,
  oi.product_value - IFNULL(oi.paid_currency,0) AS reais_cobertos_por_pontos,
  SAFE_DIVIDE(oi.product_value - IFNULL(oi.paid_currency,0), oi.paid_points) AS taxa_r_por_ponto,
  IFNULL(r.pts_resgatado,0) > 0 AND IFNULL(oi.status,'') <> 'ESTORNADO' AS is_confirmado,
  IFNULL(r.pts_resgatado,0) > 0 AS is_resgate_bruto,
  IFNULL(r.n_contas_resgate,0) > 1 AS has_resgate_multiconta
FROM brain003.order_items oi
LEFT JOIN pontua_stg.orders o           ON o.order_id = oi.order_id
LEFT JOIN pontua_stg.resgate_por_item r ON r.order_item_id = oi.order_item_id
WHERE IFNULL(oi.product_type,'') <> 'COMPRA_PONTOS';  -- compra de pontos nao e resgate

-- Compra de pontos (Cashback / COMPRA_PONTOS): fora do mix de resgate e das metas
CREATE OR REPLACE TABLE pontua_dw.fct_compra_pontos
OPTIONS(description='Grao: order_item_id. Compras de pontos (product_type COMPRA_PONTOS); nao entram no volume resgatado nem nas metas.') AS
SELECT oi.order_item_id, oi.order_id, o.user_id, oi.created_at, oi.status AS item_status,
  oi.paid_points, oi.paid_currency, oi.product_value
FROM brain003.order_items oi LEFT JOIN pontua_stg.orders o ON o.order_id = oi.order_id
WHERE oi.product_type = 'COMPRA_PONTOS';

-- FATO: grao movimento (sem PARTITION BY: evita expiracao de particao)
CREATE OR REPLACE TABLE pontua_dw.fct_ledger
CLUSTER BY operation_name, user_id
OPTIONS(description='Grao: movement_id. pontos_assinados (+credito/-debito). Earn organico = operation_code 1; migracao = 100/103.') AS
SELECT movement_id, user_id, account_id, operation_code, operation_name, direction,
  pontos_assinados, pontos_abs, is_migracao, movement_at,
  DATE(movement_at,'America/Sao_Paulo') AS data_mov,
  FORMAT_DATE('%Y-%m', DATE(movement_at,'America/Sao_Paulo')) AS mes,
  valid_until, valid_until AS data_validade
FROM pontua_stg.ledger;

-- DIM: grao user_id
CREATE OR REPLACE TABLE pontua_dw.dim_user
OPTIONS(description='Grao: user_id. Cartao mais recente, saldo na vespera do Pix, primeiro resgate e primeiro Pix.') AS
WITH card AS (
  SELECT CAST(user_id AS STRING) AS user_id, account_id, card_class, card_flag, created_at AS cartao_criado_em
  FROM brain003.cards
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CAST(user_id AS STRING) ORDER BY is_most_recent DESC, created_at DESC)=1),
saldo AS (
  SELECT l.user_id,
    SUM(IF(l.movement_at < TIMESTAMP(c.pix_launch_date,'America/Sao_Paulo'), l.pontos_assinados, 0)) AS saldo_pre_pix
  FROM pontua_stg.ledger l CROSS JOIN pontua_dw.cfg c GROUP BY l.user_id),
res AS (
  SELECT user_id,
    MIN(IF(is_confirmado, created_at, NULL)) AS primeiro_resgate_em,
    MIN(IF(is_confirmado AND categoria='PIX', created_at, NULL)) AS primeiro_pix_em,
    SUM(IF(is_confirmado AND categoria='PIX', pts_liquidos, 0)) AS pts_pix_total
  FROM pontua_dw.fct_resgate_item GROUP BY user_id),
base AS (SELECT user_id FROM card UNION DISTINCT SELECT user_id FROM saldo)
SELECT b.user_id, c.account_id, c.card_class, c.card_flag, c.cartao_criado_em, s.saldo_pre_pix,
  CASE WHEN s.saldo_pre_pix IS NULL OR s.saldo_pre_pix<=0 THEN '0 sem saldo'
       WHEN s.saldo_pre_pix<5000 THEN '1 <5k' WHEN s.saldo_pre_pix<20000 THEN '2 5k-20k'
       WHEN s.saldo_pre_pix<50000 THEN '3 20k-50k' ELSE '4 50k+' END AS faixa_saldo_pre_pix,
  r.primeiro_resgate_em, r.primeiro_pix_em, r.primeiro_pix_em IS NOT NULL AS is_adotante_pix,
  IFNULL(r.pts_pix_total,0) AS pts_pix_total
FROM base b LEFT JOIN card c USING (user_id) LEFT JOIN saldo s USING (user_id) LEFT JOIN res r USING (user_id);

-- =====================================================================
-- 3. MARTS
-- =====================================================================
-- 3.1 KPI mensal: mix, metas, Pix, ledger
CREATE OR REPLACE TABLE pontua_mart.kpi_mensal
OPTIONS(description='Grao: mes (YYYY-MM). Pontos resgatados por categoria, % do mix (0-100), status das metas aereas>=50 e varejo>=20, Pix, earn/expiracao.') AS
WITH r AS (
  SELECT mes, SUM(pts_liquidos) AS pts_total,
    SUM(IF(categoria='AEREAS',pts_liquidos,0)) AS pts_aereas,
    SUM(IF(categoria='VAREJO',pts_liquidos,0)) AS pts_varejo,
    SUM(IF(categoria='PIX',   pts_liquidos,0)) AS pts_pix,
    SUM(IF(categoria='OUTROS',pts_liquidos,0)) AS pts_outros,
    COUNT(DISTINCT user_id) AS usuarios_resgatando,
    COUNT(DISTINCT IF(categoria='PIX',user_id,NULL)) AS usuarios_pix,
    COUNTIF(categoria='PIX') AS transacoes_pix,
    SUM(IF(categoria='PIX',reais_cobertos_por_pontos,0)) AS reais_pix
  FROM pontua_dw.fct_resgate_item WHERE is_confirmado GROUP BY mes),
l AS (
  SELECT mes,
    SUM(IF(operation_code=1,  pontos_abs,0)) AS pts_earn,
    SUM(IF(operation_code=2,  pontos_abs,0)) AS pts_resgate_ledger,
    SUM(IF(operation_code=3,  pontos_abs,0)) AS pts_expirados,
    SUM(IF(operation_code=103,pontos_abs,0)) AS pts_expirados_migracao,
    SUM(IF(operation_code=100,pontos_abs,0)) AS pts_credito_migracao
  FROM pontua_dw.fct_ledger GROUP BY mes)
SELECT r.mes, r.pts_total, r.pts_aereas, r.pts_varejo, r.pts_pix, r.pts_outros,
  100*SAFE_DIVIDE(r.pts_aereas,r.pts_total) AS pct_aereas,
  100*SAFE_DIVIDE(r.pts_varejo,r.pts_total) AS pct_varejo,
  100*SAFE_DIVIDE(r.pts_pix,   r.pts_total) AS pct_pix,
  100*SAFE_DIVIDE(r.pts_outros,r.pts_total) AS pct_outros,
  SAFE_DIVIDE(r.pts_aereas,r.pts_total) >= c.meta_aereas_min AS meta_aereas_ok,
  SAFE_DIVIDE(r.pts_varejo,r.pts_total) >= c.meta_varejo_min AS meta_varejo_ok,
  r.usuarios_resgatando, r.usuarios_pix, r.transacoes_pix, r.reais_pix,
  SAFE_DIVIDE(r.reais_pix, r.pts_pix) AS taxa_pix_r_por_ponto,
  l.pts_earn, l.pts_resgate_ledger, l.pts_expirados, l.pts_expirados_migracao, l.pts_credito_migracao
FROM r LEFT JOIN l USING (mes) CROSS JOIN pontua_dw.cfg c;

-- 3.2 Serie diaria do Pix + comunicacao previa (sem PARTITION BY)
CREATE OR REPLACE TABLE pontua_mart.kpi_diario_pix
OPTIONS(description='Grao: dia. Pix vs demais categorias, novos adotantes e quantos ja tinham recebido notificacao antes do 1o Pix.') AS
WITH envio AS (
  SELECT user_id, MIN(event_ts) AS primeiro_envio FROM pontua_stg.crm
  WHERE evento_tipo='ENVIO' AND canal_grupo IN ('EMAIL','PUSH','INAPP')
    AND DATE(event_ts,'America/Sao_Paulo') >= (SELECT DATE_SUB(pix_launch_date, INTERVAL 7 DAY) FROM pontua_dw.cfg)
  GROUP BY user_id),
dia AS (
  SELECT data_resgate AS data,
    SUM(IF(categoria='PIX',pts_liquidos,0)) AS pts_pix,
    SUM(IF(categoria='AEREAS',pts_liquidos,0)) AS pts_aereas,
    SUM(IF(categoria='VAREJO',pts_liquidos,0)) AS pts_varejo,
    COUNTIF(categoria='PIX') AS transacoes_pix
  FROM pontua_dw.fct_resgate_item WHERE is_confirmado GROUP BY data),
adot AS (
  SELECT DATE(u.primeiro_pix_em,'America/Sao_Paulo') AS data, COUNT(*) AS novos_adotantes,
    COUNTIF(e.primeiro_envio IS NOT NULL AND e.primeiro_envio < u.primeiro_pix_em) AS novos_com_envio_previo
  FROM pontua_dw.dim_user u LEFT JOIN envio e USING (user_id) WHERE u.is_adotante_pix GROUP BY data)
SELECT d.*, a.novos_adotantes, a.novos_com_envio_previo,
  DATE_DIFF(d.data, c.pix_launch_date, DAY) AS dias_desde_lancamento
FROM dia d LEFT JOIN adot a USING (data) CROSS JOIN pontua_dw.cfg c;

-- 3.3 Taxa efetiva do Pix (varias definicoes) - testa "R$0,016 vs R$0,019"
CREATE OR REPLACE TABLE pontua_mart.pix_taxa_efetiva
OPTIONS(description='Grao: mes. Taxa efetiva do Pix (R$/ponto) sob definicoes alternativas vs anunciada e vs relatorio do operador. taxa_confirmada = definicao principal.') AS
WITH x AS (
  SELECT mes, COUNT(*) AS tx_todas, COUNTIF(is_confirmado) AS tx_confirmadas,
    SUM(pts_pedidos) AS pts_pedidos,
    SUM(IF(is_confirmado,pts_confirmados,0)) AS pts_confirmados,
    SUM(IF(is_confirmado,pts_liquidos,0)) AS pts_liquidos,
    SUM(pts_estornados) AS pts_estornados,
    SUM(reais_cobertos_por_pontos) AS reais_todos,
    SUM(IF(is_confirmado,reais_cobertos_por_pontos,0)) AS reais_confirmados,
    AVG(IF(is_confirmado,taxa_r_por_ponto,NULL)) AS taxa_media_simples,
    SUM(IF(is_resgate_bruto,reais_cobertos_por_pontos,0)) AS reais_bruto,
    SUM(IF(is_resgate_bruto,pts_confirmados,0)) AS pts_bruto,
    APPROX_QUANTILES(IF(is_confirmado,taxa_r_por_ponto,NULL),100 IGNORE NULLS) AS q
  FROM pontua_dw.fct_resgate_item WHERE categoria='PIX' GROUP BY mes)
SELECT x.mes, tx_todas, tx_confirmadas, pts_pedidos, pts_confirmados, pts_liquidos, pts_estornados,
  reais_todos, reais_confirmados,
  SAFE_DIVIDE(reais_confirmados,pts_confirmados) AS taxa_confirmada,
  SAFE_DIVIDE(reais_todos,pts_pedidos)           AS taxa_todos_pedidos,
  SAFE_DIVIDE(reais_bruto,pts_bruto)             AS taxa_incluindo_estornos,
  SAFE_DIVIDE(reais_confirmados,pts_liquidos)    AS taxa_liquida_estornos,
  taxa_media_simples, q[OFFSET(10)] AS taxa_p10, q[OFFSET(50)] AS taxa_p50, q[OFFSET(90)] AS taxa_p90,
  c.pix_taxa_anunciada, c.pix_taxa_53pts,
  SAFE_DIVIDE(reais_confirmados,pts_confirmados) - c.pix_taxa_anunciada AS gap_vs_anunciada,
  SAFE_DIVIDE(rel.pix_reais, rel.pix_pontos) AS taxa_relatorio_operador,
  SAFE_DIVIDE(rel.pix_reais, rel.pix_pontos) - c.pix_taxa_anunciada AS gap_relatorio_vs_anunciada
FROM x CROSS JOIN pontua_dw.cfg c LEFT JOIN brain003.relatorio_mensal_cliente rel ON rel.mes = x.mes;

-- 3.4 Metas contratuais e folga do Pix
CREATE OR REPLACE TABLE pontua_mart.metas_contratuais
OPTIONS(description='Grao: mes. Gap das metas em p.p., pontos faltantes e folga maxima de Pix compativel (teto = 100 - meta aereas - meta varejo - pct outros).') AS
SELECT k.mes, k.pts_total, k.pct_aereas, k.pct_varejo, k.pct_pix, k.pct_outros,
  k.pct_aereas - 100*c.meta_aereas_min AS gap_aereas_pp,
  k.pct_varejo - 100*c.meta_varejo_min AS gap_varejo_pp,
  GREATEST(c.meta_varejo_min*k.pts_total - k.pts_varejo,0) AS pts_faltantes_varejo,
  GREATEST(c.meta_aereas_min*k.pts_total - k.pts_aereas,0) AS pts_faltantes_aereas,
  100*(1-c.meta_aereas_min-c.meta_varejo_min) - k.pct_outros AS teto_pix_pct_compativel,
  100*(1-c.meta_aereas_min-c.meta_varejo_min) - k.pct_outros - k.pct_pix AS folga_pix_pp,
  k.meta_aereas_ok, k.meta_varejo_ok
FROM pontua_mart.kpi_mensal k CROSS JOIN pontua_dw.cfg c;

-- 3.5 Custo unitario por categoria (premissa > proxy) e economia
-- origem_custo deixa explicito o que e dado, proxy ou premissa.
-- PROXY = valor entregue ao cliente por ponto (nao e custo contabil; para varejo
-- subestima/superestima a margem dos parceiros do grupo). Substituir ao preencher premissas.
CREATE OR REPLACE TABLE pontua_mart.economia_categoria
OPTIONS(description='Grao: mes x categoria. custo_r_por_ponto com origem_custo (DADO_TAXA_EFETIVA, PREMISSA ou PROXY_VALOR_ENTREGUE). contribuicao so existe se preco_banco foi informado. custo_menos_custo_pix independe do preco do banco.') AS
WITH m AS (
  SELECT mes, categoria, SUM(pts_liquidos) AS pts, SUM(reais_cobertos_por_pontos) AS reais_entregues,
         SUM(pts_confirmados) AS pts_conf
  FROM pontua_dw.fct_resgate_item WHERE is_confirmado GROUP BY 1,2),
v AS (
  SELECT m.*, SAFE_DIVIDE(reais_entregues, pts_conf) AS valor_entregue_r_por_ponto FROM m),
w AS (
  SELECT v.*, MAX(IF(categoria='PIX', valor_entregue_r_por_ponto, NULL)) OVER (PARTITION BY mes) AS custo_pix_mes FROM v)
SELECT w.mes, w.categoria, w.pts, w.reais_entregues, w.valor_entregue_r_por_ponto,
  CASE w.categoria WHEN 'PIX' THEN w.valor_entregue_r_por_ponto
       WHEN 'AEREAS' THEN COALESCE(c.custo_aereas_r_por_ponto, w.valor_entregue_r_por_ponto)
       WHEN 'VAREJO' THEN COALESCE(c.custo_varejo_r_por_ponto, w.valor_entregue_r_por_ponto) END AS custo_r_por_ponto,
  CASE WHEN w.categoria='PIX' THEN 'DADO_TAXA_EFETIVA'
       WHEN w.categoria='AEREAS' AND c.custo_aereas_r_por_ponto IS NOT NULL THEN 'PREMISSA'
       WHEN w.categoria='VAREJO' AND c.custo_varejo_r_por_ponto IS NOT NULL THEN 'PREMISSA'
       WHEN w.categoria IN ('AEREAS','VAREJO') THEN 'PROXY_VALOR_ENTREGUE'
       ELSE 'SEM_CUSTO' END AS origem_custo,
  c.preco_banco_r_por_ponto,
  c.preco_banco_r_por_ponto - CASE w.categoria WHEN 'PIX' THEN w.valor_entregue_r_por_ponto
       WHEN 'AEREAS' THEN COALESCE(c.custo_aereas_r_por_ponto, w.valor_entregue_r_por_ponto)
       WHEN 'VAREJO' THEN COALESCE(c.custo_varejo_r_por_ponto, w.valor_entregue_r_por_ponto) END AS contribuicao_r_por_ponto,
  CASE w.categoria WHEN 'AEREAS' THEN COALESCE(c.custo_aereas_r_por_ponto, w.valor_entregue_r_por_ponto)
       WHEN 'VAREJO' THEN COALESCE(c.custo_varejo_r_por_ponto, w.valor_entregue_r_por_ponto) END - w.custo_pix_mes AS custo_menos_custo_pix
FROM w CROSS JOIN pontua_dw.cfg c;

-- 3.6 Breakeven do Pix: nao depende do preco do banco
-- Pix so e lucrativo por ponto se preco_banco > custo_pix. Realocar 1 p.p. do volume
-- de X para Pix muda o custo em (custo_pix - custo_X) * 1% do volume.
CREATE OR REPLACE TABLE pontua_mart.pix_breakeven
OPTIONS(description='Grao: mes. preco_banco_breakeven_pix = custo do Pix por ponto. impacto_r_por_pp_* = variacao de custo ao realocar 1 p.p. do volume de aereas/varejo para Pix (positivo = Pix mais caro). Custos de aereas/varejo podem ser PROXY (ver origem_custo).') AS
WITH p AS (
  SELECT mes,
    MAX(IF(categoria='PIX',    custo_r_por_ponto,NULL)) AS custo_pix,
    MAX(IF(categoria='AEREAS', custo_r_por_ponto,NULL)) AS custo_aereas,
    MAX(IF(categoria='VAREJO', custo_r_por_ponto,NULL)) AS custo_varejo,
    MAX(IF(categoria='AEREAS', origem_custo,NULL))      AS origem_custo_aereas,
    MAX(IF(categoria='VAREJO', origem_custo,NULL))      AS origem_custo_varejo
  FROM pontua_mart.economia_categoria GROUP BY mes)
SELECT p.mes, p.custo_pix AS preco_banco_breakeven_pix,
  p.custo_aereas, p.custo_varejo, p.origem_custo_aereas, p.origem_custo_varejo,
  p.custo_pix - p.custo_aereas AS pix_menos_aereas_r_por_ponto,
  p.custo_pix - p.custo_varejo AS pix_menos_varejo_r_por_ponto,
  (p.custo_pix - p.custo_aereas) * 0.01 * k.pts_total AS impacto_r_por_pp_vindo_de_aereas,
  (p.custo_pix - p.custo_varejo) * 0.01 * k.pts_total AS impacto_r_por_pp_vindo_de_varejo,
  k.pts_total, c.preco_banco_r_por_ponto,
  c.preco_banco_r_por_ponto IS NOT NULL AND c.preco_banco_r_por_ponto > p.custo_pix AS pix_lucrativo_vs_preco_banco
FROM p JOIN pontua_mart.kpi_mensal k USING (mes) CROSS JOIN pontua_dw.cfg c;

-- 3.7 Cenarios em grade: share de Pix (0-40%) x preco do banco (R$0,008-0,022/ponto)
-- Base: ultimo mes fechado antes da extracao. Premissa: o Pix sai proporcionalmente das demais
-- categorias (calibrar com pix_canibalizacao). Outros e ignorado no custo (renormaliza aereas/varejo).
CREATE OR REPLACE TABLE pontua_mart.cenarios_pix
OPTIONS(description='Grao: pix_share_pct x preco_banco. Metas atendidas e resultado estimado (R$) do volume do ultimo mes fechado. Mostra o preco do banco a partir do qual o Pix compensa; nao assume um preco unico.') AS
WITH ref AS (
  SELECT k.* FROM pontua_mart.kpi_mensal k, pontua_dw.cfg c
  WHERE k.mes < FORMAT_DATE('%Y-%m', c.data_extracao)
  QUALIFY ROW_NUMBER() OVER (ORDER BY k.mes DESC)=1),
cst AS (
  SELECT MAX(IF(categoria='PIX',custo_r_por_ponto,NULL)) AS c_pix,
         MAX(IF(categoria='AEREAS',custo_r_por_ponto,NULL)) AS c_aer,
         MAX(IF(categoria='VAREJO',custo_r_por_ponto,NULL)) AS c_var,
         MAX(IF(categoria='AEREAS',origem_custo,NULL)) AS origem_custo_aereas
  FROM pontua_mart.economia_categoria WHERE mes = (SELECT mes FROM ref)),
g AS (
  SELECT s/100 AS sh, p/1000 AS preco
  FROM UNNEST(GENERATE_ARRAY(0,40,1)) s, UNNEST(GENERATE_ARRAY(8,22,1)) p)
SELECT ref.mes AS mes_base, g.sh*100 AS pix_share_pct, g.preco AS preco_banco_r_por_ponto,
  (1-g.sh)*100*SAFE_DIVIDE(ref.pts_aereas, ref.pts_total-ref.pts_pix) AS pct_aereas,
  (1-g.sh)*100*SAFE_DIVIDE(ref.pts_varejo, ref.pts_total-ref.pts_pix) AS pct_varejo,
  (1-g.sh)*SAFE_DIVIDE(ref.pts_aereas, ref.pts_total-ref.pts_pix) >= c.meta_aereas_min AS meta_aereas_ok,
  (1-g.sh)*SAFE_DIVIDE(ref.pts_varejo, ref.pts_total-ref.pts_pix) >= c.meta_varejo_min AS meta_varejo_ok,
  g.preco - ( g.sh*cst.c_pix + (1-g.sh)*( SAFE_DIVIDE(ref.pts_aereas, ref.pts_aereas+ref.pts_varejo)*cst.c_aer
                                        + SAFE_DIVIDE(ref.pts_varejo, ref.pts_aereas+ref.pts_varejo)*cst.c_var ) ) AS contribuicao_r_por_ponto,
  ref.pts_total * ( g.preco - ( g.sh*cst.c_pix + (1-g.sh)*( SAFE_DIVIDE(ref.pts_aereas, ref.pts_aereas+ref.pts_varejo)*cst.c_aer
                                        + SAFE_DIVIDE(ref.pts_varejo, ref.pts_aereas+ref.pts_varejo)*cst.c_var ) ) ) AS resultado_estimado_r,
  cst.origem_custo_aereas
FROM g CROSS JOIN ref CROSS JOIN cst CROSS JOIN pontua_dw.cfg c;

-- 3.8 Breakage: variantes lado a lado (reconcilia o "40%" vs meta 20%)
CREATE OR REPLACE TABLE pontua_mart.breakage_resumo
OPTIONS(description='Grao: 1 linha. breakage_verdadeiro_pct = expirado (op 3) / emitido de safras ja vencidas na data de extracao (op 1). saldo_nao_resgatado_pct = 1 - resgatado/emitido NAO e breakage. Migracao (100/103) tratada a parte.') AS
WITH l AS (
  SELECT
    SUM(IF(operation_code=1,pontos_abs,0)) AS earn,
    SUM(IF(operation_code=1 AND valid_until < c.data_extracao, pontos_abs,0)) AS earn_safras_vencidas,
    SUM(IF(operation_code=2,pontos_abs,0)) AS resgatado,
    SUM(IF(operation_code=3,pontos_abs,0)) AS expirado,
    SUM(IF(operation_code=100,pontos_abs,0)) AS credito_migracao,
    SUM(IF(operation_code=103,pontos_abs,0)) AS expirado_migracao,
    COUNTIF(operation_code=3) AS n_mov_expiracao_organica
  FROM pontua_dw.fct_ledger CROSS JOIN pontua_dw.cfg c)
SELECT earn, earn_safras_vencidas, resgatado, expirado, credito_migracao, expirado_migracao,
  100*SAFE_DIVIDE(expirado, earn_safras_vencidas)                        AS breakage_verdadeiro_pct,
  100*SAFE_DIVIDE(expirado_migracao, credito_migracao) AS breakage_migracao_pct, n_mov_expiracao_organica,
  100*SAFE_DIVIDE(expirado, earn)                                        AS expirado_sobre_emitido_total_pct,
  100*SAFE_DIVIDE(expirado+expirado_migracao, earn+credito_migracao)     AS expirado_com_migracao_pct,
  100*(1-SAFE_DIVIDE(resgatado, earn))                                   AS saldo_nao_resgatado_pct,
  100*SAFE_DIVIDE(expirado, expirado+resgatado)                          AS expirado_sobre_baixas_pct,
  100*c.meta_breakage_max AS meta_breakage_pct
FROM l CROSS JOIN pontua_dw.cfg c;

CREATE OR REPLACE TABLE pontua_mart.breakage_mensal
OPTIONS(description='Grao: mes do movimento. Emissao, resgate, expiracao e acumulados.') AS
WITH m AS (
  SELECT mes, SUM(IF(operation_code=1,pontos_abs,0)) AS earn, SUM(IF(operation_code=2,pontos_abs,0)) AS resgatado,
    SUM(IF(operation_code=3,pontos_abs,0)) AS expirado, SUM(IF(operation_code=103,pontos_abs,0)) AS expirado_migracao
  FROM pontua_dw.fct_ledger GROUP BY mes)
SELECT *, SUM(earn) OVER (ORDER BY mes) AS earn_acum, SUM(resgatado) OVER (ORDER BY mes) AS resgatado_acum,
  SUM(expirado) OVER (ORDER BY mes) AS expirado_acum,
  100*SAFE_DIVIDE(SUM(resgatado) OVER (ORDER BY mes), SUM(earn) OVER (ORDER BY mes)) AS pct_resgatado_acum
FROM m;

-- 3.9 CRM: NAO existe grupo de controle (control_group e NULL em 100% das linhas).
-- Analise OBSERVACIONAL: nivel maximo de exposicao (ENVIO < VISUALIZACAO < CLIQUE) vs nunca contatados,
-- estratificada por faixa de saldo pre-Pix (confundidor principal: saldo alto aumenta a chance de contato
-- e de resgate). MIDIA_PAGA (Facebook Audiences) fica fora: e segmentacao de midia, nao mensagem ao cliente.
CREATE OR REPLACE TABLE pontua_mart.crm_lift
OPTIONS(description='Grao: nivel_exposicao x canal_primeiro x faixa_saldo. Conversao para Pix em 7/14/30d apos o 1o contato (nunca contatados: apos o lancamento). Observacional, sem controle: nao prova causalidade.') AS
WITH c AS (SELECT * FROM pontua_dw.cfg),
ev AS (
  SELECT x.user_id, MIN(x.event_ts) AS ref_ts,
    MAX(CASE x.evento_tipo WHEN 'CLIQUE' THEN 3 WHEN 'VISUALIZACAO' THEN 2 WHEN 'ENVIO' THEN 1 END) AS nivel_num,
    ARRAY_AGG(x.canal_grupo ORDER BY x.event_ts LIMIT 1)[OFFSET(0)] AS canal_primeiro
  FROM pontua_stg.crm x, c
  WHERE x.evento_tipo IN ('ENVIO','VISUALIZACAO','CLIQUE') AND x.canal_grupo IN ('EMAIL','PUSH','INAPP')
    AND DATE(x.event_ts,'America/Sao_Paulo') >= DATE_SUB(c.pix_launch_date, INTERVAL 7 DAY)
  GROUP BY x.user_id),
pop AS (
  SELECT u.user_id, u.faixa_saldo_pre_pix AS faixa_saldo,
    CASE e.nivel_num WHEN 3 THEN '3 CLIQUE' WHEN 2 THEN '2 VISUALIZACAO' WHEN 1 THEN '1 ENVIO' ELSE '0 NUNCA_CONTATADO' END AS nivel_exposicao,
    IFNULL(e.canal_primeiro,'NENHUM') AS canal_primeiro,
    IFNULL(e.ref_ts, TIMESTAMP(c.pix_launch_date,'America/Sao_Paulo')) AS ref_ts,
    u.primeiro_pix_em
  FROM pontua_dw.dim_user u CROSS JOIN c LEFT JOIN ev e ON e.user_id = u.user_id)
SELECT nivel_exposicao, canal_primeiro, faixa_saldo, COUNT(*) AS usuarios,
  COUNTIF(primeiro_pix_em < ref_ts) AS pix_antes_do_contato,
  COUNTIF(primeiro_pix_em IS NULL OR primeiro_pix_em >= ref_ts) AS usuarios_em_risco,
  COUNTIF(primeiro_pix_em BETWEEN ref_ts AND TIMESTAMP_ADD(ref_ts, INTERVAL 7  DAY)) AS conv_7d,
  COUNTIF(primeiro_pix_em BETWEEN ref_ts AND TIMESTAMP_ADD(ref_ts, INTERVAL 14 DAY)) AS conv_14d,
  COUNTIF(primeiro_pix_em BETWEEN ref_ts AND TIMESTAMP_ADD(ref_ts, INTERVAL 30 DAY)) AS conv_30d,
  100*SAFE_DIVIDE(COUNTIF(primeiro_pix_em BETWEEN ref_ts AND TIMESTAMP_ADD(ref_ts, INTERVAL 30 DAY)),
                  COUNTIF(primeiro_pix_em IS NULL OR primeiro_pix_em >= ref_ts)) AS taxa_conv_30d_pct
FROM pop GROUP BY 1,2,3;

CREATE OR REPLACE VIEW pontua_mart.crm_lift_resumo AS
WITH a AS (
  SELECT nivel_exposicao, faixa_saldo, SUM(usuarios_em_risco) AS n, SUM(conv_30d) AS conv
  FROM pontua_mart.crm_lift GROUP BY 1,2)
SELECT a.nivel_exposicao, a.faixa_saldo, a.n AS usuarios_em_risco,
  100*SAFE_DIVIDE(a.conv,a.n) AS taxa_conv_30d_pct,
  100*SAFE_DIVIDE(b.conv,b.n) AS taxa_baseline_30d_pct,
  100*SAFE_DIVIDE(a.conv,a.n) - 100*SAFE_DIVIDE(b.conv,b.n) AS lift_observacional_pp
FROM a JOIN a b ON b.nivel_exposicao = '0 NUNCA_CONTATADO' AND b.faixa_saldo = a.faixa_saldo
WHERE a.nivel_exposicao <> '0 NUNCA_CONTATADO';

-- 3.10 Canibalizacao (janelas de 60 dias, adotantes observaveis ate a data de extracao)
CREATE OR REPLACE TABLE pontua_mart.pix_canibalizacao
OPTIONS(description='Grao: categoria nao-Pix. Pontos medios por adotante 60d antes vs 60d depois do 1o Pix. Sem grupo de nao-adotantes: e antes/depois, nao causal.') AS
WITH ad AS (
  SELECT u.user_id, u.primeiro_pix_em FROM pontua_dw.dim_user u CROSS JOIN pontua_dw.cfg c
  WHERE u.is_adotante_pix AND u.primeiro_pix_em <= TIMESTAMP_SUB(TIMESTAMP(c.data_extracao), INTERVAL 60 DAY)),
x AS (
  SELECT a.user_id, f.categoria,
    SUM(IF(f.created_at < a.primeiro_pix_em AND f.created_at >= TIMESTAMP_SUB(a.primeiro_pix_em, INTERVAL 60 DAY), f.pts_liquidos,0)) AS pts_antes,
    SUM(IF(f.created_at > a.primeiro_pix_em AND f.created_at <= TIMESTAMP_ADD(a.primeiro_pix_em, INTERVAL 60 DAY), f.pts_liquidos,0)) AS pts_depois
  FROM ad a JOIN pontua_dw.fct_resgate_item f USING (user_id)
  WHERE f.is_confirmado AND f.categoria IN ('AEREAS','VAREJO','OUTROS') GROUP BY 1,2)
SELECT categoria, COUNT(DISTINCT user_id) AS adotantes, AVG(pts_antes) AS pts_medios_antes, AVG(pts_depois) AS pts_medios_depois,
  100*SAFE_DIVIDE(AVG(pts_depois)-AVG(pts_antes), AVG(pts_antes)) AS variacao_pct
FROM x GROUP BY categoria;

-- 3.11 Reconciliacao relatorio x recalculo e perfil
CREATE OR REPLACE TABLE pontua_mart.reconciliacao_relatorio
OPTIONS(description='Grao: mes. Relatorio do operador vs recalculo a partir dos dados crus (mix, Pix pontos/reais/transacoes, taxa).') AS
SELECT r.mes,
  r.aereas_pct AS rel_aereas_pct, k.pct_aereas AS calc_aereas_pct, k.pct_aereas - r.aereas_pct AS dif_aereas_pp,
  r.varejo_pct AS rel_varejo_pct, k.pct_varejo AS calc_varejo_pct, k.pct_varejo - r.varejo_pct AS dif_varejo_pp,
  r.pix_pct AS rel_pix_pct, k.pct_pix AS calc_pix_pct, k.pct_pix - r.pix_pct AS dif_pix_pp,
  r.pix_pontos AS rel_pix_pontos, k.pts_pix AS calc_pix_pontos,
  r.pix_reais AS rel_pix_reais, k.reais_pix AS calc_pix_reais,
  r.pix_transacoes AS rel_pix_tx, k.transacoes_pix AS calc_pix_tx,
  SAFE_DIVIDE(r.pix_reais, r.pix_pontos) AS rel_taxa_pix, k.taxa_pix_r_por_ponto AS calc_taxa_pix
FROM brain003.relatorio_mensal_cliente r LEFT JOIN pontua_mart.kpi_mensal k USING (mes);

CREATE OR REPLACE TABLE pontua_mart.pix_perfil
OPTIONS(description='Grao: classe de cartao x bandeira x faixa de saldo pre-Pix. Penetracao do Pix.') AS
SELECT card_class, card_flag, faixa_saldo_pre_pix, COUNT(*) AS usuarios, COUNTIF(is_adotante_pix) AS adotantes_pix,
  100*SAFE_DIVIDE(COUNTIF(is_adotante_pix), COUNT(*)) AS penetracao_pix_pct, SUM(pts_pix_total) AS pts_pix
FROM pontua_dw.dim_user GROUP BY 1,2,3;

-- =====================================================================
-- 4. CAMADA DO AGENTE (descoberta de significado + regras)
-- Fluxo do agente: (1) table_catalog -> escolher tabela; (2) esquema -> entender colunas;
-- (3) premissas -> checar status; (4) regras_resposta -> aplicar ressalvas; (5) consultar so pontua_mart/pontua_dw.
-- =====================================================================
CREATE OR REPLACE TABLE pontua_ai.table_catalog AS
SELECT * FROM UNNEST([
  STRUCT('pontua_mart.kpi_mensal' AS tabela, 'mes' AS grao, 'Mix de resgate, metas, Pix, earn/expiracao' AS uso, 'Perguntas sobre volume e metas por mes' AS quando_usar),
  ('pontua_mart.metas_contratuais','mes','Gap das metas e folga do Pix','Estamos cumprindo aereas/varejo? Quanto de Pix cabe?'),
  ('pontua_mart.kpi_diario_pix','dia','Curva de adocao do Pix e comunicacao previa','O que aconteceu apos o lancamento?'),
  ('pontua_mart.pix_taxa_efetiva','mes','Taxa efetiva do Pix sob definicoes alternativas','Pix sai a 0,016 ou 0,019?'),
  ('pontua_mart.economia_categoria','mes x categoria','Custo por ponto com origem do custo','Qual categoria custa mais?'),
  ('pontua_mart.pix_breakeven','mes','Preco do banco de equilibrio e impacto por p.p. realocado','Vale estimular o Pix?'),
  ('pontua_mart.cenarios_pix','pix_share x preco_banco','Metas e resultado por cenario','E se o Pix for X% e o banco pagar Y?'),
  ('pontua_mart.breakage_resumo','1 linha','Variantes de breakage','O breakage esta em 40%?'),
  ('pontua_mart.breakage_mensal','mes','Emissao/resgate/expiracao','Evolucao de expiracao'),
  ('pontua_mart.crm_lift','nivel de exposicao x canal x faixa de saldo','Conversao para Pix por exposicao ao CRM (observacional)','A comunicacao explica o Pix?'),
  ('pontua_mart.crm_lift_resumo','nivel de exposicao x faixa de saldo','Diferenca vs nunca contatados (sem controle)','Quanto a exposicao ao CRM se associa ao Pix?'),
  ('pontua_mart.pix_canibalizacao','categoria','Antes/depois do 1o Pix','Pix tirou resgate de aereas/varejo?'),
  ('pontua_mart.reconciliacao_relatorio','mes','Relatorio do operador vs recalculo','O relatorio confere?'),
  ('pontua_mart.pix_perfil','segmento','Penetracao por cartao/bandeira/saldo','Quem usa Pix?'),
  ('pontua_mart.testes','teste','Resultado dos testes de qualidade','Os numeros sao confiaveis?'),
  ('pontua_dw.fct_resgate_item','order_item','Fato detalhado (filtrar is_confirmado)','Perguntas ad hoc'),
  ('pontua_dw.fct_ledger','movimento','Ledger com sinal','Perguntas ad hoc de saldo/expiracao'),
  ('pontua_dw.fct_compra_pontos','order_item','Compras de pontos (fora do resgate)','Perguntas sobre compra de pontos'),
  ('pontua_dw.premissas','chave','Parametros com status','Qualquer calculo que dependa de preco/custo')
]);

CREATE OR REPLACE TABLE pontua_ai.column_catalog AS
SELECT * FROM UNNEST([
  STRUCT('kpi_mensal' AS tabela, 'mes' AS coluna, 'Mes YYYY-MM (fuso America/Sao_Paulo)' AS descricao, 'texto' AS unidade),
  ('kpi_mensal','pts_total','Pontos resgatados liquidos de estorno, todas as categorias, so confirmados','pontos'),
  ('kpi_mensal','pct_aereas','% do volume resgatado em aereas (meta >= 50)','pct 0-100'),
  ('kpi_mensal','pct_varejo','% do volume resgatado em varejo (meta >= 20)','pct 0-100'),
  ('kpi_mensal','pct_pix','% do volume resgatado via Pix','pct 0-100'),
  ('kpi_mensal','pct_outros','% fora de aereas, varejo e Pix (esperado ~0; transferencias para parceiros estao em varejo)','pct 0-100'),
  ('kpi_mensal','meta_aereas_ok','TRUE se pct_aereas >= meta contratual','bool'),
  ('kpi_mensal','meta_varejo_ok','TRUE se pct_varejo >= meta contratual','bool'),
  ('kpi_mensal','reais_pix','R$ pagos em Pix (valor do produto menos moeda paga pelo cliente)','R$'),
  ('kpi_mensal','taxa_pix_r_por_ponto','reais_pix / pontos confirmados do Pix','R$/ponto'),
  ('kpi_mensal','pts_earn','Pontos emitidos (operation_code 1), sem migracao','pontos'),
  ('kpi_mensal','pts_expirados','Pontos expirados (operation_code 3), sem migracao','pontos'),
  ('pix_taxa_efetiva','taxa_confirmada','Definicao principal: R$ / pontos dos itens com RESGATE confirmado','R$/ponto'),
  ('pix_taxa_efetiva','taxa_relatorio_operador','pix_reais / pix_pontos do relatorio do operador','R$/ponto'),
  ('economia_categoria','origem_custo','DADO_TAXA_EFETIVA, PREMISSA ou PROXY_VALOR_ENTREGUE. PROXY nao e custo contabil','texto'),
  ('economia_categoria','custo_menos_custo_pix','custo da categoria menos custo do Pix; independe do preco do banco','R$/ponto'),
  ('pix_breakeven','preco_banco_breakeven_pix','Preco do banco acima do qual o Pix deixa de dar prejuizo por ponto','R$/ponto'),
  ('breakage_resumo','breakage_verdadeiro_pct','Expirado / emitido de safras ja vencidas na data de extracao','pct 0-100'),
  ('breakage_resumo','saldo_nao_resgatado_pct','1 - resgatado/emitido. NAO e breakage','pct 0-100'),
  ('crm_lift','nivel_exposicao','Maior exposicao do usuario: 1 ENVIO, 2 VISUALIZACAO, 3 CLIQUE ou 0 NUNCA_CONTATADO','texto'),
  ('crm_lift_resumo','lift_observacional_pp','Conversao 30d do nivel de exposicao menos nunca contatados, dentro da faixa de saldo. Associacao, nao causalidade','p.p.'),
  ('fct_resgate_item','is_confirmado','TRUE se existe movimento RESGATE em redeemed_points; filtrar sempre','bool'),
  ('fct_resgate_item','has_resgate_multiconta','TRUE se o resgate usou pontos de 2 contas (2 linhas RESGATE em redeemed_points); account_id fica NULL nesses itens','bool'),
  ('fct_resgate_item','pts_liquidos','Pontos confirmados menos refunded_points','pontos'),
  ('fct_resgate_item','categoria','AEREAS e VAREJO por category_macro; PIX por supplier_responsible = Pix Pontua+; OUTROS = resto','texto')
]);

-- Esquema pesquisavel pelo agente: tipo real (INFORMATION_SCHEMA) + descricao quando existir
CREATE OR REPLACE VIEW pontua_ai.esquema AS
SELECT c.table_schema AS dataset, c.table_name AS tabela, c.column_name AS coluna, c.data_type AS tipo,
       d.descricao, d.unidade
FROM (SELECT * FROM pontua_mart.INFORMATION_SCHEMA.COLUMNS
      UNION ALL SELECT * FROM pontua_dw.INFORMATION_SCHEMA.COLUMNS) c
LEFT JOIN pontua_ai.column_catalog d ON d.tabela = c.table_name AND d.coluna = c.column_name;

CREATE OR REPLACE TABLE pontua_ai.regras_resposta AS
SELECT * FROM UNNEST([
  STRUCT('RESSALVA' AS acao, 'custo/margem/lucro' AS gatilho, 'Se origem_custo = PROXY_VALOR_ENTREGUE ou preco_banco for NULL, informar que e estimativa e citar premissas pendentes. Nao afirmar lucro ou prejuizo absoluto.' AS regra),
  ('RESSALVA','causalidade do CRM','crm_events nao tem grupo de controle (control_group nulo em 100% das linhas). Nunca afirmar causalidade; descrever como associacao e citar o baseline NUNCA_CONTATADO e o confundidor saldo.'),
  ('RESSALVA','breakage','Informar qual definicao esta usando; distinguir breakage verdadeiro de saldo nao resgatado; lembrar que validade de 24 meses limita expiracao organica ate a data de extracao.'),
  ('RESSALVA','mes mais recente','Dados extraidos em 01/10/2026; nao ha dados de outubro. Nao projetar sem dizer.'),
  ('RECUSAR','dados individuais','Nao listar user_id, account_id ou dados de um cliente especifico; responder apenas agregado (minimo de 20 usuarios por grupo).'),
  ('RECUSAR','previsao e decisao','Nao prever resultado futuro como fato nem decidir pela diretoria; apresentar cenarios de pontua_mart.cenarios_pix com as premissas.'),
  ('RECUSAR','numero sem fonte','Nao responder metrica que nao esteja no catalogo; dizer que nao existe e qual dado faltaria.'),
  ('CONFERIR','toda resposta numerica','Citar tabela e mes usados; checar pontua_mart.testes antes de responder e avisar se houver teste ERRO falhando.')
]);

-- =====================================================================
-- 5. TESTES (um resultado por linha; ERRO = bug de modelo, ALERTA = achado de dados)
-- Consultar: SELECT * FROM pontua_mart.testes WHERE NOT ok;
-- =====================================================================
CREATE OR REPLACE VIEW pontua_mart.testes AS
SELECT 'grao_fct_resgate_item' AS teste, 'ERRO' AS severidade, COUNT(*)=COUNT(DISTINCT order_item_id) AS ok,
  CONCAT('linhas=',CAST(COUNT(*) AS STRING),' distintas=',CAST(COUNT(DISTINCT order_item_id) AS STRING)) AS detalhe FROM pontua_dw.fct_resgate_item
UNION ALL SELECT 'grao_fct_ledger','ERRO', COUNT(*)=COUNT(DISTINCT movement_id), CONCAT('linhas=',CAST(COUNT(*) AS STRING)) FROM pontua_dw.fct_ledger
UNION ALL SELECT 'grao_dim_user','ERRO', COUNT(*)=COUNT(DISTINCT user_id), CONCAT('linhas=',CAST(COUNT(*) AS STRING)) FROM pontua_dw.dim_user
UNION ALL SELECT 'raw_orders_order_id_unico','ERRO', COUNT(*)=COUNT(DISTINCT order_id), CONCAT('linhas=',CAST(COUNT(*) AS STRING)) FROM brain003.orders
UNION ALL SELECT 'raw_carts_um_usuario_por_cart','ERRO', COUNTIF(n>1)=0, CONCAT('carts_com_mais_de_um_usuario=',CAST(COUNTIF(n>1) AS STRING))
  FROM (SELECT cart_id, COUNT(DISTINCT user_id) AS n FROM brain003.carts GROUP BY cart_id)
UNION ALL SELECT 'itens_sem_pedido','ERRO', COUNT(*)=0, CONCAT('itens_orfaos=',CAST(COUNT(*) AS STRING))
  FROM brain003.order_items oi LEFT JOIN brain003.orders o ON o.order_id = oi.order_id WHERE o.order_id IS NULL
UNION ALL SELECT 'pedidos_sem_usuario_apos_carts','ALERTA', COUNTIF(user_id IS NULL)=0, CONCAT('itens_sem_user=',CAST(COUNTIF(user_id IS NULL) AS STRING)) FROM pontua_dw.fct_resgate_item
UNION ALL SELECT 'ledger_operacao_sem_direcao','ERRO', COUNTIF(direction IS NULL)=0, CONCAT('movimentos_sem_direcao=',CAST(COUNTIF(direction IS NULL) AS STRING)) FROM pontua_dw.fct_ledger
UNION ALL SELECT 'reserva_cancelada_nao_excede_reserva','ERRO', COUNTIF(pts_reserva_cancelada>pts_reservado)=0,
  CONCAT('itens=',CAST(COUNTIF(pts_reserva_cancelada>pts_reservado) AS STRING)) FROM pontua_stg.resgate_por_item
UNION ALL SELECT 'pontos_liquidos_nao_negativos','ERRO', COUNTIF(pts_liquidos<0)=0, CONCAT('linhas=',CAST(COUNTIF(pts_liquidos<0) AS STRING)) FROM pontua_dw.fct_resgate_item
UNION ALL SELECT 'mix_soma_100','ERRO', COUNTIF(ABS(pct_aereas+pct_varejo+pct_pix+pct_outros-100)>0.001)=0,
  CONCAT('meses_fora=',CAST(COUNTIF(ABS(pct_aereas+pct_varejo+pct_pix+pct_outros-100)>0.001) AS STRING)) FROM pontua_mart.kpi_mensal WHERE pts_total>0
UNION ALL SELECT 'kpi_total_igual_fato','ERRO',
  (SELECT SUM(pts_total) FROM pontua_mart.kpi_mensal) = (SELECT SUM(pts_liquidos) FROM pontua_dw.fct_resgate_item WHERE is_confirmado),
  'soma de pts_total do mart = soma do fato'
UNION ALL SELECT 'pix_so_apos_lancamento','ERRO',
  IFNULL(MIN(data_resgate) >= (SELECT pix_launch_date FROM pontua_dw.cfg), TRUE),
  CONCAT('primeiro_pix=',CAST(MIN(data_resgate) AS STRING)) FROM pontua_dw.fct_resgate_item WHERE categoria='PIX' AND is_confirmado
UNION ALL SELECT 'ledger_resgate_vs_fato_ate_1pct','ALERTA', IFNULL(MAX(d) <= 0.01, TRUE),
  CONCAT('max_dif_rel=',CAST(ROUND(IFNULL(MAX(d),0),4) AS STRING))
  FROM (SELECT ABS(SAFE_DIVIDE(l.p - f.p, f.p)) AS d
        FROM (SELECT mes, SUM(pontos_abs) AS p FROM pontua_dw.fct_ledger WHERE operation_code=2 GROUP BY mes) l
        JOIN (SELECT mes, SUM(pts_confirmados) AS p FROM pontua_dw.fct_resgate_item WHERE is_resgate_bruto GROUP BY mes) f USING (mes))
UNION ALL SELECT 'relatorio_vs_recalculo_mix_ate_1pp','ALERTA',
  IFNULL(MAX(GREATEST(ABS(dif_aereas_pp),ABS(dif_varejo_pp),ABS(dif_pix_pp))) <= 1, TRUE),
  CONCAT('max_dif_pp=',CAST(ROUND(MAX(GREATEST(ABS(dif_aereas_pp),ABS(dif_varejo_pp),ABS(dif_pix_pp))),2) AS STRING)) FROM pontua_mart.reconciliacao_relatorio
UNION ALL SELECT 'pix_identificado','ERRO', COUNTIF(categoria='PIX')>0, CONCAT('itens_pix=',CAST(COUNTIF(categoria='PIX') AS STRING)) FROM pontua_dw.fct_resgate_item
UNION ALL SELECT 'categoria_outros_vazia','ALERTA', COUNTIF(categoria='OUTROS')=0, CONCAT('itens_outros=',CAST(COUNTIF(categoria='OUTROS') AS STRING)) FROM pontua_dw.fct_resgate_item
UNION ALL SELECT 'redeemed_resgate_item_existe_em_order_items','ALERTA', COUNTIF(oi.order_item_id IS NULL)=0,
  CONCAT('itens_orfaos=',CAST(COUNTIF(oi.order_item_id IS NULL) AS STRING))
  FROM (SELECT DISTINCT order_item_id FROM brain003.redeemed_points WHERE movement_type='RESGATE') r
  LEFT JOIN brain003.order_items oi ON oi.order_item_id = r.order_item_id
UNION ALL SELECT 'ledger_op2_linhas_igual_itens_com_resgate','ALERTA',
  (SELECT COUNTIF(operation_code=2) FROM pontua_dw.fct_ledger) = (SELECT COUNTIF(is_resgate_bruto) FROM pontua_dw.fct_resgate_item),
  CONCAT('ledger=',CAST((SELECT COUNTIF(operation_code=2) FROM pontua_dw.fct_ledger) AS STRING),' fato=',CAST((SELECT COUNTIF(is_resgate_bruto) FROM pontua_dw.fct_resgate_item) AS STRING))
UNION ALL SELECT 'ledger_sem_expiracao_organica','ALERTA', COUNTIF(operation_code=3)>0, CONCAT('movimentos_op3=',CAST(COUNTIF(operation_code=3) AS STRING)) FROM pontua_dw.fct_ledger
UNION ALL SELECT 'crm_user_id_casa_com_dim_user','ALERTA', SAFE_DIVIDE(COUNTIF(u.user_id IS NOT NULL), COUNT(*)) > 0.5,
  CONCAT('pct_usuarios_crm_em_dim_user=',CAST(ROUND(100*SAFE_DIVIDE(COUNTIF(u.user_id IS NOT NULL), COUNT(*)),1) AS STRING))
  FROM (SELECT DISTINCT user_id FROM pontua_stg.crm WHERE user_id IS NOT NULL) c
  LEFT JOIN pontua_dw.dim_user u ON u.user_id = c.user_id
UNION ALL SELECT 'resgate_soma_bate_com_paid_points','ERRO', COUNTIF(pts_confirmados <> pts_pedidos)=0,
  CONCAT('itens_divergentes=',CAST(COUNTIF(pts_confirmados <> pts_pedidos) AS STRING),' de ',CAST(COUNT(*) AS STRING))
  FROM pontua_dw.fct_resgate_item WHERE is_resgate_bruto
UNION ALL SELECT 'crm_tem_grupo_controle','ALERTA', COUNTIF(is_control)>0, CONCAT('eventos_controle=',CAST(COUNTIF(is_control) AS STRING)) FROM pontua_stg.crm
UNION ALL SELECT 'premissas_pendentes','ALERTA', COUNTIF(status='PENDENTE' AND valor IS NULL)=0,
  CONCAT('pendentes=',CAST(COUNTIF(status='PENDENTE' AND valor IS NULL) AS STRING)) FROM pontua_dw.premissas
UNION ALL SELECT 'tabelas_mart_catalogadas','ERRO', COUNTIF(c.tabela IS NULL)=0,
  CONCAT('sem_catalogo=',CAST(COUNTIF(c.tabela IS NULL) AS STRING))
  FROM (SELECT table_name FROM pontua_mart.INFORMATION_SCHEMA.TABLES) t
  LEFT JOIN pontua_ai.table_catalog c ON c.tabela = CONCAT('pontua_mart.', t.table_name)
UNION ALL SELECT 'colunas_chave_documentadas','ALERTA', COUNTIF(descricao IS NULL)=0,
  CONCAT('colunas_sem_descricao=',CAST(COUNTIF(descricao IS NULL) AS STRING))
  FROM pontua_ai.esquema WHERE tabela IN ('kpi_mensal','fct_resgate_item')
-- ---- Testes de cobertura (v4): pegam corte por expiracao/carga parcial ----
UNION ALL SELECT 'cobertura_ledger_vs_bruto','ERRO',
  (SELECT COUNT(*) FROM pontua_dw.fct_ledger) = (SELECT COUNT(*) FROM brain003.points_ledger),
  CONCAT('fato=',CAST((SELECT COUNT(*) FROM pontua_dw.fct_ledger) AS STRING),' bruto=',CAST((SELECT COUNT(*) FROM brain003.points_ledger) AS STRING))
UNION ALL SELECT 'cobertura_itens_vs_bruto','ERRO',
  (SELECT COUNT(*) FROM pontua_dw.fct_resgate_item) + (SELECT COUNT(*) FROM pontua_dw.fct_compra_pontos) = (SELECT COUNT(*) FROM brain003.order_items),
  CONCAT('fatos=',CAST((SELECT COUNT(*) FROM pontua_dw.fct_resgate_item) + (SELECT COUNT(*) FROM pontua_dw.fct_compra_pontos) AS STRING),' bruto=',CAST((SELECT COUNT(*) FROM brain003.order_items) AS STRING))
UNION ALL SELECT 'cobertura_data_minima_ledger','ERRO',
  (SELECT MIN(data_mov) FROM pontua_dw.fct_ledger) = (SELECT MIN(DATE(movement_at,'America/Sao_Paulo')) FROM brain003.points_ledger),
  CONCAT('fato_min=',CAST((SELECT MIN(data_mov) FROM pontua_dw.fct_ledger) AS STRING),' bruto_min=',CAST((SELECT MIN(DATE(movement_at,'America/Sao_Paulo')) FROM brain003.points_ledger) AS STRING))
UNION ALL SELECT 'cobertura_meses_kpi','ERRO',
  (SELECT COUNT(*) FROM pontua_mart.kpi_mensal) >= 12,
  CONCAT('meses_no_kpi=',CAST((SELECT COUNT(*) FROM pontua_mart.kpi_mensal) AS STRING))
UNION ALL SELECT 'tabelas_sem_expiracao','ERRO',
  (SELECT COUNT(*) FROM (
     SELECT 1 FROM pontua_dw.INFORMATION_SCHEMA.TABLE_OPTIONS WHERE option_name IN ('expiration_timestamp','partition_expiration_days') AND option_value NOT IN ('NULL','null')
     UNION ALL SELECT 1 FROM pontua_mart.INFORMATION_SCHEMA.TABLE_OPTIONS WHERE option_name IN ('expiration_timestamp','partition_expiration_days') AND option_value NOT IN ('NULL','null')
     UNION ALL SELECT 1 FROM pontua_ai.INFORMATION_SCHEMA.TABLE_OPTIONS WHERE option_name IN ('expiration_timestamp','partition_expiration_days') AND option_value NOT IN ('NULL','null'))) = 0,
  'tabelas com expiracao configurada em pontua_dw/pontua_mart/pontua_ai';
