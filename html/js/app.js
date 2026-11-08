const app = document.getElementById('app');
const playerName = document.getElementById('playerName');
const accountNumber = document.getElementById('accountNumber');
const cashBalance = document.getElementById('cashBalance');
const bankBalance = document.getElementById('bankBalance');
const totalBalance = document.getElementById('totalBalance');
const transactionList = document.getElementById('transactionList');
const resourceName = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'bc-banking';

let currencySymbol = '$';
let currentIsATM = false;

function money(value) {
    const amount = Number(value || 0);
    const formatted = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
        .format(Number.isFinite(amount) ? amount : 0);
    return currencySymbol + formatted;
}

async function nui(endpoint, data = {}) {
    const idempotentEndpoints = ['v2Transfer', 'fundV2Account', 'withdrawV2Account', 'contributeGoal', 'repayLoan', 'payroll', 'repayBusinessLoan', 'businessExpense'];
    if (idempotentEndpoints.includes(endpoint)) {
        const key = window.crypto && typeof window.crypto.randomUUID === 'function'
            ? window.crypto.randomUUID()
            : Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
        data = { ...data, idempotencyKey: key };
    }
    const response = await fetch('https://' + resourceName + '/' + endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
    });
    return response.json().catch(() => ({}));
}

function escapeHtml(value) {
    return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;').replaceAll("'", '&#039;');
}

function renderTransactions(transactions) {
    transactionList.innerHTML = '';
    if (!Array.isArray(transactions) || transactions.length === 0) {
        transactionList.innerHTML = '<div class="empty">No transactions found.</div>';
        return;
    }
    transactions.forEach(transaction => {
        const amount = Number(transaction.amount || 0);
        const income = ['deposit', 'transfer_in'].includes(transaction.transaction_type);
        const row = document.createElement('div');
        row.className = 'transaction';
        row.innerHTML = '<div class="transaction-info"><strong>' +
            escapeHtml(transaction.description || 'Bank Transaction') + '</strong><span>' +
            escapeHtml(transaction.transaction_type || 'transaction') +
            (transaction.related_account ? ' • Account ' + escapeHtml(transaction.related_account) : '') +
            '</span></div><div class="transaction-amount ' + (income ? 'income' : 'expense') + '">' +
            (income ? '+' : '-') + money(amount) + '</div>';
        transactionList.appendChild(row);
    });
}

function render(data) {
    if (!data) return;
    if (data.currency) currencySymbol = String(data.currency);
    if (data.player) playerName.textContent = data.player.name || 'Citizen';
    if (data.account) accountNumber.textContent = data.account.account_number || '----------';
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
    if (message.action === 'refreshV2') refreshV2();
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

function listRows(target, rows, renderRow, empty) {
    const element = document.getElementById(target);
    if (!element) return;
    element.innerHTML = '';
    if (!Array.isArray(rows) || rows.length === 0) {
        element.textContent = empty;
        return;
    }
    rows.forEach(item => {
        const row = document.createElement('div');
        row.className = 'v2-row';
        row.innerHTML = renderRow(item);
        element.appendChild(row);
    });
}

async function refreshV2() {
    const results = await Promise.all([
        nui('v2Accounts'), nui('v2Goals'), nui('v2Cards'), nui('v2Loans'),
        nui('v2Businesses'), nui('v2ScheduledPayments'), nui('v2BusinessLoans')
    ]);
    const accounts = results[0] || [];
    const goals = results[1] || [];
    const cards = results[2] || [];
    const loans = results[3] || [];
    const businesses = results[4] || [];
    const schedules = results[5] || [];
    const businessLoans = results[6] || [];
    const businessIdInput = document.getElementById('businessId');
    if (businessIdInput && !businessIdInput.value && businesses.length) businessIdInput.value = businesses[0].id;
    const businessExpenses = await nui('v2BusinessExpenses', { businessId: Number(businessIdInput && businessIdInput.value) });

    const sourceSelect = document.getElementById('v2SourceAccount');
    if (sourceSelect) {
        const current = sourceSelect.value;
        sourceSelect.innerHTML = '<option value="">Select source account</option>';
        accounts.forEach(account => {
            const option = document.createElement('option');
            option.value = account.id;
            option.textContent = account.display_name + ' • ' + account.account_number + ' • ' + money(account.balance);
            sourceSelect.appendChild(option);
        });
        if (current) sourceSelect.value = current;
    }

    listRows('v2Accounts', accounts, account =>
        '<strong>' + escapeHtml(account.display_name) + '</strong><span>' +
        escapeHtml(account.account_type) + ' • ' + escapeHtml(account.account_number) +
        '</span><b>' + money(account.balance) + '</b>', 'No additional accounts yet.');

    listRows('v2Goals', goals, goal =>
        '<strong>' + escapeHtml(goal.name) + '</strong><span>#' + escapeHtml(goal.id) +
        ' • ' + escapeHtml(goal.status) + '</span><b>' + money(goal.current_amount) +
        ' / ' + money(goal.target_amount) + '</b>', 'No savings goals yet.');

    listRows('v2Cards', cards, card =>
        '<strong>•••• ' + escapeHtml(card.card_last4) + '</strong><span>' +
        escapeHtml(card.card_type) + ' • ' + escapeHtml(card.status) + ' • ID ' +
        escapeHtml(card.id) + '</span><button class="mini-button" data-card-id="' +
        escapeHtml(card.id) + '" data-frozen="' + (card.status === 'frozen' ? '1' : '0') +
        '">' + (card.status === 'frozen' ? 'Unfreeze' : 'Freeze') + '</button>', 'No cards issued yet.');

    listRows('v2Loans', loans, loan =>
        '<strong>Loan #' + escapeHtml(loan.id) + '</strong><span>' +
        escapeHtml(loan.status) + ' • ' + escapeHtml(loan.term_months) +
        ' months</span><b>' + money(loan.balance_due || loan.principal) + '</b>', 'No loan applications yet.');

    listRows('v2Businesses', businesses, business =>
        '<strong>' + escapeHtml(business.name) + '</strong><span>' +
        escapeHtml(business.role) + ' • Business #' + escapeHtml(business.id) +
        '</span>', 'No business accounts yet.');

    listRows('v2Schedules', schedules, payment =>
        '<strong>Payment #' + escapeHtml(payment.id) + '</strong><span>' +
        escapeHtml(payment.frequency) + ' • ' + escapeHtml(payment.status) +
        ' • ' + escapeHtml(payment.next_run_at) + '</span><b>' + money(payment.amount) +
        '</b><button class="mini-button" data-schedule-id="' + escapeHtml(payment.id) +
        '">Cancel</button>', 'No scheduled payments yet.');

    listRows('v2BusinessExpenses', businessExpenses, expense =>
        '<strong>' + escapeHtml(expense.category) + ' • ' + money(expense.amount) + '</strong><span>' + escapeHtml(expense.description) + ' • ' + escapeHtml(expense.created_at) + '</span>', 'No business expenses found for this business.');

    listRows('v2BusinessLoans', businessLoans, loan =>
        '<strong>Business loan #' + escapeHtml(loan.id) + ' • ' + escapeHtml(loan.business_name) +
        '</strong><span>' + escapeHtml(loan.status) + ' • ' + escapeHtml(loan.term_months) +
        ' months</span><b>' + money(loan.balance_due || loan.principal) + '</b>',
        'No business loan applications yet.');
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
bindV2('v2TransferButton', 'v2Transfer', () => ({
    accountId: Number(document.getElementById('v2SourceAccount').value),
    recipient: document.getElementById('v2Recipient').value.trim(),
    amount: Number(document.getElementById('v2TransferAmount').value),
    description: document.getElementById('v2TransferDescription').value.trim()
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
bindV2('createGoalButton', 'createGoal', () => ({
    name: document.getElementById('goalName').value.trim(),
    target: Number(document.getElementById('goalTarget').value)
}));
bindV2('contributeGoalButton', 'contributeGoal', () => ({
    goalId: Number(document.getElementById('goalId').value),
    amount: Number(document.getElementById('goalContribution').value)
}));
bindV2('issueCardButton', 'issueCard', () => ({
    accountId: Number(document.getElementById('cardAccountId').value),
    cardType: document.getElementById('cardType').value
}));
bindV2('setCardPinButton', 'setCardPin', () => ({
    cardId: Number(document.getElementById('pinCardId').value),
    pin: document.getElementById('cardPin').value
}));
bindV2('replaceCardButton', 'replaceCard', () => ({
    cardId: Number(document.getElementById('pinCardId').value)
}));
bindV2('applyLoanButton', 'applyLoan', () => ({
    amount: Number(document.getElementById('loanAmount').value),
    months: Number(document.getElementById('loanMonths').value)
}));
bindV2('repayLoanButton', 'repayLoan', () => ({
    loanId: Number(document.getElementById('repayLoanId').value),
    amount: Number(document.getElementById('repayLoanAmount').value)
}));
bindV2('recordExpenseButton', 'businessExpense', () => ({
    businessId: Number(document.getElementById('businessId').value),
    amount: Number(document.getElementById('expenseAmount').value),
    category: document.getElementById('expenseCategory').value.trim(),
    description: document.getElementById('expenseDescription').value.trim()
}));
bindV2('applyBusinessLoanButton', 'applyBusinessLoan', () => ({
    businessId: Number(document.getElementById('businessId').value),
    amount: Number(document.getElementById('businessLoanAmount').value),
    months: Number(document.getElementById('businessLoanMonths').value)
}));
bindV2('repayBusinessLoanButton', 'repayBusinessLoan', () => ({
    loanId: Number(document.getElementById('businessLoanId').value),
    amount: Number(document.getElementById('businessLoanRepayment').value)
}));
bindV2('createBusinessButton', 'createBusiness', () => ({
    name: document.getElementById('businessName').value.trim()
}));
bindV2('payrollButton', 'payroll', () => ({
    businessId: Number(document.getElementById('businessId').value),
    citizenid: document.getElementById('employeeCitizenId').value.trim(),
    amount: Number(document.getElementById('employeeAmount').value)
}));
bindV2('addEmployeeButton', 'addBusinessEmployee', () => {
    const parts = document.getElementById('employeePermissions').value.split(',').map(value => value.trim());
    return {
        businessId: Number(document.getElementById('businessId').value),
        citizenid: document.getElementById('employeeCitizenId').value.trim(),
        permissions: Object.fromEntries(['view', 'deposit', 'withdraw', 'transfer', 'payroll'].map(key => [key, parts.includes(key)]))
    };
});
bindV2('createScheduleButton', 'createScheduledPayment', () => ({
    sourceAccountId: Number(document.getElementById('scheduleSource').value),
    destinationAccountId: Number(document.getElementById('scheduleDestination').value),
    amount: Number(document.getElementById('scheduleAmount').value),
    nextRunAt: document.getElementById('scheduleDate').value.replace('T', ' ') + ':00',
    frequency: document.getElementById('scheduleFrequency').value,
    description: document.getElementById('scheduleDescription').value.trim()
}));

document.getElementById('refreshLedgerButton').addEventListener('click', async () => {
    const accountId = Number(document.getElementById('v2SourceAccount').value);
    if (!accountId) {
        listRows('v2Ledger', [], () => '', 'Select an account first.');
        return;
    }
    const entries = await nui('v2Ledger', { accountId });
    listRows('v2Ledger', entries, entry =>
        '<strong>' + escapeHtml(entry.entry_type) + ' • ' + money(entry.amount) +
        '</strong><span>' + escapeHtml(entry.description || 'Account activity') +
        ' • ' + escapeHtml(entry.created_at) + '</span><b>Balance after: ' +
        money(entry.balance_after) + '</b>', 'No statement entries found.');
});

document.addEventListener('click', async event => {
    const cardButton = event.target.closest('[data-card-id]');
    if (cardButton) {
        await nui('setCardStatus', {
            cardId: Number(cardButton.dataset.cardId),
            frozen: cardButton.dataset.frozen !== '1'
        });
        window.setTimeout(refreshV2, 700);
        return;
    }
    const scheduleButton = event.target.closest('[data-schedule-id]');
    if (scheduleButton) {
        await nui('cancelScheduledPayment', { id: Number(scheduleButton.dataset.scheduleId) });
        window.setTimeout(refreshV2, 700);
    }
});
