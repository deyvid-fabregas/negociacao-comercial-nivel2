/**
 * Integridade dos itens (insert, update, delete, undelete), bulkificada.
 *  - before: valida status do pai (itens so em Rascunho), quantidade, preco, produto duplicado e calcula Subtotal.
 *  - after : coleta os pais afetados (novo E antigo em troca de pai) e delega o recalculo ao RecalcService.
 * Recursao: nao ha DML em itens aqui; o unico DML (no pai) e protegido por TrainingNegotiationContext.
 */
public with sharing class TrainingNegotiationItemHandler {

    public static void run() {
        if (Trigger.isBefore) {
            if (Trigger.isInsert || Trigger.isUpdate) {
                validateAndCalculate((List<Item_Negociacao__c>) Trigger.new,
                    Trigger.isUpdate ? (Map<Id, Item_Negociacao__c>) Trigger.oldMap : null);
            } else if (Trigger.isDelete) {
                validateDelete((List<Item_Negociacao__c>) Trigger.old);
            }
        } else {
            if (Trigger.isInsert) {
                TrainingNegotiationRecalcService.recalculate(parentIds((List<Item_Negociacao__c>) Trigger.new, null));
            } else if (Trigger.isUpdate) {
                TrainingNegotiationRecalcService.recalculate(
                    parentIds((List<Item_Negociacao__c>) Trigger.new, (Map<Id, Item_Negociacao__c>) Trigger.oldMap));
            } else if (Trigger.isDelete) {
                TrainingNegotiationRecalcService.recalculate(parentIds((List<Item_Negociacao__c>) Trigger.old, null));
            } else if (Trigger.isUndelete) {
                validateUndelete((List<Item_Negociacao__c>) Trigger.new);
                TrainingNegotiationRecalcService.recalculate(parentIds((List<Item_Negociacao__c>) Trigger.new, null));
            }
        }
    }

    private static Set<Id> parentIds(List<Item_Negociacao__c> items, Map<Id, Item_Negociacao__c> oldMap) {
        Set<Id> ids = new Set<Id>();
        for (Item_Negociacao__c item : items) {
            if (item.Negociacao__c != null) {
                ids.add(item.Negociacao__c);
            }
            if (oldMap != null && oldMap.containsKey(item.Id) && oldMap.get(item.Id).Negociacao__c != null) {
                ids.add(oldMap.get(item.Id).Negociacao__c);   // troca de pai: recalcula o antigo tambem
            }
        }
        return ids;
    }

    private static Map<Id, Negociacao_Comercial__c> loadParents(Set<Id> ids) {
        return new Map<Id, Negociacao_Comercial__c>([
            SELECT Id, Status__c, Opportunity__r.Pricebook2Id
            FROM Negociacao_Comercial__c
            WHERE Id IN :ids
        ]);
    }

    private static Boolean isLocked(Negociacao_Comercial__c parent) {
        return parent != null && parent.Status__c != TrainingConstants.RASCUNHO;
    }

    private static String key(Id parentId, Id productId) {
        return String.valueOf(parentId) + '|' + String.valueOf(productId);
    }

    private static void validateAndCalculate(List<Item_Negociacao__c> items, Map<Id, Item_Negociacao__c> oldMap) {
        Set<Id> parents = parentIds(items, oldMap);
        Map<Id, Negociacao_Comercial__c> parentMap = loadParents(parents);

        Map<Id, Id> pricebookByParent = new Map<Id, Id>();
        Boolean needsStandardPricebook = false;
        for (Id parentId : parents) {
            Negociacao_Comercial__c parent = parentMap.get(parentId);
            Id pricebookId = parent == null || parent.Opportunity__r == null
                ? null : parent.Opportunity__r.Pricebook2Id;
            if (pricebookId == null) {
                needsStandardPricebook = true;
            } else {
                pricebookByParent.put(parentId, pricebookId);
            }
        }
        if (needsStandardPricebook) {
            Id standardPricebookId = TrainingNegotiationService.resolvePricebookId(null);
            for (Id parentId : parents) {
                if (!pricebookByParent.containsKey(parentId)) {
                    pricebookByParent.put(parentId, standardPricebookId);
                }
            }
        }

        Set<Id> productIds = new Set<Id>();
        for (Item_Negociacao__c item : items) {
            if (item.Produto__c != null) {
                productIds.add(item.Produto__c);
            }
        }
        Set<Id> pricebookIds = new Set<Id>(pricebookByParent.values());
        Map<String, PricebookEntry> catalogEntries = new Map<String, PricebookEntry>();
        if (!productIds.isEmpty() && !pricebookIds.isEmpty()) {
            for (PricebookEntry entry : [
                SELECT Id, Pricebook2Id, Product2Id, UnitPrice
                FROM PricebookEntry
                WHERE Pricebook2Id IN :pricebookIds AND Product2Id IN :productIds
                    AND IsActive = true AND Product2.IsActive = true
            ]) {
                catalogEntries.put(priceKey(entry.Pricebook2Id, entry.Product2Id), entry);
            }
        }

        Map<String, Id> existing = new Map<String, Id>();
        for (Item_Negociacao__c e : [
            SELECT Id, Negociacao__c, Produto__c FROM Item_Negociacao__c WHERE Negociacao__c IN :parents AND Produto__c != null
        ]) {
            existing.put(key(e.Negociacao__c, e.Produto__c), e.Id);
        }

        Set<String> seen = new Set<String>();
        for (Item_Negociacao__c item : items) {
            Item_Negociacao__c old = oldMap == null ? null : oldMap.get(item.Id);
            String error = validate(item, old, parentMap, pricebookByParent, catalogEntries, existing, seen);
            if (error != null) {
                item.addError(error);
            }
        }
    }

    private static String validate(Item_Negociacao__c item, Item_Negociacao__c old, Map<Id, Negociacao_Comercial__c> parentMap,
                                   Map<Id, Id> pricebookByParent, Map<String, PricebookEntry> catalogEntries,
                                   Map<String, Id> existing, Set<String> seen) {
        String locked = 'Itens só podem ser incluídos, alterados ou excluídos enquanto a negociação está em Rascunho.';
        if (isLocked(parentMap.get(item.Negociacao__c))) {
            return locked;
        }
        if (old != null && old.Negociacao__c != item.Negociacao__c && isLocked(parentMap.get(old.Negociacao__c))) {
            return locked;
        }
        if (item.Produto__c == null) {
            return 'Informe o produto do item.';
        }
        if (item.Quantidade__c == null || item.Quantidade__c < 1
                || item.Quantidade__c != item.Quantidade__c.setScale(0, RoundingMode.DOWN)) {
            return 'A quantidade deve ser um número inteiro maior ou igual a 1.';
        }
        if (item.Preco_Unitario__c == null || item.Preco_Unitario__c <= 0) {
            return 'O preço unitário deve ser maior que zero.';
        }
        String k = key(item.Negociacao__c, item.Produto__c);
        Id other = existing.get(k);
        if ((other != null && other != item.Id) || !seen.add(k)) {
            return 'Produto duplicado: o mesmo produto não pode aparecer duas vezes na negociação.';
        }
        Id pricebookId = pricebookByParent.get(item.Negociacao__c);
        PricebookEntry entry = pricebookId == null
            ? null : catalogEntries.get(priceKey(pricebookId, item.Produto__c));
        if (entry == null) {
            return 'O produto precisa ter uma entrada ativa no Pricebook da oportunidade.';
        }
        if (item.Preco_Unitario__c != entry.UnitPrice) {
            return 'O preço unitário deve corresponder ao preço do catálogo ativo da oportunidade.';
        }
        item.Subtotal__c = (item.Quantidade__c * item.Preco_Unitario__c).setScale(2, RoundingMode.HALF_UP);
        return null;
    }

    private static String priceKey(Id pricebookId, Id productId) {
        return String.valueOf(pricebookId) + '|' + String.valueOf(productId);
    }

    private static void validateDelete(List<Item_Negociacao__c> items) {
        Map<Id, Negociacao_Comercial__c> parentMap = loadParents(parentIds(items, null));
        for (Item_Negociacao__c item : items) {
            if (isLocked(parentMap.get(item.Negociacao__c))) {
                item.addError('Itens só podem ser excluídos enquanto a negociação está em Rascunho.');
            }
        }
    }

    private static void validateUndelete(List<Item_Negociacao__c> items) {
        Map<Id, Negociacao_Comercial__c> parentMap = loadParents(parentIds(items, null));
        for (Item_Negociacao__c item : items) {
            if (isLocked(parentMap.get(item.Negociacao__c))) {
                item.addError('Itens só podem ser recuperados enquanto a negociação está em Rascunho.');
            }
        }
    }
}
