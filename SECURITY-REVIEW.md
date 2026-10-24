# Revisão de segurança

## Integridade do preço dos itens da negociação

- **Severidade:** Média
- **Arquivo principal:** `force-app/main/default/classes/TrainingNegotiationItemHandler.cls`
- **Problema:** antes da correção, a trigger verificava que `Preco_Unitario__c` fosse positivo, mas não confirmava que o valor correspondia a uma entrada ativa do Pricebook da Opportunity. DML direto podia gravar um preço diferente do catálogo, alterar os totais e influenciar o pedido gerado.
- **Correção:** o handler consulta em lote as entradas ativas dos produtos nos Pricebooks associados às negociações e rejeita inserts/updates sem entrada correspondente ou com preço divergente. A consulta é bulkificada, sem SOQL em loops.
- **Testes de regressão:** `directDmlEnforcesActiveOpportunityPricebookPrice` comprova que insert e update com preço adulterado, além de produto sem entrada ativa, são bloqueados. `bulkDirectDmlRejectsForgedCatalogPrices` comprova o bloqueio em 200 inserts diretos; `bulk200ItemsRecalculateWithinLimits` valida o caminho em massa com preços de catálogo.
- **Validação atual:** teste completo `RunLocalTests`: 42/42 aprovados, cobertura global de 92% (24/10/2026). Saída em [`docs/evidencias/testes-apex-cobertura.txt`](docs/evidencias/testes-apex-cobertura.txt).
- **Status:** correção implantada em `minha_nova_org` e publicada no repositório. A validação check-only citada no histórico verificou apenas a versão anterior do ajuste e não deve ser usada como status atual.
