# Decisões de projeto e limitações conhecidas

## Arredondamento (documentado conforme o PDF)
- Moeda com **2 casas decimais**, modo **HALF_UP** (`Decimal.setScale(2, RoundingMode.HALF_UP)`) em todos os pontos.
- `Subtotal = round(Quantidade × Preço)`; `Valor_Bruto = soma dos subtotais`; `Valor_Desconto = round(Bruto × % / 100)`;
  `Valor_Final = Bruto − Desconto` (assim `Bruto − Desconto = Final` sempre fecha, sem resíduo).
- O JavaScript replica a mesma estratégia apenas para a **prévia**; o servidor é a fonte da verdade.
- No `Order`, o desconto é distribuído no `UnitPrice` de cada `OrderItem` (`round(Preço × (1 − %))`); por isso o total do pedido
  pode divergir do `Valor_Final__c` em centavos (cada item arredonda separadamente). `Valor_Final__c` permanece a referência.

## Percentual
`Percentual_Desconto__c` guarda o valor "como digitado": `12` = 12%. Em Apex use `/ 100` para fração (a Trigger faz).
A faixa da matriz é **(mínimo exclusivo, máximo inclusivo]**; a automática usa mínimo `-1` para incluir 0%.

## Status e transições
`Rascunho → Pendente | Cancelada`; `Pendente → Aprovada | Rejeitada | Cancelada`; `Rejeitada → Rascunho | Cancelada`;
`Aprovada` e `Cancelada` são finais. Só as ações autorizadas (aprovação automática ou decisão validada) conseguem
`Pendente → Aprovada/Rejeitada`: a Trigger exige o contexto de decisão, valida a permissão do nível para decisões humanas
e só aceita aprovação automática quando o nível calculado é `Automática`.

## Itens só mudam em Rascunho (decisão mais estrita que o mínimo do PDF)
O PDF exige bloquear itens de negociação Aprovada/Cancelada. Também bloqueamos em **Pendente e Rejeitada**, porque editar
itens durante a aprovação invalidaria a decisão (e a US-01 manda voltar a Rascunho antes de editar uma Rejeitada).

## Recursão
Não usamos "flag de já executou". O único DML em cascata é a Trigger de item atualizando o pai; ele é protegido por
`TrainingNegotiationContext.recalculating` (restaurado em `finally`), o que permite recálculos legítimos repetidos na mesma transação.
O Flow não reentra porque seu critério exige **mudança** de `Status__c` para Pendente.

## Concorrência e idempotência
| Cenário | Mecanismo |
|---|---|
| Duas decisões simultâneas | `SELECT ... FOR UPDATE` na negociação + checagem `Status = Pendente`; a 2ª vê "já resolvida" |
| Duas gerações de Order | `FOR UPDATE` + campo único `Order.Negociacao_Origem_Id__c` (rede de segurança no banco) + retorno do pedido existente |
| Duas Pendentes na mesma Opportunity | checagem amigável na Trigger + campo único `Chave_Pendente__c` (= Id da Opportunity enquanto Pendente) |
| Reprocesso do Flow | critério de entrada por mudança de status + `Task.Chave_Idempotencia__c = Id-ciclo` consultada antes de criar |

## Segurança
- Services `with sharing`; DML/SOQL em **modo usuário** (`as user`, `WITH USER_MODE`) nas operações do vendedor/aprovador (CRUD/FLS).
- Decisão: Custom Permission por nível validada no servidor (`FeatureManagement.checkPermission`), independente da FlexiPage.
- `Historico_Decisao__c`: usuários só têm leitura; gravação em modo sistema (`TrainingHistoryService`, `without sharing`).
- Exceções `without sharing` justificadas e mínimas: `RecalcService` (integridade), `ApproverResolver` (objetos de setup),
  `TaskCloser` (concluir tarefa do ciclo após decisão validada), `HistoryService` (auditoria).
- OWD da negociação é `Public Read/Write` para simplificar o treinamento (aprovadores precisam enxergar); em produção usar
  Private + regras de compartilhamento/Territory.

## Sem IDs hardcoded
Pricebook: da Opportunity ou consultado (`IsStandard`). Aprovadores: por Custom Permission/Permission Set (ou username no MDT).
Record Types: não usados. Endpoints: nenhum.

## Limitações conhecidas
1. Os códigos foram compilados no ambiente durante o desenvolvimento.
2. O Flow de roteamento, se não encontrar a configuração do nível (MDT removido), encerra sem ação (a Trigger já impede > 30%).
   Sem aprovador resolvível, o Apex lança erro amigável e a submissão é revertida.
3. Catálogo do simulador limitado a 500 produtos ativos do Pricebook (sem busca paginada).
4. `Order` usa `Status = Draft`; não há ativação automática nem `Contract`.
5. A tarefa de aprovação é criada para **um** usuário (o primeiro do nível, ordem alfabética); qualquer usuário com a
   Custom Permission do nível consegue decidir (delegação natural). Não há separação de funções: o sistema não impede que
   uma pessoa com permissões de vendedor e aprovador decida uma negociação que criou. O PDF não exige essa regra.
6. Os testes de Apex dependem de metadados implantados (Permission Sets, Custom Metadata e Flows ativos), mas não devem
   depender de usuários ou atribuições preexistentes da org. O resolvedor pode escolher um usuário real com permissão
   quando ele for o primeiro em ordem alfabética; os testes verificam a validade da permissão, não uma identidade fixa.
7. Os testes assumem o perfil `Standard User` (ou `Usuário padrão`); em orgs com outro nome ajuste `standardProfileId()` na factory.
8. **Evolução opcional (aprovações sequenciais >15%)**: não implementada (é bônus e não vale pontos). Desenho sugerido:
   campo `Etapa_Aprovacao__c`, Custom Metadata com a sequência (Diretor → Financeiro), Trigger rejeitando decisão fora de ordem,
   `Historico_Decisao__c` por etapa e geração de pedido condicionada à conclusão de todas as etapas.
