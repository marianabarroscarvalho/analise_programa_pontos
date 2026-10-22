# Case Analytics Engineer · Brain003   
  
Exercício 1. Programa Pontua+

> Todos os dados, nomes e números deste case são fictícios e foram gerados para o processo seletivo.
> Versão dos dados: **v1**. O arquivo `MANIFESTO_v1.csv` lista os 9 CSVs com contagens de linhas e impressão digital (SHA-256).

## O contexto

O **Pontua+** é o programa de pontos dos cartões de crédito do Banco Aurora. Quem usa o cartão acumula pontos e troca por passagens aéreas, produtos de varejo ou transferências para programas parceiros. O programa é operado por uma empresa do grupo, que presta contas ao banco todo mês com um relatório (`relatorio_mensal_cliente.csv`).

Em **27/05/2026** o programa lançou o **Pontos no Pix**: o cliente troca pontos por dinheiro na conta, a R$ 0,019 por ponto. Cada 53 pontos equivael a aproximadamente R$1. O resgate nessa modalidade disparou.

O contrato com o banco tem duas metas sobre o total de pontos resgatados: trocas por passagens **aéreas devem ser pelo menos 50%** do volume de pontos trocados e **varejo pelo menos 20%**.   
  
Passagens aéreas custam mais caro ao programa do que o banco paga por ponto, sendo assim, mais desvantajoso para o programa (como empresa) e o varejo é onde o grupo tem parceiros próprios, (sendo mais vantajoso)

A diretoria vai decidir na semana que vem qual ação tomar para estimular ou coibir o resgate via Pix.  
  
Antes, quer entender o que aconteceu. E também se vale a pena estimular ou coibir o resgate tendo em vista as metas de aéreas e varejo e a própria saúde financeira do programa.  
Ela também ouviu duas afirmações e quer saber se são verdade:

- do time de CRM: "a comunicação de lançamento explica o sucesso do Pix";
- do relatório do operador: "Na verdade o Pix sai a cerca de R$ 0,016 por ponto, abaixo dos R$ 0,019 anunciados".
- De um diretor: “nosso breakage está em 40%! Nossa meta é não passar de 20%!"

## A descoberta faz parte do exercício

Não fornecemos um dicionário de dados. Explore os arquivos para identificar tipos, campos vazios, grãos, chaves, relacionamentos e regras relevantes para a análise. Documente esse entendimento no `README`, incluindo as evidências que sustentam suas escolhas.

Registre as hipóteses utilizadas e as perguntas que faria aos responsáveis pelos sistemas ou pelo negócio. Diferencie o que foi confirmado nos dados do que depende de validação adicional. Quando uma informação não puder ser estabelecida com os arquivos disponíveis, explique a limitação e o que precisaria para avançar. Hipóteses alternativas fundamentadas serão consideradas na avaliação.

## O que pedimos

Tempo de trabalho: **4 horas**. 

**O que pedimos**

1. O que aconteceu com os resgates depois do Pix e o que isso significa para as metas e para o programa.
2. Avalie as três afirmações.
3. Uma recomendação de uma página para a diretoria.
4. **Dashboard estratégico.** A diretoria vai acompanhar as principais métricas do programa por um dashboard. Monte o dashboard e a estrutura de dados por trás dele para responder às principais perguntas de negócio da diretoria. Os mesmos dados também serão consumidos por um agente de IA: desenhe uma estrutura que atenda aos dois (dashboard e agente) e justifique suas escolhas (camadas, grão, métricas, nomes, documentação, como o agente descobre o que cada campo significa).
5. **Opcional, se sobrar tempo:** desenvolva o agente que responde perguntas da diretoria sobre esses dados. Veja *Chave de LLM para o agente* abaixo.

**Regras da entrega**

- Os dados não vêm com dicionário. Entender os arquivos faz parte do exercício.
- Todos os números precisam sair de código executável (SQL e/ou Python, dbt opcional), com o grão de cada modelo declarado e **testes que garantam que os números estão certos.**
- No README, **separe o que foi confirmado nos dados do que é hipótese e liste o que você perguntaria ao negócio ou aos donos dos sistemas.**
- Tempo sugerido: 4 horas. Informe quanto tempo levou. Se não terminar, entregue o que rodou e diga como seguiria.
- Pode (DEVE) usar IA. Queremos ver como você usa e o que você confere.

## O que entregar

Quatro peças em formato zip ou em um git (cinco, se fizer o agente).

1. **Apresentação para a diretoria.** Mostra o que aconteceu, avalia as três afirmações e termina com a sua recomendação. Cada ponto da recomendação precisa trazer o número que o sustenta e dizer o que ainda falta saber. A apresentação será usada na devolutiva.
2. **Código e testes.** Todos os números da apresentação saem daqui, com SQL e/ou Python (dbt é opcional).
3. **README.** Precisa permitir que um avaliador reconstrua tudo a partir dos CSVs, sem editar nada à mão. Nele também ficam o que você entendeu dos dados, como modelou, as hipóteses que assumiu, o que perguntaria ao negócio ou aos donos dos sistemas e um registro breve do uso de IA (o que você pediu e o que conferiu ou corrigiu, subagentes e/ou skills que utilizou).
4. **Dashboard e estrutura de dados.** O dashboard (link acessível aos avaliadores, arquivo ou instruções para subir localmente), os modelos que o alimentam e a justificativa da estrutura para dashboard e agente. Ferramenta livre.
5. **Agente (opcional).** Código, instruções para rodar e exemplos de perguntas e respostas, incluindo pelo menos uma pergunta que ele deveria se recusar a responder ou responder com ressalva.

## Chave de LLM para o agente

Você não precisa gastar dinheiro com o agente.

- Durante o desenvolvimento, use a chave e o provedor que preferir. Sugestão: a camada gratuita da API do Gemini, com chave criada em https://aistudio.google.com/apikey usando qualquer conta Google. Ela basta para o volume deste case. Outros provedores com cota gratuita ou um modelo local (Ollama ou similar) também servem.
- **Na avaliação, vamos publicar o seu projeto em produção (por exemplo, no Vercel) e rodar o agente com a nossa chave do Gemini.** Por isso:
  - o agente precisa funcionar com o Gemini, mesmo que você tenha desenvolvido com outro provedor;
  - a chave deve ser lida de variável de ambiente, e o nome dela deve estar documentado no README;
  - o README deve trazer um único comando ou passo a passo curto para subir o dashboard e o agente.
- Guarde a chave em `.env` (já está no `.gitignore`). **Nunca faça commit de chave.**

## Como enviar

Envie um arquivo `.zip` com a solução ou um link para um repositório acessível aos avaliadores (@brain-yurikaminski, @brain-leonardo-andrade)pelo mesmo canal em que recebeu o case. O prazo de entrega é o alinhado entre vc e o recrutador. Inclua as respostas, o código, os testes e o `README`. Se a execução depender dos CSVs fornecidos, documente onde colocá-los.

Registre as dúvidas e eventuais esclarecimentos recebidos no `README`.

## Como vamos avaliar

Vamos avaliar análise e engenharia com o mesmo peso. Importa a qualidade do raciocínio, das evidências e do julgamento, não a quantidade de coisas entregues. Escolhas diferentes de ferramenta, arquitetura ou interpretação são bem-vindas quando fundamentadas. Na devolutiva, você vai defender suas escolhas, inclusive as que fez com ajuda de IA.

## Os dados (`dados/`)

Nove arquivos CSV separados por vírgula, com cabeçalho e codificação UTF-8. Os valores monetários estão em reais (R$). Datas e horas mantêm os formatos dos sistemas de origem; identifique e documente como você as interpreta nas análises.


| Arquivo                        | Finalidade geral                                          | Colunas                                                                                                                                                                              |
| ------------------------------ | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `orders.csv`                   | Registros do sistema de pedidos                           | order_id, cart_id, user_id, created_at, status, status_updated_at                                                                                                                    |
| `order_items.csv`              | Produtos e valores associados aos pedidos                 | order_item_id, order_id, created_at, status, product_type, supplier_name, supplier_responsible, category_macro, paid_points, paid_currency, product_value, refunded_points, quantity |
| `carts.csv`                    | Carrinhos e canais de compra                              | cart_id, user_id, channel                                                                                                                                                            |
| `points_ledger.csv`            | Movimentações do saldo de pontos                          | movement_id, user_id, account_id, operation_code, points, movement_at, valid_until                                                                                                   |
| `dim_operation.csv`            | Cadastro de tipos de movimentação                         | operation_code, operation_name, direction                                                                                                                                            |
| `cards.csv`                    | Cadastros relacionados aos cartões                        | account_id, user_id, card_class, card_flag, created_at, is_most_recent                                                                                                               |
| `redeemed_points.csv`          | Registros de movimentação de pontos associados às compras | order_item_id, account_id, movement_type, points                                                                                                                                     |
| `crm_events.csv`               | Exportação da ferramenta de engajamento                   | event_ts, user_id, device_id, event_name, campaign_type, campaign_id, control_group, event_properties (JSON)                                                                         |
| `relatorio_mensal_cliente.csv` | Relatório do operador ao banco                            | mes, aereas_pct, varejo_pct, pix_pct, pix_reais, pix_pontos, pix_transacoes, emails_enviados, push_enviados                                                                          |


O que o time de dados sabe e te conta:

- O Pontua+ substituiu um programa anterior; os saldos antigos foram migrados para o sistema novo.
- Os níveis de cartão, do mais simples ao mais alto: Essencial, Gold, Platinum, Platinum Elo, Infinite, Black.
- A ferramenta de CRM e o sistema de pedidos são sistemas diferentes e não compartilham configuração.
- Os dados foram extraídos em 01/10/2026.


## Registro do processo (obrigatório)

**Commits e pushes.** Trabalhe na branch `entrega` e faça push ao fim de cada sessão de trabalho. O GitHub registra a hora de cada push no servidor. Ao terminar, abra um Pull Request de `entrega` para `main`: a abertura do PR marca a entrega.

**Uso de IA em `AI_LOG.md`.**
- Se usar um agente que lê `AGENTS.md` ou `CLAUDE.md` (Claude Code, Cursor, Codex, Copilot e similares), ele registra cada sessão automaticamente. Confira o que foi escrito.
- Se usar IA em chat (ChatGPT, Claude.ai, Gemini etc.), ao fim de cada conversa cole o prompt abaixo e acrescente a resposta ao final de `AI_LOG.md`:

```
Resuma esta conversa para um registro de uso de IA, em português, neste formato:
### <data e hora> · <ferramenta e modelo>
- **Pedido:** o que eu pedi, em 1 a 3 linhas.
- **O que a IA fez ou sugeriu:** resumo factual.
- **O que eu conferi, corrigi ou rejeitei:** inclusive erros seus que eu apontei.
- **Arquivos criados ou alterados:** caminhos, se houver.
Seja factual. Não invente nada que não esteja na conversa.
```

Links de compartilhamento ou exportações das conversas (por exemplo, `/export` no Claude Code) são bem-vindos em `ai-log/`.
