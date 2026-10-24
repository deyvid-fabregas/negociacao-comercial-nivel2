@IsTest
private class TrainingApprovalServiceTest {

    private static User seller;
    private static User diretor;
    private static User gerente;
    private static Opportunity opp;
    private static List<Product2> products;

    private static void init() {
        seller = TrainingTestDataFactory.createUser('aseller', new List<String>{ TrainingTestDataFactory.PS_VENDEDOR });
        diretor = TrainingTestDataFactory.createUser('adir', new List<String>{ TrainingTestDataFactory.PS_DIRETOR });
        gerente = TrainingTestDataFactory.createUser('ager', new List<String>{ TrainingTestDataFactory.PS_GERENTE });
        opp = TrainingTestDataFactory.createOpportunity(seller.Id);
        products = TrainingTestDataFactory.createProducts(3, 100);
    }

    private static Negociacao_Comercial__c pendingDirectorNegotiation() {
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 12, 'Cliente estratégico', products, 2);
        TrainingTestDataFactory.submit(n.Id);
        return TrainingTestDataFactory.reload(n.Id);
    }

    // US-03 CA01: 4% aprovada automaticamente, com transicao auditavel
    @IsTest
    static void autoApprovalUpToFivePercent() {
        init();
        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 4, null, products, 1);
        Test.startTest();
        TrainingTestDataFactory.submit(n.Id);
        Test.stopTest();

        n = TrainingTestDataFactory.reload(n.Id);
        System.assertEquals('Aprovada', n.Status__c);
        System.assertEquals('Automática', n.Nivel_Aprovacao__c);
        System.assertNotEquals(null, n.Data_Aprovacao__c);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :n.Id], 'Aprovação automática não gera tarefa');
        List<Historico_Decisao__c> history = [SELECT Decisao__c, Status_Anterior__c, Status_Novo__c FROM Historico_Decisao__c WHERE Negociacao__c = :n.Id];
        System.assertEquals(1, history.size());
        System.assertEquals('Aprovada automaticamente', history[0].Decisao__c);
        System.assertEquals('Pendente', history[0].Status_Anterior__c);
        System.assertEquals('Aprovada', history[0].Status_Novo__c);
    }

    // US-03 CA02 e CA03: 12% fica Pendente com tarefa do diretor; salvar de novo nao duplica
    @IsTest
    static void pendingRoutesToDirectorAndDoesNotDuplicateTask() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        System.assertEquals('Pendente', n.Status__c);
        System.assertEquals('Diretor', n.Nivel_Aprovacao__c);
        System.assertEquals(1, n.Ciclo_Aprovacao__c);
        System.assertNotEquals(null, n.Aprovador__c);

        List<Task> tasks = [SELECT Id, OwnerId, Chave_Idempotencia__c FROM Task WHERE WhatId = :n.Id];
        System.assertEquals(1, tasks.size());
        System.assertEquals(n.Aprovador__c, tasks[0].OwnerId);
        System.assertEquals(String.valueOf(n.Id) + '-1', tasks[0].Chave_Idempotencia__c);

        update new Negociacao_Comercial__c(Id = n.Id, Aprovador__c = n.Aprovador__c);   // salvar de novo sem mudar estado
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :n.Id]);
        System.assertEquals(1, [SELECT COUNT() FROM Historico_Decisao__c WHERE Negociacao__c = :n.Id AND Decisao__c = 'Submetida']);
    }

    // US-04 CA03: aprovacao valida persiste status e auditoria
    @IsTest
    static void authorizedApproverApproves() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        Id expected = n.Aprovador__c;

        TrainingApprovalDecisionAction.Request request = new TrainingApprovalDecisionAction.Request();
        request.negotiationId = n.Id;
        request.decisao = 'Aprovada';
        System.runAs(diretor) {
            List<TrainingApprovalDecisionAction.Result> results =
                TrainingApprovalDecisionAction.apply(new List<TrainingApprovalDecisionAction.Request>{ request });
            System.assertEquals(true, results[0].success);
            System.assert(results[0].message.contains('aprovada'));
        }
        n = TrainingTestDataFactory.reload(n.Id);
        System.assertEquals('Aprovada', n.Status__c);
        System.assertEquals(diretor.Id, n.Aprovador__c);
        System.assertNotEquals(null, n.Data_Aprovacao__c);
        System.assertEquals(null, n.Chave_Pendente__c);
        Historico_Decisao__c audit = [
            SELECT Decisao__c, Usuario__c, Aprovador_Esperado__c, Ciclo__c FROM Historico_Decisao__c
            WHERE Negociacao__c = :n.Id AND Decisao__c = 'Aprovada'
        ];
        System.assertEquals(diretor.Id, audit.Usuario__c);
        System.assertEquals(expected, audit.Aprovador_Esperado__c);
        System.assertEquals(1, audit.Ciclo__c);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :n.Id AND IsClosed = true], 'Tarefa de aprovação deve ser concluída');
    }

    @IsTest
    static void approverResolverRejectsUnknownLevel() {
        Boolean thrown = false;
        try {
            TrainingApproverResolver.resolve('Nível inexistente');
        } catch (TrainingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('inválido'));
        }
        System.assert(thrown);
    }

    @IsTest
    static void approverResolverUsesConfiguredActiveUsername() {
        User configured = TrainingTestDataFactory.createUser('cfguser', null);
        Aprovacao_Nivel__mdt cfg = new Aprovacao_Nivel__mdt(
            Nivel__c = 'Diretor',
            Aprovacao_Automatica__c = false,
            Aprovador_Username__c = configured.Username,
            Custom_Permission__c = 'Aprovar_Negociacao_Diretor'
        );

        System.assertEquals(configured.Id, TrainingApproverResolver.resolve('Diretor', cfg));
    }

    @IsTest
    static void approverResolverFallsBackWhenConfiguredUsernameIsInactive() {
        User inactive = TrainingTestDataFactory.createUser('inactivo', new List<String>{ TrainingTestDataFactory.PS_DIRETOR });
        update new User(Id = inactive.Id, IsActive = false);
        TrainingTestDataFactory.createUser('fallback', new List<String>{ TrainingTestDataFactory.PS_DIRETOR });
        Aprovacao_Nivel__mdt cfg = new Aprovacao_Nivel__mdt(
            Nivel__c = 'Diretor',
            Aprovacao_Automatica__c = false,
            Aprovador_Username__c = inactive.Username,
            Custom_Permission__c = 'Aprovar_Negociacao_Diretor'
        );

        Id approverId = TrainingApproverResolver.resolve('Diretor', cfg);
        System.assertNotEquals(inactive.Id, approverId);
        System.assertEquals(1, [
            SELECT COUNT() FROM PermissionSetAssignment
            WHERE AssigneeId = :approverId
                AND Assignee.IsActive = true
                AND PermissionSet.Name = :TrainingTestDataFactory.PS_DIRETOR
        ]);
    }

    // US-04 CA02: rejeicao sem motivo e bloqueada; com motivo persiste
    @IsTest
    static void rejectionRequiresReason() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        System.runAs(diretor) {
            for (String reason : new List<String>{ null, '', '   ' }) {
                Boolean thrown = false;
                try {
                    TrainingApprovalService.decide(n.Id, 'Rejeitada', reason);
                } catch (TrainingException e) {
                    thrown = true;
                    System.assert(e.getMessage().contains('motivo'));
                }
                System.assert(thrown, 'Rejeição sem motivo deve ser bloqueada');
            }
            TrainingApprovalService.decide(n.Id, 'Rejeitada', '  Margem insuficiente  ');
        }
        n = TrainingTestDataFactory.reload(n.Id);
        System.assertEquals('Rejeitada', n.Status__c);
        System.assertEquals('Margem insuficiente', n.Motivo_Rejeicao__c);
    }

    // US-04 CA01 / US-07 CA02: sem permissao do nivel, o servidor bloqueia (UI e irrelevante)
    @IsTest
    static void unauthorizedUsersCannotDecide() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        List<User> unauthorized = new List<User>{ seller, gerente };   // vendedor e aprovador de OUTRO nivel
        for (User u : unauthorized) {
            Boolean thrown = false;
            System.runAs(u) {
                try {
                    TrainingApprovalService.decide(n.Id, 'Aprovada', null);
                } catch (TrainingException e) {
                    thrown = true;
                    System.assert(e.getMessage().contains('permissão'), e.getMessage());
                }
            }
            System.assert(thrown, 'Usuário sem permissão do nível não pode aprovar');
        }
        System.assertEquals('Pendente', TrainingTestDataFactory.reload(n.Id).Status__c);

        System.runAs(seller) {
            System.assertEquals(false, TrainingNegotiationService.getView(n.Id).canDecide);
        }
        System.runAs(diretor) {
            System.assertEquals(true, TrainingNegotiationService.getView(n.Id).canDecide);
        }

        // Acao invocavel (Screen Flow): devolve falha amigavel, sem excecao
        TrainingApprovalDecisionAction.Request request = new TrainingApprovalDecisionAction.Request();
        request.negotiationId = n.Id;
        request.decisao = 'Aprovada';
        List<TrainingApprovalDecisionAction.Result> results;
        System.runAs(seller) {
            results = TrainingApprovalDecisionAction.apply(new List<TrainingApprovalDecisionAction.Request>{ request });
        }
        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('permissão'));
    }

    // US-04 CA04 / matriz: decisao repetida nao gera segunda transicao
    @IsTest
    static void repeatedDecisionDoesNotDuplicateTransition() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        System.runAs(diretor) {
            TrainingApprovalService.decide(n.Id, 'Aprovada', null);
            Boolean thrown = false;
            try {
                TrainingApprovalService.decide(n.Id, 'Rejeitada', 'Mudei de ideia');
            } catch (TrainingException e) {
                thrown = true;
                System.assert(e.getMessage().contains('já foi resolvida'), e.getMessage());
            }
            System.assert(thrown);

            TrainingApprovalDecisionAction.Request request = new TrainingApprovalDecisionAction.Request();
            request.negotiationId = n.Id;
            request.decisao = 'Aprovada';
            TrainingApprovalDecisionAction.Result result = TrainingApprovalDecisionAction.apply(
                new List<TrainingApprovalDecisionAction.Request>{ request })[0];
            System.assertEquals(false, result.success);
        }
        System.assertEquals('Aprovada', TrainingTestDataFactory.reload(n.Id).Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Historico_Decisao__c WHERE Negociacao__c = :n.Id AND Decisao__c IN ('Aprovada', 'Rejeitada')]);
    }

    @IsTest
    static void invalidDecisionValueIsRejected() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        Boolean thrown = false;
        System.runAs(diretor) {
            try {
                TrainingApprovalService.decide(n.Id, 'Talvez', null);
            } catch (TrainingException e) {
                thrown = true;
            }
        }
        System.assert(thrown);
    }

    // US-03 CA04 + US-04: rejeitar -> reabrir -> reenviar = novo ciclo, nova tarefa, historico preservado
    @IsTest
    static void resubmissionAfterReviewStartsNewCycle() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        System.runAs(diretor) {
            TrainingApprovalService.decide(n.Id, 'Rejeitada', 'Reduzir desconto');
        }
        System.runAs(seller) {
            TrainingNegotiationService.reopenNegotiation(n.Id);
        }
        System.assertEquals('Rascunho', TrainingTestDataFactory.reload(n.Id).Status__c);

        TrainingTestDataFactory.submit(n.Id);
        n = TrainingTestDataFactory.reload(n.Id);
        System.assertEquals('Pendente', n.Status__c);
        System.assertEquals(2, n.Ciclo_Aprovacao__c);
        System.assertEquals(null, n.Motivo_Rejeicao__c, 'Novo ciclo começa limpo');
        System.assertEquals(2, [SELECT COUNT() FROM Task WHERE WhatId = :n.Id], 'Uma tarefa por ciclo');
        System.assertEquals(2, [SELECT COUNT() FROM Historico_Decisao__c WHERE Negociacao__c = :n.Id AND Decisao__c = 'Submetida']);
        System.assertEquals(1, [SELECT COUNT() FROM Historico_Decisao__c WHERE Negociacao__c = :n.Id AND Decisao__c = 'Rejeitada']);
        System.assertEquals(1, [SELECT COUNT() FROM Historico_Decisao__c WHERE Negociacao__c = :n.Id AND Decisao__c = 'Reaberta para revisão']);
    }

    @IsTest
    static void cancellingPendingClosesTasksAndFreesOpportunity() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        System.runAs(seller) {
            TrainingNegotiationService.cancelNegotiation(n.Id);
        }
        n = TrainingTestDataFactory.reload(n.Id);
        System.assertEquals('Cancelada', n.Status__c);
        System.assertEquals(null, n.Chave_Pendente__c);
        System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :n.Id AND IsClosed = false]);
    }

    @IsTest
    static void routingActionAndResolver() {
        init();
        Id resolved = TrainingApproverResolver.resolve('Diretor');
        System.assertEquals(1, [SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :resolved AND PermissionSet.Name = :TrainingTestDataFactory.PS_DIRETOR]);

        Negociacao_Comercial__c n = TrainingTestDataFactory.createNegotiationWithItems(opp.Id, 12, 'Justificativa', products, 1);
        TrainingApprovalRoutingAction.Request human = new TrainingApprovalRoutingAction.Request();
        human.negotiationId = n.Id;
        human.nivel = 'Diretor';
        human.autoApprove = false;
        List<TrainingApprovalRoutingAction.Result> results = TrainingApprovalRoutingAction.route(new List<TrainingApprovalRoutingAction.Request>{ human });
        System.assertNotEquals(null, results[0].approverId);

        // nivel automatico nao tem aprovador humano; auto-aprovar nivel humano e proibido
        Boolean thrown = false;
        try {
            TrainingApproverResolver.resolve('Automática');
        } catch (TrainingException e) {
            thrown = true;
        }
        System.assert(thrown);
        System.assert(TrainingApprovalMatrix.forPercent(0).Aprovacao_Automatica__c);
        System.assertEquals('Gerente', TrainingApprovalMatrix.nivelParaPercentual(5.01));
        System.assertEquals('Automática', TrainingApprovalMatrix.nivelParaPercentual(5));
        System.assertEquals('Diretor', TrainingApprovalMatrix.nivelParaPercentual(20));
        System.assertEquals('Financeiro', TrainingApprovalMatrix.nivelParaPercentual(30));
        System.assertEquals(null, TrainingApprovalMatrix.nivelParaPercentual(30.01));
    }

    @IsTest
    static void autoApproveRefusesHumanLevels() {
        init();
        Negociacao_Comercial__c n = pendingDirectorNegotiation();
        Boolean thrown = false;
        try {
            TrainingApprovalService.autoApprove(new List<Id>{ n.Id });
        } catch (TrainingException e) {
            thrown = true;
        }
        System.assert(thrown);
        System.assertEquals('Pendente', TrainingTestDataFactory.reload(n.Id).Status__c);
    }
}
