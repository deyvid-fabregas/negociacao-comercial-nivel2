/**
 * Descobre QUEM e o aprovador de um nivel, sempre por configuracao (nunca por Id fixo):
 *  1) Aprovacao_Nivel__mdt.Aprovador_Username__c (opcional, por ambiente), senao
 *  2) primeiro usuario ativo (ordem alfabetica) com a Custom Permission do nivel via Permission Set.
 * "without sharing" apenas para ler objetos de setup (PermissionSetAssignment, SetupEntityAccess).
 */
public without sharing class TrainingApproverResolver {

    public static Id resolve(String nivel) {
        Aprovacao_Nivel__mdt cfg = TrainingApprovalMatrix.byNivel(nivel);
        return resolve(nivel, cfg);
    }

    @TestVisible
    private static Id resolve(String nivel, Aprovacao_Nivel__mdt cfg) {
        if (cfg == null || cfg.Aprovacao_Automatica__c == true) {
            throw new TrainingException('Nível de aprovação inválido para aprovador humano: ' + nivel + '.');
        }

        if (String.isNotBlank(cfg.Aprovador_Username__c)) {
            List<User> configured = [SELECT Id FROM User WHERE Username = :cfg.Aprovador_Username__c AND IsActive = true LIMIT 1];
            if (!configured.isEmpty()) {
                return configured[0].Id;
            }
        }

        if (String.isNotBlank(cfg.Custom_Permission__c)) {
            List<CustomPermission> permissions = [SELECT Id FROM CustomPermission WHERE DeveloperName = :cfg.Custom_Permission__c LIMIT 1];
            if (!permissions.isEmpty()) {
                Set<Id> permissionSetIds = new Set<Id>();
                for (SetupEntityAccess access : [SELECT ParentId FROM SetupEntityAccess WHERE SetupEntityId = :permissions[0].Id]) {
                    permissionSetIds.add(access.ParentId);
                }
                if (!permissionSetIds.isEmpty()) {
                    List<PermissionSetAssignment> assignments = [
                        SELECT AssigneeId FROM PermissionSetAssignment
                        WHERE PermissionSetId IN :permissionSetIds AND Assignee.IsActive = true
                        ORDER BY Assignee.Name LIMIT 1
                    ];
                    if (!assignments.isEmpty()) {
                        return assignments[0].AssigneeId;
                    }
                }
            }
        }

        throw new TrainingException('Nenhum aprovador ativo foi encontrado para o nível ' + nivel
            + '. Atribua o Permission Set correspondente a um usuário ou informe o username no Custom Metadata.');
    }
}
