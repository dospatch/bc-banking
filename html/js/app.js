const app = document.getElementById('app');

const playerName = document.getElementById('playerName');
const accountNumber = document.getElementById('accountNumber');

const cashBalance = document.getElementById('cashBalance');
const bankBalance = document.getElementById('bankBalance');
const totalBalance = document.getElementById('totalBalance');

const transactionList = document.getElementById('transactionList');

const resourceName = typeof GetParentResourceName === 'function'
    ? GetParentResourceName()
    : 'bc-banking';

let currencySymbol = '

function money(value) {
    const amount = Number(value || 0);
    const formatted = new Intl.NumberFormat('en-US', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
    }).format(Number.isFinite(amount) ? amount : 0);

    return `${currencySymbol}${formatted}`;
}

async function nui(endpoint, data = {}) {
    const response = await fetch(`https://${resourceName}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
    });

    return response.json().catch(() => ({}));
}

function escapeHtml(value) {
    return String(value)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#039;');
}

function renderTransactions(transactions) {
    transactionList.innerHTML = '';

    if (!transactions || transactions.length === 0) {
        transactionList.innerHTML = '<div class="empty">No transactions found.</div>';
        return;
    }

    transactions.forEach(transaction => {
        const amount = Number(transaction.amount || 0);
        const income = ['deposit', 'transfer_in'].includes(transaction.transaction_type);
        const row = document.createElement('div');
        row.className = 'transaction';
        row.innerHTML = `
            <div class="transaction-info">
                <strong>${escapeHtml(transaction.description || 'Bank Transaction')}</strong>
                <span>
                    ${escapeHtml(transaction.transaction_type || 'transaction')}
                    ${transaction.related_account
                        ? ` • Account ${escapeHtml(transaction.related_account)}`
                        : ''}
                </span>
            </div>
            <div class="transaction-amount ${income ? 'income' : 'expense'}">
                ${income ? '+' : '-'}${money(amount)}
            </div>
        `;
        transactionList.appendChild(row);
    });
}

function render(data) {
    if (!data) return;

    if (data.currency) currencySymbol = String(data.currency);
    if (data.player) playerName.textContent = data.player.name || 'Citizen';
    if (data.account) {
        accountNumber.textContent = data.account.account_number || '----------';
    }

    const cash = Number(data.cash || 0);
    const bank = Number(data.bank || 0);
    cashBalance.textContent = money(cash);
    bankBalance.textContent = money(bank);
    totalBalance.textContent = money(cash + bank);
    renderTransactions(data.transactions || []);
}

window.addEventListener('message', event => {
    const message = event.data;
    if (!message) return;

    if (message.action === 'open') {
        currentIsATM = message.isATM === true;
        app.classList.remove('hidden');
        render(message.data);
        refreshV2();
    }

    if (message.action === 'close') app.classList.add('hidden');
});

document.getElementById('closeButton').addEventListener('click', () => {
    nui('close');
    app.classList.add('hidden');
});

document.getElementById('depositButton').addEventListener('click', async () => {
    const amount = Number(document.getElementById('depositAmount').value);
    if (!Number.isFinite(amount) || amount <= 0) return;
    await nui('deposit', { amount, isATM: currentIsATM });
    document.getElementById('depositAmount').value = '';
    window.setTimeout(refresh, 500);
});

document.getElementById('withdrawButton').addEventListener('click', async () => {
    const amount = Number(document.getElementById('withdrawAmount').value);
    if (!Number.isFinite(amount) || amount <= 0) return;
    await nui('withdraw', { amount, isATM: currentIsATM });
    document.getElementById('withdrawAmount').value = '';
    window.setTimeout(refresh, 500);
});

document.getElementById('transferButton').addEventListener('click', async () => {
    const account = document.getElementById('transferAccount').value.trim();
    const amount = Number(document.getElementById('transferAmount').value);
    const description = document.getElementById('transferDescription').value.trim();

    if (!account || !Number.isFinite(amount) || amount <= 0) return;

    await nui('transfer', { account, amount, description });
    document.getElementById('transferAccount').value = '';
    document.getElementById('transferAmount').value = '';
    document.getElementById('transferDescription').value = '';
    window.setTimeout(refresh, 700);
});

document.getElementById('refreshButton').addEventListener('click', refresh);

async function refresh() {
    const data = await nui('refresh');
    render(data);
}

document.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
        nui('close');
        app.classList.add('hidden');
    }
});


// V2 feature panels
function listRows(target, rows, renderRow, empty) {
    const el = document.getElementById(target);
    if (!el) return;
    el.innerHTML = '';
    if (!Array.isArray(rows) || !rows.length) {
        el.textContent = empty;
        return;
    }
    rows.forEach(item => {
        const row = document.createElement('div');
        row.className = 'v2-row';
        row.innerHTML = renderRow(item);
        el.appendChild(row);
    });
}

async function refreshV2() {
    const [accounts, goals, cards, loans, businesses, schedules] = await Promise.all([
        nui('v2Accounts'), nui('v2Goals'), nui('v2Cards'), nui('v2Loans'), nui('v2Businesses'), nui('v2ScheduledPayments')
    ]);
    const sourceSelect = document.getElementById('v2SourceAccount');
    if (sourceSelect) {
        const current = sourceSelect.value;
        sourceSelect.innerHTML = '<option value="">Select source account</option>';
        (accounts || []).forEach(a => {
            const option = document.createElement('option');
            option.value = a.id;
            option.textContent = a.display_name + ' • ' + a.account_number + ' • ' + money(a.balance);
            sourceSelect.appendChild(option);
        });
        if (current) sourceSelect.value = current;
    }
    listRows('v2Accounts', accounts, a =>
        '<strong>' + escapeHtml(a.display_name) + '</strong><span>' + escapeHtml(a.account_type) + ' • ' +
        escapeHtml(a.account_number) + '</span><b>' + money(a.balance) + '</b>', 'No additional accounts yet.');
    listRows('v2Goals', goals, g =>
        '<strong>' + escapeHtml(g.name) + '</strong><span>#' + escapeHtml(g.id) + ' • ' +
        escapeHtml(g.status) + '</span><b>' + money(g.current_amount) + ' / ' + money(g.target_amount) + '</b>', 'No savings goals yet.');
    listRows('v2Cards', cards, c =>
        '<strong>•••• ' + escapeHtml(c.card_last4) + '</strong><span>' + escapeHtml(c.card_type) + ' • ' +
        escapeHtml(c.status) + ' • ID ' + escapeHtml(c.id) + '</span><button class="mini-button" data-card-id="' +
        escapeHtml(c.id) + '" data-frozen="' + (c.status === 'frozen' ? '1' : '0') + '">' +
        (c.status === 'frozen' ? 'Unfreeze' : 'Freeze') + '</button>', 'No cards issued yet.');
    listRows('v2Loans', loans, l =>
        '<strong>Loan #' + escapeHtml(l.id) + '</strong><span>' + escapeHtml(l.status) + ' • ' +
        escapeHtml(l.term_months) + ' months</span><b>' + money(l.principal) + '</b>', 'No loan applications yet.');
    listRows('v2Schedules', schedules, p =>
        '<strong>Payment #' + escapeHtml(p.id) + '</strong><span>' + escapeHtml(p.frequency) + ' • ' + escapeHtml(p.status) + ' • ' + escapeHtml(p.next_run_at) + '</span><b>' + money(p.amount) + '</b>', 'No scheduled payments yet.');
    listRows('v2Businesses', businesses, b =>
        '<strong>' + escapeHtml(b.name) + '</strong><span>' + escapeHtml(b.role) + ' • Business #' +
        escapeHtml(b.id) + '</span>', 'No business accounts yet.');
}

function bindV2(id, endpoint, values) {
    const button = document.getElementById(id);
    if (!button) return;
    button.addEventListener('click', async () => {
        await nui(endpoint, values());
        window.setTimeout(refreshV2, 700);
    });
}

bindV2('createAccountButton', 'createV2Account', () => ({
    type: document.getElementById('newAccountType').value,
    name: document.getElementById('newAccountName').value.trim()
}));
bindV2('fundAccountButton', 'fundV2Account', () => ({
    accountId: Number(document.getElementById('v2SourceAccount').value),
    amount: Number(document.getElementById('fundAmount').value),
    source: document.getElementById('fundSource').value
}));
bindV2('withdrawAccountButton', 'withdrawV2Account', () => ({
    accountId: Number(document.getElementById('v2SourceAccount').value),
    amount: Number(document.getElementById('accountWithdrawAmount').value),
    destination: document.getElementById('withdrawDestination').value
}));
bindV2('v2TransferButton', 'v2Transfer', () => ({
    accountId: Number(document.getElementById('v2SourceAccount').value),
    recipient: document.getElementById('v2Recipient').value.trim(),
    amount: Number(document.getElementById('v2TransferAmount').value),
    description: document.getElementById('v2TransferDescription').value.trim()
}));
bindV2('createGoalButton', 'createGoal', () => ({
    name: document.getElementById('goalName').value.trim(),
    target: Number(document.getElementById('goalTarget').value)
}));
bindV2('contributeGoalButton', 'contributeGoal', () => ({
    goalId: Number(document.getElementById('goalId').value),
    amount: Number(document.getElementById('goalContribution').value)
}));
bindV2('setCardPinButton', 'setCardPin', () => ({
    cardId: Number(document.getElementById('pinCardId').value),
    pin: document.getElementById('cardPin').value
}));
bindV2('replaceCardButton', 'replaceCard', () => ({
    cardId: Number(document.getElementById('pinCardId').value)
}));
bindV2('issueCardButton', 'issueCard', () => ({
    accountId: Number(document.getElementById('cardAccountId').value)
}));
bindV2('repayLoanButton', 'repayLoan', () => ({
    loanId: Number(document.getElementById('repayLoanId').value),
    amount: Number(document.getElementById('repayLoanAmount').value)
}));
bindV2('addEmployeeButton', 'addBusinessEmployee', () => {
    const parts = document.getElementById('employeePermissions').value.split(',').map(x => x.trim());
    return { businessId: Number(document.getElementById('businessId').value), citizenid: document.getElementById('employeeCitizenId').value.trim(), permissions: Object.fromEntries(['view','deposit','withdraw','transfer','payroll'].map(k => [k, parts.includes(k)])) };
});
bindV2('createScheduleButton', 'createScheduledPayment', () => ({
    sourceAccountId: Number(document.getElementById('scheduleSource').value),
    destinationAccountId: Number(document.getElementById('scheduleDestination').value),
    amount: Number(document.getElementById('scheduleAmount').value),
    nextRunAt: document.getElementById('scheduleDate').value.replace('T', ' ') + ':00',
    frequency: document.getElementById('scheduleFrequency').value,
    description: document.getElementById('scheduleDescription').value.trim()
}));
bindV2('applyLoanButton', 'applyLoan', () => ({
    amount: Number(document.getElementById('loanAmount').value),
    months: Number(document.getElementById('loanMonths').value)
}));
bindV2('createBusinessButton', 'createBusiness', () => ({
    name: document.getElementById('businessName').value.trim()
}));
bindV2('payrollButton', 'payroll', () => ({
    businessId: Number(document.getElementById('businessId').value),
    citizenid: document.getElementById('employeeCitizenId').value.trim(),
    amount: Number(document.getElementById('employeeAmount').value)
}));

document.addEventListener('click', async event => {
    const button = event.target.closest('[data-card-id]');
    if (!button) return;
    await nui('setCardStatus', {
        cardId: Number(button.dataset.cardId),
        frozen: button.dataset.frozen !== '1'
    });
    window.setTimeout(refreshV2, 700);
});

window.addEventListener('message', event => {
    if (event.data && event.data.action === 'refreshV2') refreshV2();
});
;
let currentIsATM = false;

function money(value) {
    const amount = Number(value || 0);
    const formatted = new Intl.NumberFormat('en-US', {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
    }).format(Number.isFinite(amount) ? amount : 0);

    return `${currencySymbol}${formatted}`;
}

async function nui(endpoint, data = {}) {
    const response = await fetch(`https://${resourceName}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
    });

    return response.json().catch(() => ({}));
}

function escapeHtml(value) {
    return String(value)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#039;');
}

function renderTransactions(transactions) {
    transactionList.innerHTML = '';

    if (!transactions || transactions.length === 0) {
        transactionList.innerHTML = '<div class="empty">No transactions found.</div>';
        return;
    }

    transactions.forEach(transaction => {
        const amount = Number(transaction.amount || 0);
        const income = ['deposit', 'transfer_in'].includes(transaction.transaction_type);
        const row = document.createElement('div');
        row.className = 'transaction';
        row.innerHTML = `
            <div class="transaction-info">
                <strong>${escapeHtml(transaction.description || 'Bank Transaction')}</strong>
                <span>
                    ${escapeHtml(transaction.transaction_type || 'transaction')}
                    ${transaction.related_account
                        ? ` • Account ${escapeHtml(transaction.related_account)}`
                        : ''}
                </span>
            </div>
            <div class="transaction-amount ${income ? 'income' : 'expense'}">
                ${income ? '+' : '-'}${money(amount)}
            </div>
        `;
        transactionList.appendChild(row);
    });
}

function render(data) {
    if (!data) return;

    if (data.currency) currencySymbol = String(data.currency);
    if (data.player) playerName.textContent = data.player.name || 'Citizen';
    if (data.account) {
        accountNumber.textContent = data.account.account_number || '----------';
    }

    const cash = Number(data.cash || 0);
    const bank = Number(data.bank || 0);
    cashBalance.textContent = money(cash);
    bankBalance.textContent = money(bank);
    totalBalance.textContent = money(cash + bank);
    renderTransactions(data.transactions || []);
}

window.addEventListener('message', event => {
    const message = event.data;
    if (!message) return;

    if (message.action === 'open') {
        app.classList.remove('hidden');
        render(message.data);
        refreshV2();
    }

    if (message.action === 'close') app.classList.add('hidden');
});

document.getElementById('closeButton').addEventListener('click', () => {
    nui('close');
    app.classList.add('hidden');
});

document.getElementById('depositButton').addEventListener('click', async () => {
    const amount = Number(document.getElementById('depositAmount').value);
    if (!Number.isFinite(amount) || amount <= 0) return;
    await nui('deposit', { amount });
    document.getElementById('depositAmount').value = '';
    window.setTimeout(refresh, 500);
});

document.getElementById('withdrawButton').addEventListener('click', async () => {
    const amount = Number(document.getElementById('withdrawAmount').value);
    if (!Number.isFinite(amount) || amount <= 0) return;
    await nui('withdraw', { amount });
    document.getElementById('withdrawAmount').value = '';
    window.setTimeout(refresh, 500);
});

document.getElementById('transferButton').addEventListener('click', async () => {
    const account = document.getElementById('transferAccount').value.trim();
    const amount = Number(document.getElementById('transferAmount').value);
    const description = document.getElementById('transferDescription').value.trim();

    if (!account || !Number.isFinite(amount) || amount <= 0) return;

    await nui('transfer', { account, amount, description });
    document.getElementById('transferAccount').value = '';
    document.getElementById('transferAmount').value = '';
    document.getElementById('transferDescription').value = '';
    window.setTimeout(refresh, 700);
});

document.getElementById('refreshButton').addEventListener('click', refresh);

async function refresh() {
    const data = await nui('refresh');
    render(data);
}

document.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
        nui('close');
        app.classList.add('hidden');
    }
});


// V2 feature panels
function listRows(target, rows, renderRow, empty) {
    const el = document.getElementById(target);
    if (!el) return;
    el.innerHTML = '';
    if (!Array.isArray(rows) || !rows.length) {
        el.textContent = empty;
        return;
    }
    rows.forEach(item => {
        const row = document.createElement('div');
        row.className = 'v2-row';
        row.innerHTML = renderRow(item);
        el.appendChild(row);
    });
}

async function refreshV2() {
    const [accounts, goals, cards, loans, businesses, schedules] = await Promise.all([
        nui('v2Accounts'), nui('v2Goals'), nui('v2Cards'), nui('v2Loans'), nui('v2Businesses'), nui('v2ScheduledPayments')
    ]);
    const sourceSelect = document.getElementById('v2SourceAccount');
    if (sourceSelect) {
        const current = sourceSelect.value;
        sourceSelect.innerHTML = '<option value="">Select source account</option>';
        (accounts || []).forEach(a => {
            const option = document.createElement('option');
            option.value = a.id;
            option.textContent = a.display_name + ' • ' + a.account_number + ' • ' + money(a.balance);
            sourceSelect.appendChild(option);
        });
        if (current) sourceSelect.value = current;
    }
    listRows('v2Accounts', accounts, a =>
        '<strong>' + escapeHtml(a.display_name) + '</strong><span>' + escapeHtml(a.account_type) + ' • ' +
        escapeHtml(a.account_number) + '</span><b>' + money(a.balance) + '</b>', 'No additional accounts yet.');
    listRows('v2Goals', goals, g =>
        '<strong>' + escapeHtml(g.name) + '</strong><span>#' + escapeHtml(g.id) + ' • ' +
        escapeHtml(g.status) + '</span><b>' + money(g.current_amount) + ' / ' + money(g.target_amount) + '</b>', 'No savings goals yet.');
    listRows('v2Cards', cards, c =>
        '<strong>•••• ' + escapeHtml(c.card_last4) + '</strong><span>' + escapeHtml(c.card_type) + ' • ' +
        escapeHtml(c.status) + ' • ID ' + escapeHtml(c.id) + '</span><button class="mini-button" data-card-id="' +
        escapeHtml(c.id) + '" data-frozen="' + (c.status === 'frozen' ? '1' : '0') + '">' +
        (c.status === 'frozen' ? 'Unfreeze' : 'Freeze') + '</button>', 'No cards issued yet.');
    listRows('v2Loans', loans, l =>
        '<strong>Loan #' + escapeHtml(l.id) + '</strong><span>' + escapeHtml(l.status) + ' • ' +
        escapeHtml(l.term_months) + ' months</span><b>' + money(l.principal) + '</b>', 'No loan applications yet.');
    listRows('v2Schedules', schedules, p =>
        '<strong>Payment #' + escapeHtml(p.id) + '</strong><span>' + escapeHtml(p.frequency) + ' • ' + escapeHtml(p.status) + ' • ' + escapeHtml(p.next_run_at) + '</span><b>' + money(p.amount) + '</b>', 'No scheduled payments yet.');
    listRows('v2Businesses', businesses, b =>
        '<strong>' + escapeHtml(b.name) + '</strong><span>' + escapeHtml(b.role) + ' • Business #' +
        escapeHtml(b.id) + '</span>', 'No business accounts yet.');
}

function bindV2(id, endpoint, values) {
    const button = document.getElementById(id);
    if (!button) return;
    button.addEventListener('click', async () => {
        await nui(endpoint, values());
        window.setTimeout(refreshV2, 700);
    });
}

bindV2('createAccountButton', 'createV2Account', () => ({
    type: document.getElementById('newAccountType').value,
    name: document.getElementById('newAccountName').value.trim()
}));
bindV2('fundAccountButton', 'fundV2Account', () => ({
    accountId: Number(document.getElementById('v2SourceAccount').value),
    amount: Number(document.getElementById('fundAmount').value),
    source: document.getElementById('fundSource').value
}));
bindV2('withdrawAccountButton', 'withdrawV2Account', () => ({
    accountId: Number(document.getElementById('v2SourceAccount').value),
    amount: Number(document.getElementById('accountWithdrawAmount').value),
    destination: document.getElementById('withdrawDestination').value
}));
bindV2('v2TransferButton', 'v2Transfer', () => ({
    accountId: Number(document.getElementById('v2SourceAccount').value),
    recipient: document.getElementById('v2Recipient').value.trim(),
    amount: Number(document.getElementById('v2TransferAmount').value),
    description: document.getElementById('v2TransferDescription').value.trim()
}));
bindV2('createGoalButton', 'createGoal', () => ({
    name: document.getElementById('goalName').value.trim(),
    target: Number(document.getElementById('goalTarget').value)
}));
bindV2('contributeGoalButton', 'contributeGoal', () => ({
    goalId: Number(document.getElementById('goalId').value),
    amount: Number(document.getElementById('goalContribution').value)
}));
bindV2('setCardPinButton', 'setCardPin', () => ({
    cardId: Number(document.getElementById('pinCardId').value),
    pin: document.getElementById('cardPin').value
}));
bindV2('replaceCardButton', 'replaceCard', () => ({
    cardId: Number(document.getElementById('pinCardId').value)
}));
bindV2('issueCardButton', 'issueCard', () => ({
    accountId: Number(document.getElementById('cardAccountId').value)
}));
bindV2('repayLoanButton', 'repayLoan', () => ({
    loanId: Number(document.getElementById('repayLoanId').value),
    amount: Number(document.getElementById('repayLoanAmount').value)
}));
bindV2('addEmployeeButton', 'addBusinessEmployee', () => {
    const parts = document.getElementById('employeePermissions').value.split(',').map(x => x.trim());
    return { businessId: Number(document.getElementById('businessId').value), citizenid: document.getElementById('employeeCitizenId').value.trim(), permissions: Object.fromEntries(['view','deposit','withdraw','transfer','payroll'].map(k => [k, parts.includes(k)])) };
});
bindV2('createScheduleButton', 'createScheduledPayment', () => ({
    sourceAccountId: Number(document.getElementById('scheduleSource').value),
    destinationAccountId: Number(document.getElementById('scheduleDestination').value),
    amount: Number(document.getElementById('scheduleAmount').value),
    nextRunAt: document.getElementById('scheduleDate').value.replace('T', ' ') + ':00',
    frequency: document.getElementById('scheduleFrequency').value,
    description: document.getElementById('scheduleDescription').value.trim()
}));
bindV2('applyLoanButton', 'applyLoan', () => ({
    amount: Number(document.getElementById('loanAmount').value),
    months: Number(document.getElementById('loanMonths').value)
}));
bindV2('createBusinessButton', 'createBusiness', () => ({
    name: document.getElementById('businessName').value.trim()
}));
bindV2('payrollButton', 'payroll', () => ({
    businessId: Number(document.getElementById('businessId').value),
    citizenid: document.getElementById('employeeCitizenId').value.trim(),
    amount: Number(document.getElementById('employeeAmount').value)
}));

document.addEventListener('click', async event => {
    const button = event.target.closest('[data-card-id]');
    if (!button) return;
    await nui('setCardStatus', {
        cardId: Number(button.dataset.cardId),
        frozen: button.dataset.frozen !== '1'
    });
    window.setTimeout(refreshV2, 700);
});

window.addEventListener('message', event => {
    if (event.data && event.data.action === 'refreshV2') refreshV2();
});
