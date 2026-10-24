/**
 * Controller fino do LWC (simulador, resumo e acoes). Nenhuma regra de negocio aqui.
 */
public with sharing class TrainingNegotiationController {

    @AuraEnabled(cacheable=true)
    public static List<TrainingNegotiationService.CatalogItem> getCatalog(Id opportunityId) {
        try {
            return TrainingNegotiationService.getCatalog(opportunityId);
        } catch (Exception e) {
            throw TrainingNegotiationService.toAura(e);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<TrainingNegotiationService.MatrixLevel> getApprovalMatrix() {
        return TrainingNegotiationService.getApprovalMatrix();
    }

    @AuraEnabled
    public static TrainingNegotiationService.Draft getDraft(Id opportunityId, Id negotiationId) {
        try {
            return TrainingNegotiationService.getDraft(opportunityId, negotiationId);
        } catch (Exception e) {
            throw TrainingNegotiationService.toAura(e);
        }
    }

    @AuraEnabled
    public static TrainingNegotiationService.SaveResult     saveNegotiation(String requestJson, Boolean submit) {
        try {
                // JSON explícito: evita falha de conversão da lista de classes internas vinda do LWC.
                TrainingNegotiationRequest request = (TrainingNegotiationRequest) JSON.deserialize(requestJson, TrainingNegotiationRequest.class);
                return TrainingNegotiationService.saveNegotiation(request, submit);
        } catch (Exception e) {
            throw TrainingNegotiationService.toAura(e);
        }
    }

    @AuraEnabled
    public static TrainingNegotiationService.SaveResult submitNegotiation(Id negotiationId) {
        try {
            return TrainingNegotiationService.submitNegotiation(negotiationId);
        } catch (Exception e) {
            throw TrainingNegotiationService.toAura(e);
        }
    }

    @AuraEnabled
    public static TrainingNegotiationService.SaveResult reopenNegotiation(Id negotiationId) {
        try {
            return TrainingNegotiationService.reopenNegotiation(negotiationId);
        } catch (Exception e) {
            throw TrainingNegotiationService.toAura(e);
        }
    }

    @AuraEnabled
    public static TrainingNegotiationService.SaveResult cancelNegotiation(Id negotiationId) {
        try {
            return TrainingNegotiationService.cancelNegotiation(negotiationId);
        } catch (Exception e) {
            throw TrainingNegotiationService.toAura(e);
        }
    }

    @AuraEnabled
    public static TrainingNegotiationService.NegotiationView getView(Id negotiationId) {
        try {
            return TrainingNegotiationService.getView(negotiationId);
        } catch (Exception e) {
            throw TrainingNegotiationService.toAura(e);
        }
    }
}