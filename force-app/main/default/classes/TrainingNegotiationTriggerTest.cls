/**
 * Testes de Trigger/Handler (US-02): executados com DML direto (equivalente a API/Data Loader).
 */
@IsTest
private class TrainingNegotiationTriggerTest {

    private static void ensureApprovers() {
        TrainingTestDataFactory.createUser('tdir2', new List<String>{ TrainingTestDataFactory.PS_DIRETOR });
        TrainingTestDataFactory.createUser('tger2', new List<String>{ TrainingTestDataFactory.PS_GERENTE });
    }

    private static String firstError(Database.SaveResult result) {
        return result.isSuccess() ? '' : result.getErrors()[0].getMessage();
    }

    // US-02 CA01 / US-07 CA03: 200 itens em uma transacao
    @IsTest
    static void bulk200ItemsRecalculateWithinLimits() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(200, 10);
        Set<Id> productIds = new Map<Id, Product2>(products).keySet();
        Map<Id, Decimal> pricesByProduct = new Map<Id, Decimal>();
        for (PricebookEntry entry : [
            SELECT Product2Id, UnitPrice FROM PricebookEntry
            WHERE Pricebook2Id = :Test.getStandardPricebookId()
                AND Product2Id IN :productIds
        ]) {
            pricesByProduct.put(entry.Product2Id, entry.UnitPrice);
        }
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiation(opp.Id, 10, null);
        List<Item_Negociacao__c> items = new List<Item_Negociacao__c>();
        for (Product2 p : products) {
            items.add(new Item_Negociacao__c(
                Negociacao__c = n.Id, Produto__c = p.Id, Quantidade__c = 2,
                Preco_Unitario__c = pricesByProduct.get(p.Id)
            ));
        }

        Test.startTest();
        insert items;
        Integer queries = Limits.getQueries();
        Integer dmlStatements = Limits.getDmlStatements();
        Test.stopTest();

        Negociacao_Comercial__c reloaded = TrainingTestDataFactory.reload(n.Id);
        System.assertEquals(43800.00, reloaded.Valor_Bruto__c);
        System.assertEquals(4380.00, reloaded.Valor_Desconto__c);
        System.assertEquals(39420.00, reloaded.Valor_Final__c);
        System.assert(queries < 20, 'Consultas: ' + queries);
        System.assert(dmlStatements < 5, 'DMLs: ' + dmlStatements);
    }

    // US-02 CA02
    @IsTest
    static void deletingLastItemZeroesTotals() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(1, 50);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiation(opp.Id, 10, null);
        Item_Negociacao__c item = TrainingTestDataFactory.createItem(n.Id, products[0].Id, 3);
        System.assertEquals(150.00, TrainingTestDataFactory.reload(n.Id).Valor_Bruto__c);

        delete item;

        Negociacao_Comercial__c reloaded = TrainingTestDataFactory.reload(n.Id);
        System.assertEquals(0, reloaded.Valor_Bruto__c);
        System.assertEquals(0, reloaded.Valor_Desconto__c);
        System.assertEquals(0, reloaded.Valor_Final__c);
    }

    // US-02 CA03: troca de pai recalcula os dois
    @IsTest
    static void changingParentRecalculatesBothNegotiations() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(2, 50);
        Negociacao_Comercial__c a = TrainingTestDataFactory.createNegotiation(opp.Id, 0, null);
        Negociacao_Comercial__c b = TrainingTestDataFactory.createNegotiation(opp.Id, 0, null);
        Item_Negociacao__c item = TrainingTestDataFactory.createItem(a.Id, products[0].Id, 2);
        TrainingTestDataFactory.createItem(b.Id, products[1].Id, 1);

        item.Negociacao__c = b.Id;
        update item;

        System.assertEquals(0, TrainingTestDataFactory.reload(a.Id).Valor_Bruto__c);
        System.assertEquals(151.00, TrainingTestDataFactory.reload(b.Id).Valor_Bruto__c);
    }

    @IsTest
    static void undeleteRestoresTotals() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(1, 50);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiation(opp.Id, 0, null);
        Item_Negociacao__c item = TrainingTestDataFactory.createItem(n.Id, products[0].Id, 2);
        delete item;
        System.assertEquals(0, TrainingTestDataFactory.reload(n.Id).Valor_Bruto__c);
        undelete item;
        System.assertEquals(100.00, TrainingTestDataFactory.reload(n.Id).Valor_Bruto__c);
    }

    @IsTest
    static void recalculationHandlesEmptyAndAlreadyCalculatedParents() {
        TrainingNegotiationRecalcService.recalculate(null);
        TrainingNegotiationRecalcService.recalculate(new Set<Id>());

        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(1, 50);
        Negociacao_Comercial__c negotiation = TrainingTestDataFactory.createNegotiationWithItems(
            opp.Id, 0, null, products, 1);
        TrainingNegotiationRecalcService.recalculate(new Set<Id>{ negotiation.Id });
        System.assertEquals(50.00, TrainingTestDataFactory.reload(negotiation.Id).Valor_Bruto__c);
    }

    @IsTest
    static void itemValidationsBlockInvalidData() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(2, 50);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiation(opp.Id, 0, null);

        Database.SaveResult zeroQty = Database.insert(new Item_Negociacao__c(Negociacao__c = n.Id, Produto__c = products[0].Id, Quantidade__c = 0, Preco_Unitario__c = 10), false);
        System.assert(firstError(zeroQty).contains('inteiro'), firstError(zeroQty));
        Database.SaveResult zeroPrice = Database.insert(new Item_Negociacao__c(Negociacao__c = n.Id, Produto__c = products[0].Id, Quantidade__c = 1, Preco_Unitario__c = 0), false);
        System.assert(firstError(zeroPrice).contains('maior que zero'), firstError(zeroPrice));
        Database.SaveResult noProduct = Database.insert(new Item_Negociacao__c(Negociacao__c = n.Id, Quantidade__c = 1, Preco_Unitario__c = 10), false);
        System.assert(firstError(noProduct).contains('produto'), firstError(noProduct));

        TrainingTestDataFactory.createItem(n.Id, products[0].Id, 1);
        Database.SaveResult duplicate = Database.insert(new Item_Negociacao__c(Negociacao__c = n.Id, Produto__c = products[0].Id, Quantidade__c = 1, Preco_Unitario__c = 50), false);
        System.assert(firstError(duplicate).contains('duplicado'), firstError(duplicate));
    }

    @IsTest
    static void directApprovalRequiresLevelPermissionEvenWhenContextIsSet() {
        User seller = TrainingTestDataFactory.createUser('gateselr', new List<String>{ TrainingTestDataFactory.PS_VENDEDOR });
        TrainingTestDataFactory.createUser('gatedir', new List<String>{ TrainingTestDataFactory.PS_DIRETOR });
        Opportunity opp = TrainingTestDataFactory.createOpportunity(seller.Id);
        List<Product2> products = TrainingTestDataFactory.createProducts(1, 100);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiationWithItems(
            opp.Id, 12, 'Desconto estratégico', products, 1);
        TrainingTestDataFactory.submit(n.Id);
        n = TrainingTestDataFactory.reload(n.Id);

        System.runAs(seller) {
            Boolean previous = TrainingNegotiationContext.isDecisionAuthorized();
            TrainingNegotiationContext.setDecisionAuthorized(true);
            try {
                Database.SaveResult result = Database.update(new Negociacao_Comercial__c(
                    Id = n.Id,
                    Status__c = TrainingConstants.APROVADA,
                    Aprovador__c = seller.Id,
                    Data_Aprovacao__c = System.now()
                ), false);
                System.assertEquals(false, result.isSuccess());
                System.assert(firstError(result).contains('usuário autorizado'), firstError(result));
            } finally {
                TrainingNegotiationContext.setDecisionAuthorized(previous);
            }
        }
        System.assertEquals(TrainingConstants.PENDENTE, TrainingTestDataFactory.reload(n.Id).Status__c);
    }

    @IsTest
    static void pendingNegotiationProtectsAuditAndUniquenessFields() {
        User seller = TrainingTestDataFactory.createUser('auditsel', new List<String>{ TrainingTestDataFactory.PS_VENDEDOR });
        TrainingTestDataFactory.createUser('auditdir', new List<String>{ TrainingTestDataFactory.PS_DIRETOR });
        Opportunity opp = TrainingTestDataFactory.createOpportunity(seller.Id);
        List<Product2> products = TrainingTestDataFactory.createProducts(1, 100);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiationWithItems(
            opp.Id, 12, 'Desconto estratégico', products, 1);
        TrainingTestDataFactory.submit(n.Id);
        n = TrainingTestDataFactory.reload(n.Id);

        List<Negociacao_Comercial__c> attempts = new List<Negociacao_Comercial__c>{
            new Negociacao_Comercial__c(Id = n.Id, Aprovador__c = seller.Id),
            new Negociacao_Comercial__c(Id = n.Id, Data_Aprovacao__c = System.now()),
            new Negociacao_Comercial__c(Id = n.Id, Motivo_Rejeicao__c = 'Motivo forjado'),
            new Negociacao_Comercial__c(Id = n.Id, Ciclo_Aprovacao__c = 99),
            new Negociacao_Comercial__c(Id = n.Id, Chave_Pendente__c = null),
            new Negociacao_Comercial__c(
                Id = n.Id, Status__c = TrainingConstants.CANCELADA,
                Aprovador__c = seller.Id, Data_Aprovacao__c = System.now()
            )
        };
        List<String> expectedErrors = new List<String>{
            'O aprovador esperado',
            'Campos de auditoria e controle',
            'Campos de auditoria e controle',
            'Campos de auditoria e controle',
            'Campos de auditoria e controle',
            'Campos de auditoria e controle'
        };
        for (Integer i = 0; i < attempts.size(); i++) {
            Database.SaveResult result = Database.update(attempts[i], false);
            System.assertEquals(false, result.isSuccess());
            System.assert(firstError(result).contains(expectedErrors[i]), firstError(result));
        }
        Negociacao_Comercial__c unchanged = TrainingTestDataFactory.reload(n.Id);
        System.assertEquals(TrainingConstants.PENDENTE, unchanged.Status__c);
        System.assertEquals(String.valueOf(opp.Id), unchanged.Chave_Pendente__c);
    }

    @IsTest
    static void directDmlEnforcesActiveOpportunityPricebookPrice() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(2, 50);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiation(opp.Id, 0, null);

        Database.SaveResult forgedInsert = Database.insert(new Item_Negociacao__c(
            Negociacao__c = n.Id, Produto__c = products[0].Id, Quantidade__c = 1, Preco_Unitario__c = 1
        ), false);
        System.assert(firstError(forgedInsert).contains('preço do catálogo'), firstError(forgedInsert));

        Item_Negociacao__c validItem = TrainingTestDataFactory.createItem(n.Id, products[0].Id, 1);
        validItem.Preco_Unitario__c = 1;
        Database.SaveResult forgedUpdate = Database.update(validItem, false);
        System.assert(firstError(forgedUpdate).contains('preço do catálogo'), firstError(forgedUpdate));
        System.assertEquals(50.00, [SELECT Preco_Unitario__c FROM Item_Negociacao__c WHERE Id = :validItem.Id].Preco_Unitario__c);

        Product2 customOnlyProduct = new Product2(Name = 'Produto fora do catálogo da oportunidade', IsActive = true);
        insert customOnlyProduct;
        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(), Product2Id = customOnlyProduct.Id, UnitPrice = 75, IsActive = true
        );
        Pricebook2 otherPricebook = new Pricebook2(Name = 'Pricebook alternativo', IsActive = true);
        insert otherPricebook;
        insert new PricebookEntry(
            Pricebook2Id = otherPricebook.Id, Product2Id = customOnlyProduct.Id, UnitPrice = 75, IsActive = true
        );
        PricebookEntry standardEntry = [
            SELECT Id, IsActive FROM PricebookEntry
            WHERE Pricebook2Id = :Test.getStandardPricebookId() AND Product2Id = :customOnlyProduct.Id
        ];
        standardEntry.IsActive = false;
        update standardEntry;
        Database.SaveResult outsideCatalog = Database.insert(new Item_Negociacao__c(
            Negociacao__c = n.Id, Produto__c = customOnlyProduct.Id, Quantidade__c = 1, Preco_Unitario__c = 75
        ), false);
        System.assert(firstError(outsideCatalog).contains('entrada ativa'), firstError(outsideCatalog));
    }

    @IsTest
    static void bulkDirectDmlRejectsForgedCatalogPrices() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(200, 50);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiation(opp.Id, 0, null);
        Set<Id> productIds = new Map<Id, Product2>(products).keySet();
        Map<Id, Decimal> catalogPriceByProduct = new Map<Id, Decimal>();
        for (PricebookEntry entry : [
            SELECT Product2Id, UnitPrice FROM PricebookEntry
            WHERE Pricebook2Id = :Test.getStandardPricebookId() AND Product2Id IN :productIds
                AND IsActive = true AND Product2.IsActive = true
        ]) {
            catalogPriceByProduct.put(entry.Product2Id, entry.UnitPrice);
        }

        List<Item_Negociacao__c> forgedItems = new List<Item_Negociacao__c>();
        for (Product2 product : products) {
            forgedItems.add(new Item_Negociacao__c(
                Negociacao__c = n.Id, Produto__c = product.Id, Quantidade__c = 1,
                Preco_Unitario__c = catalogPriceByProduct.get(product.Id) + 1
            ));
        }

        Test.startTest();
        Database.SaveResult[] results = Database.insert(forgedItems, false);
        Test.stopTest();

        System.assertEquals(200, results.size());
        for (Database.SaveResult result : results) {
            System.assert(!result.isSuccess(), 'DML em massa não pode aceitar preço adulterado.');
            System.assert(firstError(result).contains('preço do catálogo'), firstError(result));
        }
        System.assertEquals(0, [SELECT COUNT() FROM Item_Negociacao__c WHERE Negociacao__c = :n.Id]);
    }

    // US-02 CA04 + US-07 matriz: alterar item/negociacao apos aprovacao e bloqueado no servidor
    @IsTest
    static void approvedNegotiationIsImmutableOnEveryChannel() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(3, 100);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createApprovedNegotiation(opp.Id, products, 1);
        System.assertEquals('Aprovada', n.Status__c);
        Item_Negociacao__c item = [SELECT Id, Quantidade__c FROM Item_Negociacao__c WHERE Negociacao__c = :n.Id];

        item.Quantidade__c = 99;
        System.assert(!Database.update(item, false).isSuccess(), 'Alterar item aprovado deve falhar');
        System.assert(!Database.insert(new Item_Negociacao__c(Negociacao__c = n.Id, Produto__c = products[1].Id, Quantidade__c = 1, Preco_Unitario__c = 10), false).isSuccess());
        System.assert(!Database.delete(item, false).isSuccess());

        n.Percentual_Desconto__c = 1;
        Database.SaveResult update1 = Database.update(n, false);
        System.assert(!update1.isSuccess());
        System.assert(firstError(update1).contains('não pode ser alterada'), firstError(update1));
        System.assert(!Database.delete(n, false).isSuccess());
        System.assertEquals(1, [SELECT Quantidade__c FROM Item_Negociacao__c WHERE Id = :item.Id].Quantidade__c);
    }

    @IsTest
    static void statusTransitionsAndDirectEditsAreValidated() {
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(2, 100);

        // insert: so Rascunho; desconto fora da faixa
        System.assert(!Database.insert(new Negociacao_Comercial__c(Opportunity__c = opp.Id, Status__c = 'Pendente'), false).isSuccess());
        System.assert(!Database.insert(new Negociacao_Comercial__c(Opportunity__c = opp.Id, Percentual_Desconto__c = 30.5), false).isSuccess());

        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 12, 'Motivo', products, 1);

        // Valor bruto nao pode ser editado diretamente
        n.Valor_Bruto__c = 1;
        System.assert(firstError(Database.update(n, false)).contains('calculado'));
        n.Valor_Bruto__c = 100;

        // Rascunho -> Aprovada direto: transicao invalida
        Database.SaveResult direct = Database.update(new Negociacao_Comercial__c(Id = n.Id, Status__c = 'Aprovada'), false);
        System.assert(firstError(direct).contains('Transição de status inválida'), firstError(direct));

        // Sem itens nao envia; sem justificativa (>5%) nao envia
        Negociacao_Comercial__c empty = TrainingTestDataFactory.createNegotiation(opp.Id, 0, null);
        System.assert(firstError(Database.update(new Negociacao_Comercial__c(Id = empty.Id, Status__c = 'Pendente'), false)).contains('ao menos um item'));
        Negociacao_Comercial__c noJustification = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 8, null, products, 1);
        System.assert(firstError(Database.update(new Negociacao_Comercial__c(Id = noJustification.Id, Status__c = 'Pendente'), false)).contains('justificativa'));

        // Rascunho excluivel; nao-rascunho nao
        System.assert(Database.delete(empty, false).isSuccess());
    }

    // Restricao transversal: no maximo uma Pendente por Opportunity
    @IsTest
    static void onlyOnePendingNegotiationPerOpportunity() {
        ensureApprovers();
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(2, 100);
        Negociacao_Comercial__c a = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 12, 'Justificativa A', products, 1);
        Negociacao_Comercial__c b = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 12, 'Justificativa B', products, 1);

        TrainingTestDataFactory.submit(a.Id);
        System.assertEquals('Pendente', TrainingTestDataFactory.reload(a.Id).Status__c);
        System.assertEquals(String.valueOf(opp.Id), TrainingTestDataFactory.reload(a.Id).Chave_Pendente__c);

        Database.SaveResult second = Database.update(new Negociacao_Comercial__c(Id = b.Id, Status__c = 'Pendente'), false);
        System.assert(firstError(second).contains('Já existe uma negociação Pendente'), firstError(second));
        System.assertEquals('Rascunho', TrainingTestDataFactory.reload(b.Id).Status__c);
    }

    @IsTest
    static void pendingNegotiationFreezesBusinessFields() {
        ensureApprovers();
        Opportunity opp = TrainingTestDataFactory.createOpportunity(UserInfo.getUserId());
        List<Product2> products = TrainingTestDataFactory.createProducts(1, 100);
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 12, 'Justificativa', products, 1);
        TrainingTestDataFactory.submit(n.Id);

        Database.SaveResult changePercent = Database.update(new Negociacao_Comercial__c(Id = n.Id, Percentual_Desconto__c = 1), false);
        System.assert(firstError(changePercent).contains('só podem ser alterados em Rascunho'), firstError(changePercent));
        Database.SaveResult changeItem = Database.update(new Item_Negociacao__c(Id = [SELECT Id FROM Item_Negociacao__c WHERE Negociacao__c = :n.Id].Id, Quantidade__c = 5), false);
        System.assert(!changeItem.isSuccess());
        // Aprovar por DML direto (fora do servico autorizado) tambem e bloqueado
        Database.SaveResult forcedApproval = Database.update(new Negociacao_Comercial__c(Id = n.Id, Status__c = 'Aprovada',
            Aprovador__c = UserInfo.getUserId(), Data_Aprovacao__c = System.now()), false);
        System.assert(firstError(forcedApproval).contains('processo de decisão autorizado'), firstError(forcedApproval));
    }
}
