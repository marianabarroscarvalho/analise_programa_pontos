"""Dashboard estratégico Pontua+ (Streamlit + Plotly) sobre as camadas pontua_dw / pontua_mart.

Todas as consultas agregam no BigQuery (nenhum SELECT * / tabela inteira em memória) e são
cacheadas por 1 h. Premissas ainda pendentes (preço do banco, custos) são parâmetros editáveis.
"""
import os
from pathlib import Path

import pandas as pd
import plotly.graph_objects as go
import streamlit as st
from dotenv import load_dotenv
from google.cloud import bigquery

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")
PROJECT = os.getenv("GCP_PROJECT_ID", "stoked-outlook-303718")
_creds = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
if _creds and not Path(_creds).is_absolute():
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str((BASE_DIR / _creds).resolve())

DW, MART = f"`{PROJECT}.pontua_dw", f"`{PROJECT}.pontua_mart"
LANCAMENTO_PIX = "2026-05-27"
META_AEREAS, META_VAREJO, META_BREAKAGE = 50.0, 20.0, 20.0
OPERADOR_CLAIM = 0.0166  # R$/ponto citado no relatório (mai/26: 0,0166; set/26: 0,0154)
CLAIM_DIRETOR = 40.0
COR = {"AEREAS": "#2a6fdb", "VAREJO": "#e8833a", "PIX": "#2ca58d", "META": "#8a8f98", "ALERTA": "#c0392b"}
st.set_page_config(page_title="Pontua+ · Pontos no Pix", layout="wide")


# ----------------------------------------------------------------------------- formatação pt-BR
def _fmt(x: float, d: int) -> str:
    return f"{x:,.{d}f}".replace(",", "X").replace(".", ",").replace("X", ".")


def n0(x) -> str:
    return "n/d" if pd.isna(x) else _fmt(x, 0)


def pct(x, d: int = 1) -> str:
    return "n/d" if pd.isna(x) else _fmt(x, d) + "%"


def pp(x: float, suf: str) -> str:
    return f"{'+' if x >= 0 else '-'}{_fmt(abs(x), 1)} p.p. {suf}"


def brl(x, d: int = 2) -> str:
    return "n/d" if pd.isna(x) else ("-R$ " + _fmt(-x, d) if x < 0 else "R$ " + _fmt(x, d))


def md(texto: str) -> str:
    """Escapa o cifrão para o markdown do Streamlit não tratar 'R$ ... R$' como fórmula."""
    return texto.replace("$", "\\$")


def style(fig: go.Figure, h: int = 380) -> go.Figure:
    fig.update_layout(height=h, separators=",.", margin=dict(l=10, r=10, t=50, b=70),
                      legend=dict(orientation="h", y=-0.18, x=0), hovermode="x unified",
                      title=dict(x=0, xanchor="left", font=dict(size=15)))
    return fig


def marca_lancamento(fig: go.Figure, x: str) -> None:
    fig.add_shape(type="line", x0=x, x1=x, y0=0, y1=1, yref="paper", line=dict(dash="dot", color=COR["META"]))
    fig.add_annotation(x=x, y=1, yref="paper", text="Lançamento Pix", showarrow=False, yshift=12,
                       font=dict(size=11, color=COR["META"]))


# ----------------------------------------------------------------------------- acesso a dados
@st.cache_resource
def client() -> bigquery.Client:
    return bigquery.Client(project=PROJECT)


def _run(sql: str, **params) -> pd.DataFrame:
    types = {str: "STRING", bool: "BOOL", int: "INT64"}
    qp = [bigquery.ScalarQueryParameter(k, "DATE" if k.startswith("d_") else types[type(v)], v)
          for k, v in params.items()]
    return client().query(sql, job_config=bigquery.QueryJobConfig(query_parameters=qp)).result().to_dataframe()


@st.cache_data(ttl=3600)
def q_meses() -> list[str]:
    return _run(f"select mes from {MART}.kpi_mensal` order by mes")["mes"].tolist()


@st.cache_data(ttl=3600)
def q_kpi_mensal(ini: str, fim: str) -> pd.DataFrame:
    return _run(f"""select mes, pts_total, pts_aereas, pts_varejo, pts_pix, pct_aereas, pct_varejo, pct_pix,
        usuarios_resgatando, usuarios_pix, transacoes_pix, reais_pix, pts_earn, pts_resgate_ledger
        from {MART}.kpi_mensal` where mes between @ini and @fim order by mes""", ini=ini, fim=fim)


@st.cache_data(ttl=3600)
def q_metas(ini: str, fim: str) -> pd.DataFrame:
    return _run(f"""select mes, gap_aereas_pp, gap_varejo_pp, pts_faltantes_varejo, teto_pix_pct_compativel,
        folga_pix_pp, meta_aereas_ok, meta_varejo_ok from {MART}.metas_contratuais`
        where mes between @ini and @fim order by mes""", ini=ini, fim=fim)


@st.cache_data(ttl=3600)
def q_pix_diario(d_ini: str, d_fim: str) -> pd.DataFrame:
    return _run(f"""with r as (select data_resgate as data, sum(reais_cobertos_por_pontos) as reais
          from {DW}.fct_resgate_item` where categoria = 'PIX' and is_confirmado
          and data_resgate between @d_ini and @d_fim group by 1)
        select d.data, d.pts_pix, d.transacoes_pix, d.novos_adotantes, d.novos_com_envio_previo,
               coalesce(r.reais, 0) as reais
        from {MART}.kpi_diario_pix` d left join r on r.data = d.data
        where d.data between @d_ini and @d_fim order by d.data""", d_ini=d_ini, d_fim=d_fim)


@st.cache_data(ttl=3600)
def q_taxa(ini: str, fim: str) -> pd.DataFrame:
    return _run(f"""select mes, tx_todas, tx_confirmadas, pts_pedidos, pts_confirmados, reais_confirmados,
        taxa_confirmada, taxa_p10, taxa_p50, taxa_p90, pix_taxa_anunciada, taxa_relatorio_operador,
        safe_divide(reais_confirmados, pts_pedidos) as taxa_reproduzida
        from {MART}.pix_taxa_efetiva` where tx_todas > 0 and mes between @ini and @fim order by mes""",
                ini=ini, fim=fim)


@st.cache_data(ttl=3600)
def q_breakage_resumo() -> pd.DataFrame:
    return _run(f"""select earn, resgatado, credito_migracao, expirado, expirado_migracao,
        breakage_verdadeiro_pct, breakage_migracao_pct, expirado_com_migracao_pct, saldo_nao_resgatado_pct,
        n_mov_expiracao_organica from {MART}.breakage_resumo`""")


@st.cache_data(ttl=3600)
def q_breakage_mensal(ini: str, fim: str) -> pd.DataFrame:
    return _run(f"""select mes, earn, resgatado, expirado_migracao, pct_resgatado_acum
        from {MART}.breakage_mensal` where mes between @ini and @fim order by mes""", ini=ini, fim=fim)


@st.cache_data(ttl=3600)
def q_validade_organica() -> pd.DataFrame:
    return _run(f"""select min(data_validade) as primeira_validade, count(*) as creditos_organicos
        from {DW}.fct_ledger` where operation_code = 1 and not is_migracao""")


@st.cache_data(ttl=3600)
def q_baseline(excluir_jan: bool) -> pd.DataFrame:
    return _run(f"""select sum(pts_aereas) as aereas, sum(pts_varejo) as varejo, sum(pts_total) as total
        from {MART}.kpi_mensal` where mes < '2026-05' and (not @excluir or mes != '2026-01')""",
                excluir=excluir_jan)


@st.cache_data(ttl=3600)
def q_crm_nivel() -> pd.DataFrame:
    return _run(f"""select nivel_exposicao, sum(usuarios) as usuarios, sum(usuarios_em_risco) as em_risco,
        sum(conv_30d) as conv_30d, safe_divide(100 * sum(conv_30d), sum(usuarios_em_risco)) as taxa_30d_pct
        from {MART}.crm_lift` group by 1 order by 1""")


@st.cache_data(ttl=3600)
def q_crm_saldo() -> pd.DataFrame:
    return _run(f"""select nivel_exposicao, faixa_saldo, usuarios_em_risco, taxa_conv_30d_pct
        from {MART}.crm_lift_resumo` order by 1, 2""")


@st.cache_data(ttl=3600)
def q_perfil() -> pd.DataFrame:
    return _run(f"""select card_class, sum(usuarios) as usuarios, sum(adotantes_pix) as adotantes_pix,
        safe_divide(100 * sum(adotantes_pix), sum(usuarios)) as penetracao_pct, sum(pts_pix) as pts_pix
        from {MART}.pix_perfil` group by 1 order by penetracao_pct desc""")


@st.cache_data(ttl=3600)
def q_testes() -> pd.DataFrame:
    return _run(f"select severidade, teste, detalhe from {MART}.testes` where not ok order by 1, 2")


# ----------------------------------------------------------------------------- sidebar
meses = q_meses()
st.sidebar.title("Filtros")
ini, fim = st.sidebar.select_slider("Período (mês)", options=meses, value=(meses[0], meses[-1]))
cats = st.sidebar.multiselect("Categorias (gráficos de volume)", ["AEREAS", "VAREJO", "PIX"],
                              default=["AEREAS", "VAREJO", "PIX"])

st.sidebar.title("Premissas do simulador")
st.sidebar.caption("Preço do banco e custos por categoria estão PENDENTES (financeiro/contrato). "
                   "Os valores abaixo são hipóteses editáveis, não dados confirmados.")
preco = st.sidebar.number_input("Preço Banco (R$/ponto)", 0.0, 0.1, 0.025, 0.001, format="%.4f",
                                help="Hipótese de trabalho. Quanto o banco paga ao programa por ponto.")
custo_a = st.sidebar.number_input("Custo Aéreas (R$/ponto)", 0.0, 0.1, 0.0150, 0.0005, format="%.4f",
                                  help="Proxy: valor entregue por ponto (economia_categoria).")
custo_v = st.sidebar.number_input("Custo Varejo (R$/ponto)", 0.0, 0.1, 0.0138, 0.0005, format="%.4f",
                                  help="Proxy: valor entregue por ponto (economia_categoria).")
taxa_pix = st.sidebar.number_input("Taxa Pix (R$/ponto)", 0.0, 0.1, 0.0190, 0.0005, format="%.4f",
                                   help="Observada: R$ 0,019 em todos os percentis (pix_taxa_efetiva).")
subst = st.sidebar.slider("Substituição pelo Pix (%)", 0, 100, 100, 5,
                          help="Parcela do volume Pix que seria resgatada em aéreas/varejo sem o Pix. "
                               "0% = Pix 100% incremental; 100% = pior caso de canibalização.") / 100
excluir_jan = st.sidebar.checkbox("Excluir jan/26 do mix pré-Pix", True,
                                  help="Jan/26 tem pico atípico de aéreas (96,8%, 88 mi de pontos).")

kpi = q_kpi_mensal(ini, fim)
metas = q_metas(ini, fim)

st.title("Pontua+ · O que mudou com o Pontos no Pix")
st.caption(f"Fonte: BigQuery `{PROJECT}` (pontua_dw / pontua_mart). Dados extraídos em 01/10/2026. "
           f"Período: {ini} a {fim}.")
falhas = q_testes()
if (falhas["severidade"] == "ERRO").any():
    with st.expander("Atenção: testes de qualidade com ERRO no mart", expanded=False):
        st.dataframe(falhas, hide_index=True, width="stretch")

abas = st.tabs(["1 · Executiva e metas", "2 · Auditoria do Pix", "3 · Breakage", "4 · Simulador Pix",
                "5 · CRM e causalidade"])

# ----------------------------------------------------------------------------- 1. executiva
with abas[0]:
    if kpi.empty:
        st.warning("Sem dados no período.")
        st.stop()
    ult, ant = kpi.iloc[-1], (kpi.iloc[-2] if len(kpi) > 1 else None)
    st.subheader(f"Mês de referência: {ult['mes']}")
    c = st.columns(4)
    var_vol = None if ant is None or not ant["pts_total"] else (
        f"{'+' if ult['pts_total'] >= ant['pts_total'] else '-'}"
        f"{_fmt(abs(ult['pts_total'] / ant['pts_total'] - 1) * 100, 1)}% vs mês anterior")
    c[0].metric("Pontos resgatados", n0(ult["pts_total"]), var_vol)
    c[1].metric(f"Mix Aéreas (meta ≥ {META_AEREAS:.0f}%)", pct(ult["pct_aereas"]),
                pp(ult["pct_aereas"] - META_AEREAS, "vs meta"),
                delta_color="normal")
    c[2].metric(f"Mix Varejo (meta ≥ {META_VAREJO:.0f}%)", pct(ult["pct_varejo"]),
                pp(ult["pct_varejo"] - META_VAREJO, "vs meta"),
                delta_color="normal")
    c[3].metric("Mix Pix", pct(ult["pct_pix"]),
                None if ant is None else pp(ult["pct_pix"] - ant["pct_pix"], "vs mês anterior"),
                delta_color="off")
    m = metas[metas["mes"] == ult["mes"]]
    if not m.empty and m.iloc[0]["pts_faltantes_varejo"] > 0:
        st.error(f"Varejo abaixo da meta: faltaram {n0(m.iloc[0]['pts_faltantes_varejo'])} pontos "
                 f"({_fmt(abs(m.iloc[0]['gap_varejo_pp']), 1)} p.p.) para os 20%.")
    elif not m.empty:
        st.success("Metas de aéreas e varejo cumpridas no mês de referência.")

    esq, dir_ = st.columns(2)
    fig = go.Figure()
    for k, col in [("AEREAS", "pct_aereas"), ("VAREJO", "pct_varejo"), ("PIX", "pct_pix")]:
        fig.add_bar(x=kpi["mes"], y=kpi[col], name=k.title(), marker_color=COR[k],
                    hovertemplate="%{y:,.1f}%")
    fig.update_layout(barmode="stack", title="Mix mensal de pontos resgatados (%)")
    fig.add_hline(y=META_AEREAS, line_dash="dash", line_color=COR["AEREAS"], annotation_text="Meta aéreas 50%")
    fig.add_hline(y=META_VAREJO, line_dash="dash", line_color=COR["VAREJO"], annotation_text="Meta varejo 20%")
    if ini <= "2026-05" <= fim:
        marca_lancamento(fig, "2026-05")
    esq.plotly_chart(style(fig), width="stretch")

    fig = go.Figure()
    for k, col in [("AEREAS", "pts_aereas"), ("VAREJO", "pts_varejo"), ("PIX", "pts_pix")]:
        if k in cats:
            fig.add_bar(x=kpi["mes"], y=kpi[col], name=k.title(), marker_color=COR[k],
                        hovertemplate="%{y:,.0f} pts")
    fig.update_layout(barmode="stack", title="Volume absoluto de pontos por categoria")
    if ini <= "2026-05" <= fim:
        marca_lancamento(fig, "2026-05")
    dir_.plotly_chart(style(fig), width="stretch")
    st.caption("O Pix adicionou volume sem reduzir os pontos absolutos de aéreas e varejo: "
               "a queda do varejo no mix vem em grande parte da diluição pelo denominador maior.")

    st.subheader("Drill-down mensal")
    t = kpi.merge(metas[["mes", "gap_aereas_pp", "gap_varejo_pp", "folga_pix_pp"]], on="mes")
    st.dataframe(t, hide_index=True, width="stretch", column_config={
        "mes": "Mês", "pts_total": st.column_config.NumberColumn("Pontos total", format="%d"),
        "pts_aereas": st.column_config.NumberColumn("Pts aéreas", format="%d"),
        "pts_varejo": st.column_config.NumberColumn("Pts varejo", format="%d"),
        "pts_pix": st.column_config.NumberColumn("Pts Pix", format="%d"),
        "pct_aereas": st.column_config.NumberColumn("% aéreas", format="%.1f"),
        "pct_varejo": st.column_config.NumberColumn("% varejo", format="%.1f"),
        "pct_pix": st.column_config.NumberColumn("% Pix", format="%.1f"),
        "gap_aereas_pp": st.column_config.NumberColumn("Gap aéreas (p.p.)", format="%.1f"),
        "gap_varejo_pp": st.column_config.NumberColumn("Gap varejo (p.p.)", format="%.1f"),
        "folga_pix_pp": st.column_config.NumberColumn("Folga Pix (p.p.)", format="%.1f"),
        "reais_pix": st.column_config.NumberColumn("R$ Pix", format="%.2f")})

# ----------------------------------------------------------------------------- 2. auditoria Pix
with abas[1]:
    d_ini = max(pd.Timestamp(f"{ini}-01"), pd.Timestamp(LANCAMENTO_PIX))
    d_fim = pd.Period(fim, "M").end_time.normalize()
    if d_ini > d_fim:
        st.info("Selecione um período que inclua datas após 27/05/2026.")
    else:
        dia = q_pix_diario(str(d_ini.date()), str(d_fim.date()))
        total_pts, total_reais = dia["pts_pix"].sum(), dia["reais"].sum()
        c = st.columns(4)
        c[0].metric("Pontos em Pix (período)", n0(total_pts))
        c[1].metric("Reais entregues (confirmados)", brl(total_reais, 0))
        c[2].metric(md("Taxa efetiva (anunciada R$ 0,0190)"), brl(total_reais / total_pts, 4) if total_pts else "n/d")
        c[3].metric("Transações Pix", n0(dia["transacoes_pix"].sum()))

        fig = go.Figure()
        fig.add_bar(x=dia["data"], y=dia["pts_pix"], name="Pontos em Pix", marker_color=COR["PIX"],
                    hovertemplate="%{y:,.0f} pts")
        fig.add_scatter(x=dia["data"], y=dia["reais"], name="Reais entregues", yaxis="y2",
                        line=dict(color=COR["ALERTA"], width=1.5), hovertemplate="R$ %{y:,.0f}")
        fig.update_layout(title="Pix por dia desde o lançamento (27/05/2026)",
                          yaxis=dict(title="Pontos", rangemode="tozero"),
                          yaxis2=dict(title="R$", overlaying="y", side="right", rangemode="tozero", showgrid=False),
                          xaxis=dict(tickformat="%d/%m"))
        marca_lancamento(fig, LANCAMENTO_PIX)
        st.plotly_chart(style(fig, 400), width="stretch")

        taxa = q_taxa(ini, fim)
        if not taxa.empty:
            fig = go.Figure()
            fig.add_scatter(x=taxa["mes"], y=taxa["taxa_p90"], line=dict(width=0), showlegend=False,
                            hoverinfo="skip")
            fig.add_scatter(x=taxa["mes"], y=taxa["taxa_p10"], fill="tonexty", name="Observada p10–p90",
                            line=dict(width=0), fillcolor="rgba(44,165,141,0.35)", hoverinfo="skip")
            fig.add_scatter(x=taxa["mes"], y=taxa["taxa_confirmada"], name="Observada (confirmados)",
                            mode="lines+markers", line=dict(color=COR["PIX"]), hovertemplate="R$ %{y:,.4f}")
            fig.add_scatter(x=taxa["mes"], y=taxa["pix_taxa_anunciada"], name="Anunciada", mode="lines",
                            line=dict(color=COR["META"], dash="dash"), hovertemplate="R$ %{y:,.4f}")
            fig.add_scatter(x=taxa["mes"], y=taxa["taxa_relatorio_operador"], name="Relatório do operador",
                            mode="lines+markers", line=dict(color=COR["ALERTA"]), hovertemplate="R$ %{y:,.4f}")
            fig.update_layout(title="Taxa do Pix (R$/ponto): observada vs relatório do operador",
                              yaxis=dict(tickformat=",.4f", range=[0.014, 0.0205]), xaxis=dict(type="category"))
            st.plotly_chart(style(fig, 400), width="stretch")

            ult_t = taxa.iloc[-1]
            gap = (ult_t["pix_taxa_anunciada"] - ult_t["taxa_relatorio_operador"]) * ult_t["pts_confirmados"]
            st.info(md(
                f"**Por que o relatório mostra ~R$ 0,016?** Em {ult_t['mes']}, reais confirmados "
                f"({brl(ult_t['reais_confirmados'], 0)}) ÷ pontos **pedidos** ({n0(ult_t['pts_pedidos'])}, incluindo "
                f"{n0(ult_t['pts_pedidos'] - ult_t['pts_confirmados'])} pontos de pedidos não confirmados) = "
                f"{brl(ult_t['taxa_reproduzida'], 4)}, próximo do {brl(ult_t['taxa_relatorio_operador'], 4)} do operador. "
                f"Dividindo pelos pontos **confirmados** a taxa é {brl(ult_t['taxa_confirmada'], 4)}. "
                f"Se a taxa do operador fosse real, o custo estaria superestimado em ~{brl(gap, 0)} no mês."))
            st.dataframe(taxa[["mes", "tx_todas", "tx_confirmadas", "pts_pedidos", "pts_confirmados",
                               "reais_confirmados", "taxa_confirmada", "taxa_relatorio_operador",
                               "taxa_reproduzida"]], hide_index=True, width="stretch", column_config={
                "taxa_confirmada": st.column_config.NumberColumn(format="%.4f"),
                "taxa_relatorio_operador": st.column_config.NumberColumn(format="%.4f"),
                "taxa_reproduzida": st.column_config.NumberColumn("Reais conf. ÷ pts pedidos", format="%.4f"),
                "reais_confirmados": st.column_config.NumberColumn(format="%.2f")})

        st.subheader("Quem adota o Pix")
        perfil = q_perfil()
        st.dataframe(perfil, hide_index=True, width="stretch", column_config={
            "penetracao_pct": st.column_config.NumberColumn("Penetração (%)", format="%.1f")})

# ----------------------------------------------------------------------------- 3. breakage
with abas[2]:
    br = q_breakage_resumo().iloc[0]
    val = q_validade_organica().iloc[0]
    apurados = [("Meta contratual (máx.)", META_BREAKAGE, COR["META"]),
                ("Alegação do diretor", CLAIM_DIRETOR, COR["ALERTA"]),
                ("Breakage de migração apurado", br["breakage_migracao_pct"], COR["PIX"]),
                ("Expirado (incl. migração) / emitido", br["expirado_com_migracao_pct"], COR["AEREAS"]),
                ("Saldo não resgatado (NÃO é breakage)", br["saldo_nao_resgatado_pct"], COR["VAREJO"])]
    fig = go.Figure(go.Bar(x=[a[1] for a in apurados], y=[a[0] for a in apurados], orientation="h",
                           marker_color=[a[2] for a in apurados],
                           text=[pct(a[1]) for a in apurados], textposition="outside",
                           hovertemplate="%{y}: %{x:,.1f}%<extra></extra>"))
    fig.update_layout(title="Breakage: meta vs alegação vs apurado (janela completa out/25–set/26)",
                      xaxis=dict(range=[0, 48], title="%"), yaxis=dict(autorange="reversed"), hovermode="closest")
    st.plotly_chart(style(fig, 360), width="stretch")
    c = st.columns(3)
    c[0].metric(f"Breakage verdadeiro ({int(br['n_mov_expiracao_organica'])} expirações orgânicas)", "n/d")
    c[1].metric(f"Expirado de migração (de {n0(br['credito_migracao'])} migrados)", n0(br["expirado_migracao"]))
    c[2].metric(f"1º vencimento orgânico possível ({n0(val['creditos_organicos'])} créditos)",
                str(val["primeira_validade"]))
    st.warning(
        "**Os 40% não aparecem em nenhuma definição calculada.** Como a validade é de 24 meses e o primeiro "
        f"crédito orgânico vence em {val['primeira_validade']}, depois da extração (01/10/2026), ainda não houve "
        "expiração orgânica: o breakage verdadeiro não é mensurável hoje. O número mais próximo da meta é o de "
        f"migração ({pct(br['breakage_migracao_pct'])}), que não se compara à meta de 20% sem alinhar a definição. "
        f"O saldo não resgatado ({pct(br['saldo_nao_resgatado_pct'])}) não é breakage: ainda pode ser resgatado.")
    bm = q_breakage_mensal(ini, fim)
    fig = go.Figure()
    fig.add_bar(x=bm["mes"], y=bm["earn"], name="Emitido (earn)", marker_color=COR["AEREAS"],
                hovertemplate="%{y:,.0f}")
    fig.add_bar(x=bm["mes"], y=bm["resgatado"], name="Resgatado", marker_color=COR["PIX"],
                hovertemplate="%{y:,.0f}")
    fig.add_bar(x=bm["mes"], y=bm["expirado_migracao"], name="Expirado (migração)", marker_color=COR["ALERTA"],
                hovertemplate="%{y:,.0f}")
    fig.add_scatter(x=bm["mes"], y=bm["pct_resgatado_acum"], name="% resgatado acumulado", yaxis="y2",
                    line=dict(color=COR["META"]), hovertemplate="%{y:,.1f}%")
    fig.update_layout(barmode="group", title="Emissão, resgate e expiração por mês (pontos)",
                      yaxis2=dict(overlaying="y", side="right", title="%", range=[0, 100]))
    st.plotly_chart(style(fig, 400), width="stretch")
    st.dataframe(bm, hide_index=True, width="stretch")

# ----------------------------------------------------------------------------- 4. simulador
with abas[3]:
    com_pix = kpi[kpi["pts_pix"] > 0]
    base = q_baseline(excluir_jan).iloc[0]
    if com_pix.empty or not base["total"]:
        st.info("Selecione um período com Pix (a partir de mai/2026) para simular.")
    else:
        ref = com_pix.iloc[-1]
        a0, v0 = base["aereas"] / (base["aereas"] + base["varejo"]), base["varejo"] / (base["aereas"] + base["varejo"])
        c_mix = a0 * custo_a + v0 * custo_v
        pa, pv, px = ref["pts_aereas"], ref["pts_varejo"], ref["pts_pix"]

        def delta_margem(p: float, s: float) -> float:
            """Margem com Pix menos margem sem Pix (mês de referência), em R$."""
            return px * ((p - taxa_pix) - s * (p - c_mix))

        d = delta_margem(preco, subst)
        st.caption(f"Mês de referência: **{ref['mes']}** · mix pré-Pix usado: {pct(a0 * 100)} aéreas / "
                   f"{pct(v0 * 100)} varejo · volume Pix: {n0(px)} pontos.")
        c = st.columns(4)
        c[0].metric("Contribuição aéreas (R$/pt)", brl(preco - custo_a, 4))
        c[1].metric("Contribuição varejo (R$/pt)", brl(preco - custo_v, 4))
        c[2].metric("Contribuição Pix (R$/pt)", brl(preco - taxa_pix, 4))
        c[3].metric(f"Δ margem mensal com Pix (subst. {subst * 100:.0f}%)", brl(d, 0))

        if d >= 0:
            st.success(md(f"Com estas premissas, o Pix **agrega** {brl(d, 0)}/mês ao programa."))
        else:
            st.error(md(f"Com estas premissas, o Pix **consome** {brl(-d, 0)}/mês de margem."))
        if subst < 1:
            p_star = (taxa_pix - subst * c_mix) / (1 - subst)
            st.write(md(f"Preço do banco de equilíbrio com {subst * 100:.0f}% de substituição: **{brl(p_star, 4)}** por ponto "
                        "(acima disso, o Pix agrega margem)."))
        else:
            st.write(md(f"Com 100% de substituição o resultado independe do preço do banco: Pix custa "
                        f"{brl(taxa_pix, 4)} vs {brl(c_mix, 4)} do mix aéreas/varejo pré-Pix, "
                        f"diferença de {brl(taxa_pix - c_mix, 4)} por ponto."))

        precos = [round(0.010 + 0.002 * i, 3) for i in range(11)]
        subs = [i / 10 for i in range(11)]
        z = [[delta_margem(p, s) for s in subs] for p in precos]
        fig = go.Figure(go.Heatmap(z=z, x=[f"{s * 100:.0f}%" for s in subs], y=[f"{p:.3f}" for p in precos],
                                   colorscale="RdBu", zmid=0, colorbar=dict(title="R$/mês"),
                                   hovertemplate="Substituição %{x}<br>Preço banco R$ %{y}<br>Δ margem R$ %{z:,.0f}<extra></extra>"))
        fig.update_layout(title="Sensibilidade: Δ margem mensal do Pix (preço do banco × substituição)",
                          xaxis=dict(title="Substituição pelo Pix", type="category"),
                          yaxis=dict(title="Preço do banco (R$/ponto)", type="category"),
                          hovermode="closest")
        e, dr = st.columns(2)
        e.plotly_chart(style(fig, 420), width="stretch")

        # mix observado vs contrafactual com a substituição escolhida
        cf_total = pa + pv + subst * px
        cf_a, cf_v = (pa + subst * px * a0) / cf_total * 100, (pv + subst * px * v0) / cf_total * 100
        fig = go.Figure()
        fig.add_bar(x=["Observado (com Pix)", f"Sem Pix ({subst * 100:.0f}% subst.)"],
                    y=[ref["pct_aereas"], cf_a], name="Aéreas", marker_color=COR["AEREAS"], hovertemplate="%{y:,.1f}%")
        fig.add_bar(x=["Observado (com Pix)", f"Sem Pix ({subst * 100:.0f}% subst.)"],
                    y=[ref["pct_varejo"], cf_v], name="Varejo", marker_color=COR["VAREJO"], hovertemplate="%{y:,.1f}%")
        fig.add_hline(y=META_AEREAS, line_dash="dash", line_color=COR["AEREAS"], annotation_text="Meta aéreas 50%")
        fig.add_hline(y=META_VAREJO, line_dash="dash", line_color=COR["VAREJO"], annotation_text="Meta varejo 20%")
        fig.update_layout(barmode="group", title="Metas: com Pix vs cenário sem Pix")
        dr.plotly_chart(style(fig, 420), width="stretch")
        st.caption(
            f"Varejo sem Pix: {pct(cf_v)} (meta 20%). Se o varejo já ficaria abaixo da meta sem o Pix, "
            "o Pix não é a única causa do descumprimento. Custos de aéreas e varejo são PROXY (valor entregue "
            "por ponto), o preço do banco é hipótese: use o resultado como direção, não como valor contábil.")

# ----------------------------------------------------------------------------- 5. CRM
with abas[4]:
    st.warning("**Sem grupo de controle:** `control_group` é nulo em 100% dos eventos de CRM. Os números abaixo "
               "mostram **associação**, não causalidade. Quase toda a base foi contatada, então não existe "
               "baseline confiável de quem nunca recebeu comunicação.")
    nivel = q_crm_nivel()
    esq, dir_ = st.columns(2)
    fig = go.Figure(go.Bar(x=[f"{n}<br>(n={int(e):,})".replace(",", ".") for n, e in zip(nivel["nivel_exposicao"], nivel["em_risco"])],
                           y=nivel["taxa_30d_pct"], marker_color=COR["AEREAS"],
                           text=[pct(v) for v in nivel["taxa_30d_pct"]], textposition="outside",
                           hovertemplate="%{x}<br>%{y:,.2f}% convertem em 30 d<extra></extra>"))
    fig.update_layout(title="Conversão para Pix em 30 dias por exposição ao CRM", yaxis_title="%", hovermode="closest")
    esq.plotly_chart(style(fig, 380), width="stretch")

    saldo = q_crm_saldo()
    fig = go.Figure()
    for (lvl, g), cor in zip(saldo.groupby("nivel_exposicao"), ["#9db8e8", "#2a6fdb", "#12356e"]):
        fig.add_bar(x=g["faixa_saldo"], y=g["taxa_conv_30d_pct"], name=lvl, marker_color=cor,
                    hovertemplate="%{y:,.2f}%")
    fig.update_layout(barmode="group", title="Conversão 30 d por faixa de saldo (confundidor)", yaxis_title="%")
    dir_.plotly_chart(style(fig, 380), width="stretch")
    st.caption("A conversão sobe com o saldo em todos os níveis de exposição: saldo é um confundidor, pois "
               "quem tem mais pontos tende a resgatar mais, receba ou não a comunicação.")

    d_ini2 = pd.Timestamp(LANCAMENTO_PIX)
    dia = q_pix_diario(str(d_ini2.date()), str(pd.Period(meses[-1], "M").end_time.date()))
    ad, ev = dia["novos_adotantes"].sum(), dia["novos_com_envio_previo"].sum()
    c = st.columns(3)
    c[0].metric("Adotantes do Pix", n0(ad))
    c[1].metric(f"Com envio de CRM antes da adoção ({pct(100 * ev / ad) if ad else 'n/d'})", n0(ev))
    c[2].metric("Sem envio prévio", n0(ad - ev))
    st.dataframe(nivel, hide_index=True, width="stretch", column_config={
        "taxa_30d_pct": st.column_config.NumberColumn("Conversão 30 d (%)", format="%.2f")})
    st.caption("Quase todos os adotantes receberam envio antes, mas quase toda a base também recebeu. "
               "Isso é compatível com 'CRM explica o Pix' e com 'o Pix teria crescido de qualquer forma'. "
               "Para decidir, é preciso um grupo de controle ou um teste A/B.")
