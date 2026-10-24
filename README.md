# Desafio Nível 2 — Gestão de Negociações e Aprovação Comercial

Solução ponta a ponta em Salesforce (LWC • Apex • Trigger • Record-Triggered Flow • Screen Flow • FlexiPage • Testes)
para o desafio **Treinamento Salesforce — Nível 2** (US-01 a US-07).

Jornada: `Opportunity → Simulador LWC → Negociação + Itens → Aprovação (Flow) → Decisão (Screen Flow) → FlexiPage → Order + OrderItems`.


## 1. Pré-requisitos

- Salesforce CLI (`sf`) e VS Code com *Salesforce Extension Pack*.
- Uma **Developer Edition / Sandbox / Scratch Org** com **Orders habilitado** (Setup → *Order Settings* → *Enable Orders*).
  A scratch org definida em `config/project-scratch-def.json` já habilita.
- Produtos e Pricebook standard com entradas ativas (o script `scripts/apex/seed-demo.apex` cria dados de demonstração).

## 2. Deploy

```bash
# org já autenticada (exemplo: alias "minha_nova_org")
sf project deploy start --source-dir force-app --target-org minha_nova_org

# rodar todos os testes e ver cobertura
sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 20 --target-org minha_nova_org
```

Se algum nome de classe já existir no seu repositório (ex.: `TrainingOrderService` do Nível 1), faça o merge manualmente:
os nomes seguem exatamente os sugeridos pelo PDF (`TrainingNegotiationController/Service`, `TrainingNegotiationItemTrigger`,
`TrainingOrderController/Service`, LWC `trainingNegotiationSimulator`).

## 3. Configuração pós-deploy

1. **Permission Sets** (Setup → Permission Sets) — atribua aos usuários:
   | Permission Set | Para quem | Faz |
   |---|---|---|
   | `Training - Vendedor` | vendedores | monta/edita negociações, envia para aprovação, gera pedido |
   | `Training - Aprovador Gerente` | gerentes | decide nível Gerente (>5% a 10%) |
   | `Training - Aprovador Diretor` | diretores | decide nível Diretor (>10% a 20%) |
   | `Training - Aprovador Financeiro` | financeiro | decide nível Financeiro (>20% a 30%) |

   Quem decide é definido pela **Custom Permission** do nível (`Aprovar_Negociacao_*`), nunca pela tela.
2. **Aprovador responsável** (sem Ids fixos): o Flow resolve o aprovador do nível pelo primeiro usuário ativo com o
   Permission Set do nível. Para fixar alguém por ambiente, edite o Custom Metadata `Aprovacao_Nivel__mdt` →
   campo *Aprovador (Username opcional)*.
3. **Simulador na Opportunity**: Lightning App Builder → editar a página de registro da Opportunity → arrastar
   *Training - Simulador de Negociação*. (Existe também a página pronta `Opportunity - Simulador de Negociacao`,
   não ativada para não substituir páginas existentes; ative em *Activation* se quiser.)
4. **Página da Negociação**: `Negociacao_Comercial_Record_Page` já é a visualização padrão do objeto (via *action override*).
5. App **Training Negociações** (Opportunity + Negociações) disponível no App Launcher.
6. (Opcional) `sf apex run --file scripts/apex/seed-demo.apex --target-org minha_nova_org` cria conta, 5 produtos e uma Opportunity.

## 4. Mapa do repositório

```
force-app/main/default/
  objects/            Negociacao_Comercial__c, Item_Negociacao__c, Historico_Decisao__c, Aprovacao_Nivel__mdt,
                      campos extras em Order (vínculo + chave única) e Task (chave de idempotência)
  classes/            Controllers finos, Services, Handlers, Actions invocáveis e classes de teste
  triggers/           TrainingNegotiationItemTrigger (itens) e TrainingNegotiationTrigger (negociação)
  flows/              Negociacao_Roteamento_Aprovacao (record-triggered) e Negociacao_Decisao_Aprovacao (screen)
  lwc/                trainingNegotiationSimulator, trainingNegotiationSummary, trainingNegotiationActions
  flexipages/         página da Negociação (Dynamic Forms + visibilidade por status) e página de Opportunity
  permissionsets/     Vendedor + 3 aprovadores (com Custom Permissions)
  customMetadata/     matriz de aprovação (portável entre ambientes)
docs/                 arquitetura, decisões, evidências de testes, rastreabilidade, respostas do code review, roteiro de demo
scripts/apex/         dados de demonstração
```

## 5. Documentação

| Arquivo | Conteúdo |
|---|---|
| `docs/ARQUITETURA.md` | diagrama e responsabilidade de LWC, Apex, Triggers e Flows |
| `docs/DECISOES_E_LIMITACOES.md` | arredondamento, ownership de campos, recursão, concorrência, limitações conhecidas |
| `docs/TESTES_E_EVIDENCIAS.md` | como validar Apex e Flows (testes declarativos, evidências a anexar) |
| `docs/MATRIZ_RASTREABILIDADE.md` | US/CA → componente → teste |
| `docs/RESPOSTAS_CODE_REVIEW.md` | respostas às 8 perguntas do PDF |
| `docs/ROTEIRO_DEMO.md` | passo a passo da demonstração (inclui cenários de falha) |
