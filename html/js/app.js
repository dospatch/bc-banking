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

let currencySymbol = '$';

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
