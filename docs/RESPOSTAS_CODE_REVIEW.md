# Respostas às perguntas do code review

1. **Por que a validação no JavaScript não impede alterações feitas por API?**
   O JS roda no navegador do usuário e pode ser ignorado: quem chama a API REST, o Data Loader ou o Execute Anonymous nem passa pelo LWC.
   Por isso as mesmas regras existem no servidor: o Service reprecifica e valida (preço vem do Pricebook), e as Triggers
   validam quantidade, preço, duplicidade, status e transições para qualquer canal.

2. **Como um Trigger bulkificado identifica todos os pais afetados por insert, update, delete e undelete?**
   `parentIds(items, oldMap)` percorre `Trigger.new` (insert/update/undelete) ou `Trigger.old` (delete) e coleta `Negociacao__c`;
   no update inclui também o pai **antigo** (`oldMap`), cobrindo troca de pai. Um único `Set<Id>` alimenta uma agregação
   (`SUM(Subtotal__c) GROUP BY`), uma consulta dos pais e um DML — sem SOQL/DML em loop.

3. **Por que o Record-Triggered Flow não deve replicar os cálculos da Trigger?**
   Duas automações calculando os mesmos campos geram conflito de ordem de execução, resultados divergentes e manutenção dupla.
   Há ownership explícito: a Trigger calcula valores/nível/ciclo; o Flow só roteia (aprovação automática, Task, aprovador esperado).

4. **Como garantir que reprocessar o Flow não gere uma nova tarefa?**
   (a) O critério de entrada exige que `Status__c` **mude** para Pendente; salvar de novo não dispara.
   (b) Antes de criar a Task o Flow consulta `Task.Chave_Idempotencia__c = Id-ciclo`; se existe, não cria.
   Um reenvio legítimo incrementa o ciclo e, portanto, gera chave nova (nova Task).

5. **Como você valida a permissão de quem aprova independentemente da FlexiPage?**
   `TrainingApprovalService.decide` exige a Custom Permission do **nível** (`FeatureManagement.checkPermission`) a cada chamada, seja pelo
   Screen Flow, Apex direto ou Execute Anonymous. A Trigger também verifica a Custom Permission do nível humano e identifica o decisor,
   mesmo que alguém defina a flag estática de contexto diretamente; para aprovação automática, exige o nível `Automática` calculado no servidor.
   A visibilidade do botão na página é só conveniência de UX.

6. **Como seus dados permanecem íntegros quando o terceiro OrderItem falha?**
   `Savepoint` antes de criar o Order; qualquer exceção chama `Database.rollback`. O insert dos itens é all-or-none. O teste
   `failureOnThirdItemRollsBackEverything` força falha no 3º item e comprova que não sobra Order nem OrderItem.

7. **Como seu desenho impede dois Orders diante de requisições simultâneas?**
   Camada 1: `FOR UPDATE` na negociação serializa as chamadas (a 2ª só segue depois da 1ª e então enxerga o pedido existente).
   Camada 2: `Order.Negociacao_Origem_Id__c` é **único** no banco; se duas transações passarem do lock, a 2ª recebe `DUPLICATE_VALUE`,
   o serviço faz rollback e devolve o pedido já criado.

8. **Qual parte da solução você mudaria se novos níveis de aprovação fossem criados?**
   Praticamente nada de código: basta um novo registro em `Aprovacao_Nivel__mdt` (faixa + Custom Permission), um valor na picklist
   `Nivel_Aprovacao__c`, a Custom Permission e o Permission Set. A matriz é dado, não código.
   (Hoje a picklist ainda exige o novo valor; uma melhoria seria validar o nível contra o MDT.)
