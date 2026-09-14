const app = document.getElementById('app');
const $ = (id) => document.getElementById(id);

function money(value) {
    return '$' + Math.floor(Number(value || 0)).toLocaleString('en-US');
}

function post(name, data = {}) {
    return fetch(`https://${GetParentResourceName()}/${name}`, {
        method: 'POST',
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: JSON.stringify(data)
    });
}

function render(data) {
    if (!data || !data.player) return;
    const p = data.player;
    $('name').textContent = p.name || 'Citizen';
    $('job').textContent = p.job || 'Citizen';
    $('citizenid').textContent = p.citizenid || '—';
    $('balance').textContent = money(p.bank);
    $('cash').textContent = money(p.cash);
    $('account').textContent = 'Citizen banking account';

    const list = $('transactions');
    list.innerHTML = '';
    const txs = data.transactions || [];
    $('count').textContent = `${txs.length} transaction${txs.length === 1 ? '' : 's'}`;

    if (!txs.length) {
        list.innerHTML = '<div class="empty">No transactions yet.</div>';
        return;
    }

    txs.forEach(tx => {
        const positive = ['deposit', 'transfer_received'].includes(tx.type);
        const row = document.createElement('div');
        row.className = 'transaction';
        const icon = tx.type === 'deposit' ? '+' : tx.type === 'withdraw' ? '−' : '↔';
        row.innerHTML = `
            <div class="tx-icon">${icon}</div>
            <div>
                <div class="tx-desc">${escapeHtml(tx.description || tx.type)}</div>
                <div class="tx-date">${formatDate(tx.created_at)}</div>
            </div>
            <div class="tx-amount ${positive ? 'positive' : 'negative'}">${positive ? '+' : '-'}${money(tx.amount)}</div>
        `;
        list.appendChild(row);
    });
}

function escapeHtml(value) {
    return String(value).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#039;','"':'&quot;'}[c]));
}

function formatDate(value) {
    if (!value) return 'Unknown date';
    const d = new Date(String(value).replace(' ', 'T') + 'Z');
    return Number.isNaN(d.getTime()) ? value : d.toLocaleString();
}

window.addEventListener('message', (event) => {
    const {action, data} = event.data || {};
    if (action === 'open') app.classList.remove('hidden');
    if (action === 'close') app.classList.add('hidden');
    if (action === 'setData') render(data);
});

$('close').addEventListener('click', () => post('close'));
$('refresh').addEventListener('click', () => post('refresh'));

$('depositForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const amount = Number($('depositAmount').value);
    if (amount > 0) post('deposit', {amount});
    e.target.reset();
});

$('withdrawForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const amount = Number($('withdrawAmount').value);
    if (amount > 0) post('withdraw', {amount});
    e.target.reset();
});

$('transferForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const target = Number($('target').value);
    const amount = Number($('transferAmount').value);
    if (target > 0 && amount > 0) post('transfer', {target, amount, note: $('note').value});
    e.target.reset();
});

document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') post('close');
});
