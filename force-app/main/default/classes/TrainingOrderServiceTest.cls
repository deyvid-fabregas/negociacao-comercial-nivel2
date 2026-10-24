@IsTest
private class TrainingOrderServiceTest {

    private static User seller;
    private static User diretor;
    private static Opportunity opp;
    private static List<Product2> products;

    private static void init() {
        seller = TrainingTestDataFactory.createUser('oseller', new List<String>{ TrainingTestDataFactory.PS_VENDEDOR });
        diretor = TrainingTestDataFactory.createUser('odir', new List<String>{ TrainingTestDataFactory.PS_DIRETOR });
        opp = TrainingTestDataFactory.createOpportunity(seller.Id);
        products = TrainingTestDataFactory.createProducts(3, 100);
    }

    // US-06 CA01
    @IsTest
    static void approvedNegotiationGeneratesOrderWithThreeItems() {
        init();
        Negociacao_Comercial__c n = TrainingTestDataFactory.createApprovedNegotiation(opp.Id, products, 3);
        System.assertEquals('Aprovada', n.Status__c);

        TrainingOrderService.OrderResult result;
        Test.startTest();
        System.runAs(seller) {
            result = TrainingOrderService.generateOrder(n.Id);
        }
        Test.stopTest();

        System.assertEquals(false, result.alreadyExisted);
        Order order = [SELECT Id, AccountId, Status, Pricebook2Id, Negociacao_Origem_Id__c, Oportunidade_Origem__c FROM Order WHERE Id = :result.orderId];
        System.assertEquals('Draft', order.Status);
        System.assertEquals(opp.AccountId, order.AccountId);
        System.assertEquals(Test.getStandardPricebookId(), order.Pricebook2Id);
        System.assertEquals(String.valueOf(n.Id), order.Negociacao_Origem_Id__c);
        System.assertEquals(opp.Id, order.Oportunidade_Origem__c);
        List<OrderItem> orderItems = [
            SELECT Quantity, UnitPrice FROM OrderItem WHERE OrderId = :order.Id ORDER BY UnitPrice
        ];
        System.assertEquals(3, orderItems.size());
        List<Decimal> expectedPrices = new List<Decimal>{ 96.00, 96.96, 97.92 };
        for (Integer i = 0; i < orderItems.size(); i++) {
            OrderItem oi = orderItems[i];
            System.assertEquals(expectedPrices[i], oi.UnitPrice, 'Preço do catálogo com 4% de desconto');
            System.assertEquals(1, oi.Quantity);
        }
    }

    // US-06 CA03 / matriz: duas geracoes => um unico pedido
    @IsTest
    static void generatingTwiceKeepsASingleOrder() {
        init();
        Negociacao_Comercial__c n = TrainingTestDataFactory.createApprovedNegotiation(opp.Id, products, 2);
        TrainingOrderService.OrderResult first;
        TrainingOrderService.OrderResult second;
        System.runAs(seller) {
            first = TrainingOrderService.generateOrder(n.Id);
            second = TrainingOrderService.generateOrder(n.Id);
        }
        System.assertEquals(first.orderId, second.orderId);
        System.assertEquals(true, second.alreadyExisted);
        System.assertEquals(1, [SELECT COUNT() FROM Order WHERE Negociacao_Comercial__c = :n.Id]);
        System.assertEquals(2, [SELECT COUNT() FROM OrderItem WHERE OrderId = :first.orderId]);

        TrainingNegotiationService.NegotiationView view;
        System.runAs(seller) {
            view = TrainingNegotiationService.getView(n.Id);
        }
        System.assertEquals(first.orderId, view.orderId);
        System.assertEquals(false, view.canGenerateOrder);
    }

    // US-06 CA02 / matriz: falha no 3o item => nenhum Order nem item parcial
    @IsTest
    static void failureOnThirdItemRollsBackEverything() {
        init();
        Negociacao_Comercial__c n = TrainingTestDataFactory.createApprovedNegotiation(opp.Id, products, 3);
        TrainingOrderService.testBreakItemIndex = 2;
        Boolean thrown = false;
        System.runAs(seller) {
            try {
                TrainingOrderService.generateOrder(n.Id);
            } catch (TrainingException e) {
                thrown = true;
                System.assert(e.getMessage().contains('Nenhum registro parcial'), e.getMessage());
            }
        }
        System.assert(thrown);
        System.assertEquals(0, [SELECT COUNT() FROM Order WHERE Negociacao_Comercial__c = :n.Id], 'Order deve ter sofrido rollback');
        System.assertEquals(0, [SELECT COUNT() FROM OrderItem WHERE Order.Negociacao_Comercial__c = :n.Id]);
        System.assertEquals('Aprovada', TrainingTestDataFactory.reload(n.Id).Status__c, 'A negociação não fica bloqueada por falha');

        // Sem a falha forcada, a mesma negociacao gera o pedido normalmente
        TrainingOrderService.testBreakItemIndex = null;
        System.runAs(seller) {
            System.assertEquals(false, TrainingOrderService.generateOrder(n.Id).alreadyExisted);
        }
    }

    // US-06 CA04: Pendente, Rejeitada e Rascunho nao geram pedido
    @IsTest
    static void onlyApprovedNegotiationsGenerateOrders() {
        init();
        Negociacao_Comercial__c draft = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 12, 'Justificativa', products, 1);
        assertBlocked(draft.Id);

        TrainingTestDataFactory.submit(draft.Id);   // Pendente (Diretor)
        System.assertEquals('Pendente', TrainingTestDataFactory.reload(draft.Id).Status__c);
        assertBlocked(draft.Id);

        System.runAs(diretor) {
            TrainingApprovalService.decide(draft.Id, 'Rejeitada', 'Fora da política');
        }
        assertBlocked(draft.Id);
        System.assertEquals(0, [SELECT COUNT() FROM Order]);
    }

    private static void assertBlocked(Id negotiationId) {
        Boolean thrown = false;
        System.runAs(seller) {
            try {
                TrainingOrderService.generateOrder(negotiationId);
            } catch (TrainingException e) {
                thrown = true;
                System.assert(e.getMessage().contains('Somente negociações Aprovadas'), e.getMessage());
            }
        }
        System.assert(thrown);
    }

    @IsTest
    static void controllerReturnsFriendlyErrorsAndUserWithoutPermissionIsBlocked() {
        init();
        Negociacao_Comercial__c n = TrainingTestDataFactory.createApprovedNegotiation(opp.Id, products, 1);
        User outsider = TrainingTestDataFactory.createUser('onoperm', null);
        Boolean thrown = false;
        System.runAs(outsider) {
            try {
                TrainingOrderController.generateOrder(n.Id);
            } catch (AuraHandledException e) {
                thrown = true;
            }
        }
        System.assert(thrown, 'Usuário sem permissão não gera pedido');
        System.assertEquals(0, [SELECT COUNT() FROM Order]);

        System.runAs(seller) {
            TrainingOrderService.OrderResult result = TrainingOrderController.generateOrder(n.Id);
            System.assertNotEquals(null, result.orderNumber);
        }
    }

    // Corrida: pedido ja criado por outra transacao => devolve o existente, sem erro e sem duplicar
    @IsTest
    static void existingOrderFromAnotherTransactionIsReused() {
        init();
        Negociacao_Comercial__c n = TrainingTestDataFactory.createApprovedNegotiation(opp.Id, products, 1);
        Order other = new Order(AccountId = opp.AccountId, Pricebook2Id = Test.getStandardPricebookId(), EffectiveDate = Date.today(),
            Status = 'Draft', Negociacao_Comercial__c = n.Id, Negociacao_Origem_Id__c = String.valueOf(n.Id));
        insert other;
        System.runAs(seller) {
            TrainingOrderService.OrderResult result = TrainingOrderService.generateOrder(n.Id);
            System.assertEquals(other.Id, result.orderId);
            System.assertEquals(true, result.alreadyExisted);
        }
        // A chave unica tambem protege no banco contra insercao direta duplicada
        Order duplicate = new Order(AccountId = opp.AccountId, Pricebook2Id = Test.getStandardPricebookId(), EffectiveDate = Date.today(),
            Status = 'Draft', Negociacao_Comercial__c = n.Id, Negociacao_Origem_Id__c = String.valueOf(n.Id));
        Database.SaveResult result = Database.insert(duplicate, false);
        System.assert(!result.isSuccess());
        System.assertEquals(StatusCode.DUPLICATE_VALUE, result.getErrors()[0].getStatusCode());
    }
}
