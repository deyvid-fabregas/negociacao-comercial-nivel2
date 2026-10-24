import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import CURRENCY from '@salesforce/i18n/currency';
import getCatalog from '@salesforce/apex/TrainingNegotiationController.getCatalog';
import getDraft from '@salesforce/apex/TrainingNegotiationController.getDraft';
import getApprovalMatrix from '@salesforce/apex/TrainingNegotiationController.getApprovalMatrix';
import saveNegotiation from '@salesforce/apex/TrainingNegotiationController.saveNegotiation';

const MAX_DISCOUNT = 30;
const AUTO_LIMIT = 5;

// Mesma estratégia do servidor: arredondamento HALF_UP em 2 casas (a prévia é só informativa;
// o servidor reprecifica e revalida tudo ao salvar).
const round2 = (value) => Math.round((Number(value) + Number.EPSILON) * 100) / 100;

let lineSequence = 0;
const newLine = (productId = null, quantity = 1) => ({ key: `line-${++lineSequence}`, productId, quantity });

export default class TrainingNegotiationSimulator extends NavigationMixin(LightningElement) {
    /** Id da Opportunity quando o componente está na página da Opportunity. */
    @api recordId;
    /** Usados quando o simulador é aberto de dentro da página da negociação (modal). */
    @api opportunityId;
    @api negotiationId;

    currencyCode = CURRENCY;
    catalog = [];
    matrix = [];
    lines = [];
    discount = 0;
    justification = '';
    errors = [];
    loading = true;
    saving = false;
    currentNegotiationId;

    get oppId() {
        return this.opportunityId || this.recordId;
    }

    connectedCallback() {
        this.currentNegotiationId = this.negotiationId;
        this.init();
    }

    async init() {
        this.loading = true;
        try {
            const [catalog, matrix, draft] = await Promise.all([
                getCatalog({ opportunityId: this.oppId }),
                getApprovalMatrix(),
                getDraft({ opportunityId: this.oppId, negotiationId: this.negotiationId })
            ]);
            this.catalog = catalog;
            this.matrix = matrix;
            this.currentNegotiationId = draft.negotiationId || this.negotiationId;
            this.discount = draft.discountPercent || 0;
            this.justification = draft.justification || '';
            this.lines = draft.items && draft.items.length
                ? draft.items.map((i) => newLine(i.productId, i.quantity))
                : [newLine()];
        } catch (error) {
            this.errors = [this.reduceError(error)];
            this.lines = [newLine()];
        } finally {
            this.loading = false;
        }
    }

    // ---------------------------------------------------------------- view model
    get catalogById() {
        const map = new Map();
        this.catalog.forEach((c) => map.set(c.productId, c));
        return map;
    }

    get lineViews() {
        const byId = this.catalogById;
        const used = new Set(this.lines.map((l) => l.productId).filter(Boolean));
        return this.lines.map((line) => {
            const entry = line.productId ? byId.get(line.productId) : null;
            const qty = Number(line.quantity) || 0;
            const options = this.catalog
                .filter((c) => c.productId === line.productId || !used.has(c.productId))
                .map((c) => ({ label: c.productCode ? `${c.productName} (${c.productCode})` : c.productName, value: c.productId }));
            return {
                ...line,
                options,
                hasPrice: !!entry,
                unitPrice: entry ? entry.unitPrice : 0,
                subtotal: entry ? round2(qty * entry.unitPrice) : 0,
                canRemove: this.lines.length > 1
            };
        });
    }

    get gross() {
        const byId = this.catalogById;
        return round2(
            this.lines.reduce((sum, l) => {
                const entry = l.productId ? byId.get(l.productId) : null;
                return sum + (entry ? round2((Number(l.quantity) || 0) * entry.unitPrice) : 0);
            }, 0)
        );
    }

    get discountPercent() {
        const value = Number(this.discount);
        return Number.isFinite(value) ? value : 0;
    }

    get discountValue() {
        return round2((this.gross * this.discountPercent) / 100);
    }

    get finalValue() {
        return round2(this.gross - this.discountValue);
    }

    get approvalLabel() {
        const pct = this.discountPercent;
        if (pct < 0 || pct > MAX_DISCOUNT) {
            return 'Desconto fora do limite (0% a 30%): submissão bloqueada';
        }
        const level = this.matrix.find((m) => m.minimo < pct && pct <= m.maximo);
        if (!level) {
            return '';
        }
        return level.automatica ? 'Aprovação automática' : `Aprovação necessária: ${level.nivel}`;
    }

    get requiresJustification() {
        return this.discountPercent > AUTO_LIMIT;
    }

    get hasErrors() {
        return this.errors.length > 0;
    }

    get saveDisabled() {
        return this.loading || this.saving;
    }

    // ---------------------------------------------------------------- handlers
    handleProduct(event) {
        const key = event.target.dataset.key;
        this.lines = this.lines.map((l) => (l.key === key ? { ...l, productId: event.detail.value } : l));
    }

    handleQuantity(event) {
        const key = event.target.dataset.key;
        this.lines = this.lines.map((l) => (l.key === key ? { ...l, quantity: event.detail.value } : l));
    }

    handleAddLine() {
        this.lines = [...this.lines, newLine()];
    }

    handleRemoveLine(event) {
        const key = event.target.dataset.key;
        this.lines = this.lines.filter((l) => l.key !== key);
        if (!this.lines.length) {
            this.lines = [newLine()];
        }
    }

    handleDiscount(event) {
        this.discount = event.detail.value;
    }

    handleJustification(event) {
        this.justification = event.detail.value;
    }

    handleSaveDraft() {
        return this.save(false);
    }

    handleSaveAndSubmit() {
        return this.save(true);
    }

    // ---------------------------------------------------------------- save
    validate(submit) {
        const messages = [];
        const chosen = this.lines.filter((l) => l.productId);
        if (!chosen.length) {
            messages.push('Adicione ao menos um produto.');
        }
        if (this.lines.some((l) => !l.productId)) {
            messages.push('Selecione o produto em todas as linhas (ou remova as linhas vazias).');
        }
        if (this.lines.some((l) => !Number.isInteger(Number(l.quantity)) || Number(l.quantity) < 1)) {
            messages.push('A quantidade deve ser um número inteiro maior ou igual a 1.');
        }
        if (new Set(chosen.map((l) => l.productId)).size !== chosen.length) {
            messages.push('Não é permitido repetir o mesmo produto.');
        }
        if (this.discountPercent < 0 || this.discountPercent > MAX_DISCOUNT) {
            messages.push('O desconto deve estar entre 0% e 30%.');
        }
        if (submit && this.requiresJustification && !(this.justification || '').trim()) {
            messages.push('Informe a justificativa do desconto (obrigatória acima de 5%).');
        }
        return messages;
    }

    async save(submit) {
        this.errors = this.validate(submit);
        if (this.errors.length) {
            return;
        }
        this.saving = true;
        try {
            // O navegador envia apenas produto/quantidade/desconto: preços e totais NUNCA são enviados.
            const request = {
                negotiationId: this.currentNegotiationId,
                opportunityId: this.oppId,
                discountPercent: this.discountPercent,
                justification: this.justification,
                items: this.lines.map((l) => ({ productId: l.productId, quantity: parseInt(l.quantity, 10) }))
            };
            const result = await saveNegotiation({ requestJson: JSON.stringify(request), submit });
            this.currentNegotiationId = result.negotiationId;
            this.dispatchEvent(new ShowToastEvent({ title: 'Sucesso', message: result.message, variant: 'success' }));
            this.dispatchEvent(new CustomEvent('saved', { detail: { negotiationId: result.negotiationId, status: result.status } }));
            if (submit) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: { recordId: result.negotiationId, objectApiName: 'Negociacao_Comercial__c', actionName: 'view' }
                });
            }
        } catch (error) {
            this.errors = [this.reduceError(error)];
        } finally {
            this.saving = false;
        }
    }

    reduceError(error) {
        if (error && error.body) {
            if (Array.isArray(error.body)) {
                return error.body.map((e) => e.message).join(', ');
            }
            if (error.body.message) {
                return error.body.message;
            }
        }
        return (error && error.message) || 'Erro inesperado.';
    }
}