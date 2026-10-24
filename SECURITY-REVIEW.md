# Revisão de segurança

## Integridade do preço dos itens da negociação

- **Severidade:** Média
- **Arquivo principal:** `force-app/main/default/classes/TrainingNegotiationItemHandler.cls`
- **Problema:** antes da correção, a trigger verificava que `Preco_Unitario__c` fosse positivo, mas não confirmava que o valor correspondia a uma entrada ativa do Pricebook da Opportunity. DML direto podia gravar um preço diferente do catálogo, alterar os totais e influenciar o pedido gerado.
- **Correção local:** o handler agora consulta em lote as entradas ativas dos produtos nos Pricebooks associados às negociações e rejeita inserções/atualizações sem entrada correspondente ou com preço divergente. A consulta é bulkificada, sem SOQL em loops. Os itens de teste agora usam o preço real do catálogo.
- **Validação:** deploy Salesforce em modo `check-only`, com 41 testes direcionados executados e 0 falhas.
- **Status de implantação:** a validação não implantou a correção; ela permanece local até um deploy posterior.
