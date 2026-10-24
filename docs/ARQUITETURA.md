# Arquitetura

```mermaid
flowchart LR
  subgraph UI[Interface]
    SIM[LWC trainingNegotiationSimulator<br/>Opportunity]
    SUM[LWC trainingNegotiationSummary]
    ACT[LWC trainingNegotiationActions]
    FP[FlexiPage Negociacao_Comercial<br/>Resumo e ações LWC + detalhes padrão]
    SF[Screen Flow<br/>Negociacao_Decisao_Aprovacao]
  end
  subgraph APEX[Apex]
    CTRL[TrainingNegotiationController<br/>TrainingOrderController<br/>finos]
    NS[TrainingNegotiationService]
    AS[TrainingApprovalService]
    OS[TrainingOrderService]
    DA[TrainingApprovalDecisionAction<br/>@InvocableMethod]
    RA[TrainingApprovalRoutingAction<br/>@InvocableMethod]
    RES[TrainingApproverResolver]
  end
  subgraph DATA[Dados e integridade]
    TN[Trigger Negociacao_Comercial__c<br/>TrainingNegotiationHandler]
    TI[Trigger Item_Negociacao__c<br/>TrainingNegotiationItemHandler]
    RC[TrainingNegotiationRecalcService]
    MDT[(Aprovacao_Nivel__mdt)]
    NEG[(Negociacao_Comercial__c)]
    ITM[(Item_Negociacao__c)]
    HIS[(Historico_Decisao__c)]
    ORD[(Order / OrderItem)]
  end
  RTF[Record-Triggered Flow<br/>Negociacao_Roteamento_Aprovacao]

  FP --> SUM & ACT
  SIM & ACT --> CTRL --> NS
  ACT --> SF --> DA --> AS
  ACT --> CTRL --> OS --> ORD
  NS --> NEG & ITM
  ITM --> TI --> RC --> NEG
  NEG --> TN
  NEG -- Status vira Pendente --> RTF
  RTF --> MDT
  RTF --> RA --> RES
  RA --> AS
  AS --> HIS
  AS --> NEG
```

## Responsabilidades

| Camada | Componente | Responsabilidade | NÃO faz |
|---|---|---|---|
| LWC | `trainingNegotiationSimulator` | montar itens, prévia de totais, validação de UX, enviar **apenas** produto/quantidade/desconto | decidir preço, aplicar regra de negócio definitiva |
| LWC | `trainingNegotiationSummary` | resumo, indicadores, itens, motivo da rejeição, aprovador esperado (reutilizado no Screen Flow) | alterar dados |
| LWC | `trainingNegotiationActions` | exibe botões conforme status/permissão; abre modal do simulador e do Screen Flow | autorizar (só exibe; o servidor revalida) |
| Apex Controller | `Training*Controller` | traduzir exceções em `AuraHandledException` | regra de negócio |
| Apex Service | `TrainingNegotiationService` | reprecificar no servidor (Pricebook), salvar com savepoint, submeter/reabrir/cancelar, DML em modo usuário | cálculo de totais do pai (é da Trigger) |
| Apex Service | `TrainingApprovalService` | decisão com lock de linha, autorização por Custom Permission, auditoria, aprovação automática | roteamento (é do Flow) |
| Apex Service | `TrainingOrderService` | Order + OrderItems atômicos e idempotentes | — |
| Trigger/Handler | Negociação | transições de status, congelamento, `Valor_Desconto/Final`, `Nivel_Aprovacao`, ciclo, unicidade de Pendente | criar tarefa |
| Trigger/Handler | Item | validações, `Subtotal`, bloqueio por status, recálculo do pai (bulk) | rotear aprovação |
| Flow (record-triggered) | Roteamento | dispara só em `Status → Pendente`; consulta a matriz (MDT); aprovação automática ou Task idempotente + aprovador esperado | recalcular valores |
| Flow (screen) | Decisão | UI de decisão; chama a ação Apex que valida no servidor | autorizar sozinho |
| Metadados | `Aprovacao_Nivel__mdt` | faixas, Custom Permission e aprovador opcional por nível | — |

A FlexiPage implantada não usa Dynamic Forms nem regras `visibilityRule`: ela contém o resumo e as ações em LWC,
além do painel padrão de detalhes. A visibilidade por estado é controlada dentro de `trainingNegotiationActions`;
é uma conveniência de interface, não um controle de autorização.

## Ownership de campos (evita automações conflitantes)

| Campo | Dono |
|---|---|
| `Valor_Bruto__c` | Trigger de itens (via `RecalcService`) |
| `Valor_Desconto__c`, `Valor_Final__c`, `Nivel_Aprovacao__c`, `Ciclo_Aprovacao__c`, `Chave_Pendente__c` | Trigger da negociação |
| `Aprovador__c` (esperado, enquanto Pendente) | Flow de roteamento |
| `Status__c` Pendente→Aprovada/Rejeitada, `Data_Aprovacao__c`, `Motivo_Rejeicao__c`, `Aprovador__c` (decisor) | `TrainingApprovalService` |
| `Status__c` Rascunho→Pendente, Rejeitada→Rascunho, Cancelada | vendedor via `TrainingNegotiationService` |
| `Historico_Decisao__c` | `TrainingHistoryService` (modo sistema; usuários só leem) |
