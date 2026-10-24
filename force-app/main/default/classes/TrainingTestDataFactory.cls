/**
 * Fabrica de dados de teste. Nenhum teste depende de registros pre-existentes do ambiente
 * (somente de metadados implantados: Permission Sets, Custom Metadata e Flows).
 */
@IsTest
public class TrainingTestDataFactory {

    public static final String PS_VENDEDOR = 'Training_Vendedor';
    public static final String PS_GERENTE = 'Training_Aprovador_Gerente';
    public static final String PS_DIRETOR = 'Training_Aprovador_Diretor';
    public static final String PS_FINANCEIRO = 'Training_Aprovador_Financeiro';

    public static Id standardProfileId() {
        List<Profile> profiles = [SELECT Id FROM Profile WHERE Name IN ('Standard User', 'Usuário padrão', 'Usuario padrao') LIMIT 1];
        return profiles.isEmpty() ? UserInfo.getProfileId() : profiles[0].Id;
    }

    /** Cria usuario e atribui Permission Sets (DML de setup isolado em runAs para evitar MIXED_DML). */
    public static User createUser(String alias, List<String> permissionSetNames) {
        User u = new User(
            Alias = alias, Email = alias + '@training.test', EmailEncodingKey = 'UTF-8', LastName = 'Teste ' + alias,
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = standardProfileId(),
            TimeZoneSidKey = 'America/Sao_Paulo',
            Username = alias + '.' + String.valueOf(Math.abs(Crypto.getRandomInteger())) + '@training.test'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            if (permissionSetNames != null && !permissionSetNames.isEmpty()) {
                List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
                for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
                    assignments.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id));
                }
                insert assignments;
            }
        }
        return u;
    }

    public static Account createAccount(Id ownerId) {
        Account acc = new Account(Name = 'Concessionária Teste', OwnerId = ownerId);
        insert acc;
        return acc;
    }

    public static Opportunity createOpportunity(Id ownerId) {
        Account acc = createAccount(ownerId);
        Opportunity opp = new Opportunity(
            Name = 'Oportunidade Teste', AccountId = acc.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30), Pricebook2Id = Test.getStandardPricebookId(), OwnerId = ownerId
        );
        insert opp;
        return opp;
    }

    /** Cria produtos ativos com entrada no Pricebook standard. Preco = basePrice + indice. */
    public static List<Product2> createProducts(Integer count, Decimal basePrice) {
        List<Product2> products = new List<Product2>();
        for (Integer i = 0; i < count; i++) {
            products.add(new Product2(Name = 'Produto ' + i, ProductCode = 'P' + i, IsActive = true));
        }
        insert products;
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Integer i = 0; i < count; i++) {
            entries.add(new PricebookEntry(
                Pricebook2Id = Test.getStandardPricebookId(), Product2Id = products[i].Id,
                UnitPrice = basePrice + i, IsActive = true
            ));
        }
        insert entries;
        return products;
    }

    public static Negociacao_Comercial__c createNegotiation(Id opportunityId, Decimal percent, String justification) {
        Negociacao_Comercial__c n = new Negociacao_Comercial__c(
            Opportunity__c = opportunityId, Percentual_Desconto__c = percent, Justificativa__c = justification
        );
        insert n;
        return n;
    }

    public static Item_Negociacao__c createItem(Id negotiationId, Id productId, Integer quantity) {
        Negociacao_Comercial__c negotiation = [
            SELECT Opportunity__r.Pricebook2Id
            FROM Negociacao_Comercial__c WHERE Id = :negotiationId
        ];
        Id pricebookId = TrainingNegotiationService.resolvePricebookId(negotiation.Opportunity__r.Pricebook2Id);
        PricebookEntry entry = [
            SELECT UnitPrice FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND Product2Id = :productId
                AND IsActive = true AND Product2.IsActive = true
            LIMIT 1
        ];
        Item_Negociacao__c item = new Item_Negociacao__c(
            Negociacao__c = negotiationId, Produto__c = productId, Quantidade__c = quantity,
            Preco_Unitario__c = entry.UnitPrice
        );
        insert item;
        return item;
    }

    /** Negociacao Rascunho com N itens distintos, precificados pelo catalogo da oportunidade. */
    public static Negociacao_Comercial__c createNegotiationWithItems(Id opportunityId, Decimal percent, String justification,
                                                                     List<Product2> products, Integer itemCount) {
        Negociacao_Comercial__c n = createNegotiation(opportunityId, percent, justification);
        Opportunity opportunity = [SELECT Pricebook2Id FROM Opportunity WHERE Id = :opportunityId];
        Id pricebookId = TrainingNegotiationService.resolvePricebookId(opportunity.Pricebook2Id);
        Set<Id> productIds = new Set<Id>();
        for (Integer i = 0; i < itemCount; i++) {
            productIds.add(products[i].Id);
        }
        Map<Id, PricebookEntry> entriesByProduct = new Map<Id, PricebookEntry>();
        for (PricebookEntry entry : [
            SELECT Product2Id, UnitPrice FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND Product2Id IN :productIds
                AND IsActive = true AND Product2.IsActive = true
        ]) {
            entriesByProduct.put(entry.Product2Id, entry);
        }
        List<Item_Negociacao__c> items = new List<Item_Negociacao__c>();
        for (Integer i = 0; i < itemCount; i++) {
            items.add(new Item_Negociacao__c(
                Negociacao__c = n.Id, Produto__c = products[i].Id, Quantidade__c = 1,
                Preco_Unitario__c = entriesByProduct.get(products[i].Id).UnitPrice
            ));
        }
        insert items;
        return n;
    }

    public static void submit(Id negotiationId) {
        update new Negociacao_Comercial__c(Id = negotiationId, Status__c = TrainingConstants.PENDENTE);
    }

    public static Negociacao_Comercial__c reload(Id negotiationId) {
        return [
            SELECT Id, Name, Status__c, Nivel_Aprovacao__c, Ciclo_Aprovacao__c, Valor_Bruto__c, Percentual_Desconto__c,
                   Valor_Desconto__c, Valor_Final__c, Aprovador__c, Data_Aprovacao__c, Motivo_Rejeicao__c, Chave_Pendente__c
            FROM Negociacao_Comercial__c WHERE Id = :negotiationId
        ];
    }

    /** Negociacao Aprovada via aprovacao automatica (<= 5%), exercitando o Flow de roteamento. */
    public static Negociacao_Comercial__c createApprovedNegotiation(Id opportunityId, List<Product2> products, Integer itemCount) {
        Negociacao_Comercial__c n = createNegotiationWithItems(opportunityId, 4, null, products, itemCount);
        submit(n.Id);
        return reload(n.Id);
    }

    public static TrainingNegotiationRequest buildRequest(Id opportunityId, Decimal percent, String justification, Map<Id, Integer> quantityByProduct) {
        TrainingNegotiationRequest request = new TrainingNegotiationRequest();
        request.opportunityId = opportunityId;
        request.discountPercent = percent;
        request.justification = justification;
        request.items = new List<TrainingNegotiationRequest.Item>();
        for (Id productId : quantityByProduct.keySet()) {
            TrainingNegotiationRequest.Item item = new TrainingNegotiationRequest.Item();
            item.productId = productId;
            item.quantity = quantityByProduct.get(productId);
            request.items.add(item);
        }
        return request;
    }
}
