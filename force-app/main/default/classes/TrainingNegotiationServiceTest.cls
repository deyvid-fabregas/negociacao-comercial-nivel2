@IsTest
private class TrainingNegotiationServiceTest {

    private static User seller;
    private static User director;
    private static Opportunity opp;
    private static List<Product2> products;

    private static void init() {
        seller = TrainingTestDataFactory.createUser('tseller', new List<String>{ TrainingTestDataFactory.PS_VENDEDOR });
        director = TrainingTestDataFactory.createUser('tdir', new List<String>{ TrainingTestDataFactory.PS_DIRETOR });
        TrainingTestDataFactory.createUser('tger', new List<String>{ TrainingTestDataFactory.PS_GERENTE });
        opp = TrainingTestDataFactory.createOpportunity(seller.Id);
        products = TrainingTestDataFactory.createProducts(3, 100);   // 100.00, 101.00, 102.00
    }

    private static void assertSaveFails(TrainingNegotiationRequest request, String fragment) {
        Boolean thrown = false;
        try {
            System.runAs(seller) {
                TrainingNegotiationService.saveNegotiation(request, false);
            }
        } catch (TrainingException e) {
            thrown = true;
            System.assert(e.getMessage().containsIgnoreCase(fragment), 'Mensagem inesperada: ' + e.getMessage());
        }
        System.assert(thrown, 'Era esperado erro contendo: ' + fragment);
        System.assertEquals(0, [SELECT COUNT() FROM Negociacao_Comercial__c], 'Nada deve ter sido gravado');
    }

    // US-01 CA01 e CA04: total correto e persistencia relacionada a Opportunity
    @IsTest
    static void saveCalculatesTotalsOnServerAndPersists() {
        init();
        Map<Id, Integer> quantities = new Map<Id, Integer>{ products[0].Id => 2, products[1].Id => 1 };
        TrainingNegotiationRequest request = TrainingTestDataFactory.buildRequest(opp.Id, 10, 'Cliente estratégico', quantities);

        TrainingNegotiationService.SaveResult result;
        Test.startTest();
        System.runAs(seller) {
            result = TrainingNegotiationService.saveNegotiation(request, false);
        }
        Test.stopTest();

        // 2 x 100,00 + 1 x 101,00 = 301,00 ; 10% = 30,10 ; final = 270,90
        System.assertEquals(301.00, result.grossValue);
        System.assertEquals(30.10, result.discountValue);
        System.assertEquals(270.90, result.finalValue);
        System.assertEquals('Rascunho', result.status);
        Negociacao_Comercial__c saved = TrainingTestDataFactory.reload(result.negotiationId);
        System.assertEquals(opp.Id, [SELECT Opportunity__c FROM Negociacao_Comercial__c WHERE Id = :saved.Id].Opportunity__c);
        System.assertEquals(2, [SELECT COUNT() FROM Item_Negociacao__c WHERE Negociacao__c = :saved.Id]);
        System.assertEquals('Gerente', saved.Nivel_Aprovacao__c);
    }

    // US-01 CA02: desconto > 30, produto repetido, quantidade invalida, lista vazia
    @IsTest
    static void invalidRequestsAreBlocked() {
        init();
        assertSaveFails(TrainingTestDataFactory.buildRequest(opp.Id, 30.01, null, new Map<Id, Integer>{ products[0].Id => 1 }), 'entre 0%');
        assertSaveFails(TrainingTestDataFactory.buildRequest(opp.Id, -1, null, new Map<Id, Integer>{ products[0].Id => 1 }), 'entre 0%');
        assertSaveFails(TrainingTestDataFactory.buildRequest(opp.Id, 5, null, new Map<Id, Integer>{ products[0].Id => 0 }), 'quantidade');

        TrainingNegotiationRequest duplicated = TrainingTestDataFactory.buildRequest(opp.Id, 5, null, new Map<Id, Integer>{ products[0].Id => 1 });
        TrainingNegotiationRequest.Item again = new TrainingNegotiationRequest.Item();
        again.productId = products[0].Id;
        again.quantity = 2;
        duplicated.items.add(again);
        assertSaveFails(duplicated, 'repetir');

        TrainingNegotiationRequest empty = TrainingTestDataFactory.buildRequest(opp.Id, 5, null, new Map<Id, Integer>());
        assertSaveFails(empty, 'ao menos um produto');
    }

    // US-01 CA03: payload malicioso (precos/totais forjados) e ignorado; servidor reprecifica
    @IsTest
    static void maliciousPayloadDoesNotChangeServerRules() {
        init();
        String payloadJson = '{"opportunityId":"' + opp.Id + '","discountPercent":5,"items":[{"productId":"' + products[0].Id
            + '","quantity":1,"unitPrice":0.01,"subtotal":0.01}],"grossValue":1,"finalValue":1,"status":"Aprovada"}';
        TrainingNegotiationRequest request = (TrainingNegotiationRequest) JSON.deserialize(payloadJson, TrainingNegotiationRequest.class);

        TrainingNegotiationService.SaveResult result;
        System.runAs(seller) {
            result = TrainingNegotiationService.saveNegotiation(request, false);
        }
        System.assertEquals(100.00, result.grossValue, 'Preco deve vir do Pricebook, nao do navegador');
        System.assertEquals('Rascunho', result.status);
    }

    @IsTest
    static void productOutsideCatalogIsRejected() {
        init();
        Product2 inactiveEntryProduct = new Product2(Name = 'Sem preco', IsActive = true);
        insert inactiveEntryProduct;
        assertSaveFails(TrainingTestDataFactory.buildRequest(opp.Id, 0, null, new Map<Id, Integer>{ inactiveEntryProduct.Id => 1 }), 'fora do catálogo');
    }

    // Edicao: reabrir rejeitada e editar em Rascunho; Pendente nao pode ser editada
    @IsTest
    static void editingFollowsStatusRules() {
        init();
        TrainingNegotiationService.SaveResult first;
        System.runAs(seller) {
            first = TrainingNegotiationService.saveNegotiation(
                TrainingTestDataFactory.buildRequest(opp.Id, 12, 'Justificativa', new Map<Id, Integer>{ products[0].Id => 1 }), false);
        }
        TrainingNegotiationRequest edit = TrainingTestDataFactory.buildRequest(opp.Id, 12, 'Justificativa', new Map<Id, Integer>{ products[1].Id => 3 });
        edit.negotiationId = first.negotiationId;
        TrainingNegotiationService.SaveResult edited;
        System.runAs(seller) {
            edited = TrainingNegotiationService.saveNegotiation(edit, false);
        }
        System.assertEquals(303.00, edited.grossValue);
        System.assertEquals(1, [SELECT COUNT() FROM Item_Negociacao__c WHERE Negociacao__c = :first.negotiationId]);

        TrainingTestDataFactory.submit(first.negotiationId);   // 12% -> Pendente (Diretor)
        Boolean thrown = false;
        try {
            System.runAs(seller) {
                TrainingNegotiationService.saveNegotiation(edit, false);
            }
        } catch (TrainingException e) {
            thrown = true;
        }
        System.assert(thrown, 'Negociação Pendente não pode ser editada');
    }

    @IsTest
    static void submitRequiresJustificationAboveFivePercent() {
        init();
        Boolean thrown = false;
        try {
            System.runAs(seller) {
                TrainingNegotiationService.saveNegotiation(
                    TrainingTestDataFactory.buildRequest(opp.Id, 8, null, new Map<Id, Integer>{ products[0].Id => 1 }), true);
            }
        } catch (Exception e) {
            thrown = true;
            System.assert(e.getMessage().containsIgnoreCase('justificativa'), e.getMessage());
        }
        System.assert(thrown);
        System.assertEquals(0, [SELECT COUNT() FROM Negociacao_Comercial__c], 'O savepoint deve desfazer o rascunho parcial');
    }

    @IsTest
    static void saveAndSubmitWithinFivePercentApprovesAutomatically() {
        init();
        TrainingNegotiationService.SaveResult result;
        System.runAs(seller) {
            result = TrainingNegotiationService.saveNegotiation(
                TrainingTestDataFactory.buildRequest(opp.Id, 4, null, new Map<Id, Integer>{ products[0].Id => 1 }), true);
        }
        System.assertEquals('Aprovada', result.status);
        System.assert(result.message.contains('aprovada automaticamente'));
    }

    // US-07 CA02: usuario sem privilegios nao contorna as regras pelo metodo exposto
    @IsTest
    static void userWithoutPermissionCannotSave() {
        init();
        User outsider = TrainingTestDataFactory.createUser('tnoperm', null);
        Boolean thrown = false;
        try {
            System.runAs(outsider) {
                TrainingNegotiationService.saveNegotiation(
                    TrainingTestDataFactory.buildRequest(opp.Id, 0, null, new Map<Id, Integer>{ products[0].Id => 1 }), false);
            }
        } catch (Exception e) {
            thrown = true;
        }
        System.assert(thrown, 'Usuário sem permissão não pode criar negociações');
        System.assertEquals(0, [SELECT COUNT() FROM Negociacao_Comercial__c]);
    }

    @IsTest
    static void catalogAndDraftAndMatrixAreAvailable() {
        init();
        System.runAs(seller) {
            List<TrainingNegotiationService.CatalogItem> catalog = TrainingNegotiationService.getCatalog(opp.Id);
            System.assertEquals(3, catalog.size());
            System.assertEquals(4, TrainingNegotiationService.getApprovalMatrix().size());
            System.assertEquals(0, TrainingNegotiationService.getDraft(opp.Id, null).items.size());

            TrainingNegotiationService.SaveResult saved = TrainingNegotiationService.saveNegotiation(
                TrainingTestDataFactory.buildRequest(opp.Id, 3, null, new Map<Id, Integer>{ products[2].Id => 5 }), false);
            TrainingNegotiationService.Draft draft = TrainingNegotiationService.getDraft(opp.Id, null);
            System.assertEquals(saved.negotiationId, draft.negotiationId);
            System.assertEquals(1, draft.items.size());
            System.assertEquals(5, draft.items[0].quantity);

            TrainingNegotiationService.NegotiationView view = TrainingNegotiationService.getView(saved.negotiationId);
            System.assertEquals('Rascunho', view.status);
            System.assertEquals(1, view.items.size());
            System.assertEquals(false, view.canDecide);
        }
    }

    @IsTest
    static void cancelAndControllerWrappers() {
        init();
        System.runAs(seller) {
            TrainingNegotiationService.SaveResult saved = TrainingNegotiationController.saveNegotiation(
                JSON.serialize(TrainingTestDataFactory.buildRequest(opp.Id, 0, null, new Map<Id, Integer>{ products[0].Id => 1 })), false);
            System.assertEquals(3, TrainingNegotiationController.getCatalog(opp.Id).size());
            System.assertEquals('Cancelada', TrainingNegotiationController.cancelNegotiation(saved.negotiationId).status);

            Boolean thrown = false;
            try {
                TrainingNegotiationController.cancelNegotiation(saved.negotiationId);
            } catch (AuraHandledException e) {
                thrown = true;
                System.assert(e.getMessage().contains('não podem ser canceladas'), e.getMessage());
            }
            System.assert(thrown);

            thrown = false;
            try {
                TrainingNegotiationController.saveNegotiation(JSON.serialize(TrainingTestDataFactory.buildRequest(opp.Id, 31, null,
                    new Map<Id, Integer>{ products[0].Id => 1 })), false);
            } catch (AuraHandledException e) {
                thrown = true;
            }
            System.assert(thrown);
        }
    }

    @IsTest
    static void remainingControllerMethodsDelegateAndTranslateErrors() {
        init();
        TrainingNegotiationService.SaveResult saved;
        System.runAs(seller) {
            System.assertEquals(4, TrainingNegotiationController.getApprovalMatrix().size());
            System.assertEquals(0, TrainingNegotiationController.getDraft(opp.Id, null).items.size());
            saved = TrainingNegotiationController.saveNegotiation(
                JSON.serialize(TrainingTestDataFactory.buildRequest(opp.Id, 12, 'Justificativa', new Map<Id, Integer>{ products[0].Id => 1 })), false);
            System.assertEquals('Rascunho', TrainingNegotiationController.getView(saved.negotiationId).status);
            System.assertEquals('Pendente', TrainingNegotiationController.submitNegotiation(saved.negotiationId).status);

            Boolean thrown = false;
            try {
                TrainingNegotiationController.getCatalog(null);
            } catch (AuraHandledException e) {
                thrown = true;
            }
            System.assert(thrown);

            thrown = false;
            try {
                TrainingNegotiationController.getDraft(opp.Id, saved.negotiationId);
            } catch (AuraHandledException e) {
                thrown = true;
            }
            System.assert(thrown);

            thrown = false;
            try {
                TrainingNegotiationController.submitNegotiation(null);
            } catch (AuraHandledException e) {
                thrown = true;
            }
            System.assert(thrown);

            thrown = false;
            try {
                TrainingNegotiationController.reopenNegotiation(saved.negotiationId);
            } catch (AuraHandledException e) {
                thrown = true;
            }
            System.assert(thrown);

            thrown = false;
            try {
                TrainingNegotiationController.getView(null);
            } catch (AuraHandledException e) {
                thrown = true;
            }
            System.assert(thrown);
        }

        System.runAs(director) {
            TrainingApprovalService.decide(saved.negotiationId, 'Rejeitada', 'Revisar proposta');
        }
        System.runAs(seller) {
            TrainingNegotiationService.Draft rejectedDraft =
                TrainingNegotiationController.getDraft(opp.Id, saved.negotiationId);
            System.assertEquals(saved.negotiationId, rejectedDraft.negotiationId);
            System.assertEquals('Rejeitada', TrainingTestDataFactory.reload(saved.negotiationId).Status__c);
            System.assertEquals('Rascunho', TrainingNegotiationController.reopenNegotiation(saved.negotiationId).status);
            System.assertEquals('Cancelada', TrainingNegotiationController.cancelNegotiation(saved.negotiationId).status);
        }
    }

    @IsTest
    static void friendlyMessageHidesTechnicalDetails() {
        System.assertEquals('x', TrainingNegotiationService.friendlyMessage(new TrainingException('x')));
        String generic = TrainingNegotiationService.friendlyMessage(new NullPointerException());
        System.assert(generic.startsWith('Não foi possível concluir'));
    }
}
