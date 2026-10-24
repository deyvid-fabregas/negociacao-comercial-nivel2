/**
 * DTO enviado pelo LWC. Propositalmente NAO contem preco, subtotal nem totais:
 * o servidor nunca confia em valores calculados pelo navegador.
 */
public with sharing class TrainingNegotiationRequest {
    @AuraEnabled public Id negotiationId;
    @AuraEnabled public Id opportunityId;
    @AuraEnabled public Decimal discountPercent;
    @AuraEnabled public String justification;
    @AuraEnabled public List<Item> items;

    public class Item {
        @AuraEnabled public Id productId;
        @AuraEnabled public Integer quantity;
    }
}