/**
 * Regras de integridade da Negociacao_Comercial__c, aplicadas no servidor para QUALQUER canal
 * (LWC, Flow, API, Data Loader, Execute Anonymous).
 *
 * Responsabilidades (ownership dos campos):
 *  - Trigger: Valor_Desconto__c, Valor_Final__c, Nivel_Aprovacao__c, Ciclo_Aprovacao__c,
 *             Chave_Pendente__c e validacao de transicoes. (Valor_Bruto__c: via itens.)
 *  - Flow de roteamento: Aprovador__c (esperado) e Task. A decisao (Status/Data/Motivo): approval service.
 */
public with sharing class TrainingNegotiationHandler {

    private static final Map<String, Set<String>> TRANSICOES = new Map<String, Set<String>>{
        TrainingConstants.RASCUNHO  => new Set<String>{ TrainingConstants.PENDENTE, TrainingConstants.CANCELADA },
        TrainingConstants.PENDENTE  => new Set<String>{ TrainingConstants.APROVADA, TrainingConstants.REJEITADA, TrainingConstants.CANCELADA },
        TrainingConstants.REJEITADA => new Set<String>{ TrainingConstants.RASCUNHO, TrainingConstants.CANCELADA },
        TrainingConstants.APROVADA  => new Set<String>(),
        TrainingConstants.CANCELADA => new Set<String>()
    };

    public static void run() {
        if (!Trigger.isBefore) {
            return;
        }
        if (Trigger.isInsert) {
            beforeInsert((List<Negociacao_Comercial__c>) Trigger.new);
        } else if (Trigger.isUpdate) {
            beforeUpdate((List<Negociacao_Comercial__c>) Trigger.new, (Map<Id, Negociacao_Comercial__c>) Trigger.oldMap);
        } else if (Trigger.isDelete) {
            beforeDelete((List<Negociacao_Comercial__c>) Trigger.old);
        }
    }

    private static void beforeInsert(List<Negociacao_Comercial__c> records) {
        for (Negociacao_Comercial__c n : records) {
            if (String.isBlank(n.Status__c)) {
                n.Status__c = TrainingConstants.RASCUNHO;
            }
            if (n.Status__c != TrainingConstants.RASCUNHO) {
                n.addError('Uma negociação nova só pode ser criada com status Rascunho.');
                continue;
            }
            n.Valor_Bruto__c = 0;
            n.Ciclo_Aprovacao__c = 0;
            n.Chave_Pendente__c = null;
            n.Aprovador__c = null;
            n.Data_Aprovacao__c = null;
            n.Motivo_Rejeicao__c = null;
            if (validatePercent(n)) {
                applyCalculations(n);
            }
        }
    }

    private static void beforeUpdate(List<Negociacao_Comercial__c> records, Map<Id, Negociacao_Comercial__c> oldMap) {
        List<Negociacao_Comercial__c> submissions = new List<Negociacao_Comercial__c>();
        Map<String, Id> resolvedApproverByLevel = new Map<String, Id>();

        for (Negociacao_Comercial__c n : records) {
            Negociacao_Comercial__c o = oldMap.get(n.Id);

            // Aprovada/Cancelada: nada muda, por nenhum canal.
            if (o.Status__c == TrainingConstants.APROVADA || o.Status__c == TrainingConstants.CANCELADA) {
                n.addError('Negociação ' + o.Status__c.toLowerCase() + ' não pode ser alterada por nenhum canal.');
                continue;
            }

            Boolean statusChanged = n.Status__c != o.Status__c;
            if (statusChanged && n.Status__c != TrainingConstants.PENDENTE
                    && n.Status__c != TrainingConstants.APROVADA
                    && n.Status__c != TrainingConstants.REJEITADA
                    && (n.Aprovador__c != o.Aprovador__c
                        || n.Data_Aprovacao__c != o.Data_Aprovacao__c
                        || n.Motivo_Rejeicao__c != o.Motivo_Rejeicao__c
                        || n.Ciclo_Aprovacao__c != o.Ciclo_Aprovacao__c)) {
                n.addError('Campos de auditoria e controle não podem ser alterados fora de uma decisão autorizada.');
                continue;
            }
            if (statusChanged && (n.Status__c == TrainingConstants.APROVADA
                    || n.Status__c == TrainingConstants.REJEITADA)
                    && n.Ciclo_Aprovacao__c != o.Ciclo_Aprovacao__c) {
                n.addError('O ciclo de aprovação é controlado pelo sistema e não pode ser alterado na decisão.');
                continue;
            }
            if (!statusChanged) {
                if (n.Ciclo_Aprovacao__c != o.Ciclo_Aprovacao__c
                        || n.Data_Aprovacao__c != o.Data_Aprovacao__c
                        || n.Motivo_Rejeicao__c != o.Motivo_Rejeicao__c
                        || n.Chave_Pendente__c != o.Chave_Pendente__c) {
                    n.addError('Campos de auditoria e controle não podem ser alterados diretamente.');
                    continue;
                }
                if (n.Aprovador__c != o.Aprovador__c) {
                    if (o.Status__c != TrainingConstants.PENDENTE || o.Aprovador__c != null || n.Aprovador__c == null) {
                        n.addError('O aprovador esperado só pode ser definido uma vez pelo roteamento da negociação.');
                        continue;
                    }
                    if (!resolvedApproverByLevel.containsKey(n.Nivel_Aprovacao__c)) {
                        try {
                            resolvedApproverByLevel.put(n.Nivel_Aprovacao__c,
                                TrainingApproverResolver.resolve(n.Nivel_Aprovacao__c));
                        } catch (TrainingException e) {
                            resolvedApproverByLevel.put(n.Nivel_Aprovacao__c, null);
                            n.addError(e.getMessage());
                            continue;
                        }
                    }
                    if (n.Aprovador__c != resolvedApproverByLevel.get(n.Nivel_Aprovacao__c)) {
                        n.addError('O aprovador informado não corresponde ao roteamento configurado para este nível.');
                        continue;
                    }
                }
            }
            if (statusChanged) {
                Set<String> allowed = TRANSICOES.get(o.Status__c);
                if (allowed == null || !allowed.contains(n.Status__c)) {
                    n.addError('Transição de status inválida: ' + o.Status__c + ' → ' + n.Status__c + '.');
                    continue;
                }
            }

            if (n.Valor_Bruto__c != o.Valor_Bruto__c && !TrainingNegotiationContext.isRecalculating()) {
                n.addError('O valor bruto é calculado a partir dos itens e não pode ser alterado diretamente.');
                continue;
            }

            if (o.Status__c == TrainingConstants.RASCUNHO) {
                if (!validatePercent(n)) {
                    continue;
                }
            } else if (n.Opportunity__c != o.Opportunity__c
                    || n.Percentual_Desconto__c != o.Percentual_Desconto__c
                    || n.Justificativa__c != o.Justificativa__c) {
                n.addError('Oportunidade, desconto e justificativa só podem ser alterados em Rascunho. '
                    + 'Retorne a negociação para Rascunho antes de editar.');
                continue;
            }

            applyCalculations(n);

            if (!statusChanged) {
                continue;
            }
            if (n.Status__c == TrainingConstants.PENDENTE) {
                if (prepareSubmission(n, o)) {
                    submissions.add(n);
                }
            } else if (n.Status__c == TrainingConstants.APROVADA) {
                validateApproval(n);
            } else if (n.Status__c == TrainingConstants.REJEITADA) {
                validateRejection(n);
            } else {
                // Cancelada ou volta para Rascunho: libera a chave de unicidade da pendencia.
                n.Chave_Pendente__c = null;
            }
        }

        validateSinglePending(submissions);
    }

    private static void beforeDelete(List<Negociacao_Comercial__c> records) {
        for (Negociacao_Comercial__c n : records) {
            if (n.Status__c != TrainingConstants.RASCUNHO) {
                n.addError('Somente negociações em Rascunho podem ser excluídas. Use o cancelamento para as demais.');
            }
        }
    }

    // ------------------------------------------------------------------ helpers

    private static Boolean validatePercent(Negociacao_Comercial__c n) {
        Decimal pct = n.Percentual_Desconto__c == null ? 0 : n.Percentual_Desconto__c;
        if (pct < 0 || pct > TrainingConstants.DESCONTO_MAXIMO) {
            n.addError('O percentual de desconto deve estar entre 0% e 30%. Acima de 30% a submissão é bloqueada.');
            return false;
        }
        return true;
    }

    private static void applyCalculations(Negociacao_Comercial__c n) {
        Decimal gross = n.Valor_Bruto__c == null ? 0 : n.Valor_Bruto__c;
        Decimal pct = n.Percentual_Desconto__c == null ? 0 : n.Percentual_Desconto__c;
        n.Percentual_Desconto__c = pct;
        // Estrategia de arredondamento: HALF_UP, 2 casas, aplicado ao desconto; final = bruto - desconto.
        n.Valor_Desconto__c = (gross * pct / 100).setScale(2, RoundingMode.HALF_UP);
        n.Valor_Final__c = gross - n.Valor_Desconto__c;
        n.Nivel_Aprovacao__c = TrainingApprovalMatrix.nivelParaPercentual(pct);
    }

    private static Boolean prepareSubmission(Negociacao_Comercial__c n, Negociacao_Comercial__c o) {
        if (n.Valor_Bruto__c == null || n.Valor_Bruto__c <= 0) {
            n.addError('Adicione ao menos um item antes de enviar a negociação para aprovação.');
            return false;
        }
        if (n.Nivel_Aprovacao__c == null) {
            n.addError('Desconto acima de 30% bloqueia a submissão.');
            return false;
        }
        if (n.Nivel_Aprovacao__c != TrainingConstants.NIVEL_AUTOMATICA && String.isBlank(n.Justificativa__c)) {
            n.addError('Informe a justificativa do desconto (obrigatória acima de 5%).');
            return false;
        }
        n.Ciclo_Aprovacao__c = (o.Ciclo_Aprovacao__c == null ? 0 : o.Ciclo_Aprovacao__c) + 1;
        n.Chave_Pendente__c = String.valueOf(n.Opportunity__c);
        n.Aprovador__c = null;
        n.Data_Aprovacao__c = null;
        n.Motivo_Rejeicao__c = null;
        return true;
    }

    private static void validateApproval(Negociacao_Comercial__c n) {
        if (!TrainingNegotiationContext.isDecisionAuthorized()) {
            n.addError('A aprovação só pode ser registrada pelo processo de decisão autorizado.');
            return;
        }
        if (n.Nivel_Aprovacao__c == TrainingConstants.NIVEL_AUTOMATICA) {
            if (n.Aprovador__c != null) {
                n.addError('A aprovação automática não pode registrar um aprovador humano.');
                return;
            }
        } else if (!TrainingApprovalService.hasLevelPermission(n.Nivel_Aprovacao__c)
                || n.Aprovador__c != UserInfo.getUserId()) {
            n.addError('A aprovação exige um usuário autorizado para o nível e identificado como decisor.');
            return;
        }
        if (n.Data_Aprovacao__c == null || (n.Aprovador__c == null && n.Nivel_Aprovacao__c != TrainingConstants.NIVEL_AUTOMATICA)) {
            n.addError('A aprovação exige responsável e data/hora da decisão.');
            return;
        }
        n.Chave_Pendente__c = null;
    }

    private static void validateRejection(Negociacao_Comercial__c n) {
        if (!TrainingNegotiationContext.isDecisionAuthorized()) {
            n.addError('A rejeição só pode ser registrada pelo processo de decisão autorizado.');
            return;
        }
        if (n.Nivel_Aprovacao__c == TrainingConstants.NIVEL_AUTOMATICA
                || !TrainingApprovalService.hasLevelPermission(n.Nivel_Aprovacao__c)
                || n.Aprovador__c != UserInfo.getUserId()) {
            n.addError('A rejeição exige um usuário autorizado para o nível e identificado como decisor.');
            return;
        }
        if (String.isBlank(n.Motivo_Rejeicao__c)) {
            n.addError('A rejeição exige um motivo.');
            return;
        }
        if (n.Aprovador__c == null || n.Data_Aprovacao__c == null) {
            n.addError('A rejeição exige responsável e data/hora da decisão.');
            return;
        }
        n.Chave_Pendente__c = null;
    }

    /** No maximo uma Pendente por Opportunity (checagem amigavel; o banco garante via Chave_Pendente__c unica). */
    private static void validateSinglePending(List<Negociacao_Comercial__c> submissions) {
        if (submissions.isEmpty()) {
            return;
        }
        Set<Id> ids = new Set<Id>();
        Set<Id> opportunityIds = new Set<Id>();
        for (Negociacao_Comercial__c n : submissions) {
            ids.add(n.Id);
            opportunityIds.add(n.Opportunity__c);
        }
        String pendente = TrainingConstants.PENDENTE;
        Set<Id> blocked = new Set<Id>();
        for (Negociacao_Comercial__c existing : [
            SELECT Opportunity__c FROM Negociacao_Comercial__c
            WHERE Opportunity__c IN :opportunityIds AND Status__c = :pendente AND Id NOT IN :ids
        ]) {
            blocked.add(existing.Opportunity__c);
        }
        Set<Id> seenInBatch = new Set<Id>();
        for (Negociacao_Comercial__c n : submissions) {
            if (blocked.contains(n.Opportunity__c) || !seenInBatch.add(n.Opportunity__c)) {
                n.addError('Já existe uma negociação Pendente para esta oportunidade.');
            }
        }
    }
}
