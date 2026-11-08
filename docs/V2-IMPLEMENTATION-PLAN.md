# BC-Banking V2.0.0 — Implementation Plan

Status: approved scope; implementation in progress on `feature/bc-banking-v2`.
Stable V1 branch: `main` (do not modify during V2 development).

## Repository baseline inspected

V1 is a compact QBCore resource using oxmysql, ox_target, and a NUI. Existing capabilities include one checking account per citizen ID, QBCore cash/bank balances, deposits, withdrawals, player transfers (including offline recipient credit), transaction history, configurable bank/ATM access, per-citizen in-process locks, cooldowns, and category-based Discord webhooks.

Important V1 data model:
- `bc_banking_accounts`: one row per citizen ID; unique citizen ID and account number; `balance` is a mirror of QBCore's bank balance.
- `bc_banking_transactions`: citizen-scoped transaction history.
- QBCore's `players.money.bank` remains authoritative for the existing primary bank balance.

## V2 architecture decisions

1. Preserve V1 tables and data. Add additive, versioned migrations; do not drop or rewrite existing rows as part of installation.
2. Keep QBCore cash and primary bank money authoritative for legacy cash/checking behavior.
3. Introduce a BC-Banking ledger for additional checking/savings/business accounts. Each ledger operation must be atomic and auditable; do not duplicate balances in QBCore and custom accounts.
4. Treat cash-vs-bank as an explicit payment-source choice exposed by a server-authoritative payment API. A client selection is a request, never proof of funds.
5. Use integer minor units (cents) or exact DECIMAL arithmetic consistently for stored amounts; validate finite positive amounts and currency precision.
6. Add idempotency keys and database transactions for money-moving operations. In-process locks alone are insufficient across multiple resources/restarts.
7. Hash card PINs with a server-side password-hashing approach; never store plaintext PINs or full sensitive card credentials in logs.
8. Enforce account ownership, business membership, role permissions, card state, loan state, and admin permissions on the server for every operation.
9. Keep Discord webhook URLs blank in public configuration. Never commit customer webhook secrets.
10. Optional integrations must degrade gracefully when their resources are absent.

## Approved feature scope

- Personal checking and multiple accounts.
- Savings accounts, savings goals, and configurable savings interest.
- Cash-or-bank payment selection and payment API.
- Transaction history, search/filtering, and account statements.
- Business accounts, employee permissions, expenses, payments, and payroll.
- Physical-style and virtual cards; PIN management, freeze/unfreeze, and replacement.
- Configurable bank branches and ATMs; ATM deposits, withdrawals, and fees.
- Personal and business loans, applications, approvals, repayment schedules, and interest.
- Banking administration, security controls, and immutable-style audit history.
- Multiple Discord webhook destinations.
- BC Systems integration API and optional resource adapters.
- Versioned SQL migrations preserving V1 data.

## Proposed additive data model

Final SQL names and constraints will be reviewed against the actual V1 schema before implementation. Planned entities include:
- account registry and account holders/memberships
- ledger entries and idempotency records
- savings goals and interest accrual records
- businesses and employee permissions
- payroll batches and payroll items
- cards and card event history
- loan applications, loans, and repayments
- scheduled payments
- admin/security audit events
- schema migration version tracking

The existing `bc_banking_accounts` and `bc_banking_transactions` tables remain intact. A compatibility layer will map legacy checking accounts and transaction history into the V2 account/ledger model without double-counting existing QBCore bank money.

## API design principles

- Payment request accepts amount, purpose, allowed sources, and optional metadata; server validates and returns a result.
- Player-facing choice can be Cash, Bank, or Cancel when enabled by the calling resource.
- Dedicated exports/callbacks for account lookup, authorized deposits/withdrawals/transfers, business payroll, and transaction retrieval.
- Exports validate caller-supplied identifiers and permissions; no client-triggered privileged exports.
- Stable API versioning and documented examples for BC-Dealership, BC-Business, BC-Admin, and other QBCore resources.

## Delivery phases

1. V2 foundation: audit V1 behavior, migration framework, account/ledger core, idempotency, compatibility tests.
2. Personal banking: multiple accounts, savings, goals, payment-source selector, transaction filters/statements.
3. Business banking: business accounts, memberships/permissions, expenses, transfers, payroll.
4. Cards and locations: card lifecycle/PIN security, branches, ATM workflows and fees.
5. Loans and interest: application/approval, repayment schedules, interest accrual and duplicate-run protection.
6. Administration and integrations: permissioned admin tools, audit/security logs, webhook expansion, versioned integration API.
7. Release readiness: clean install, V1 upgrade/rollback rehearsal, security tests, runtime testing, documentation and release notes.

## Safety and release gates

- Do not push V2 work to `main` during development.
- Do not publish a V2 release until implementation, migration rehearsal, and FiveM runtime tests pass.
- Never claim runtime-tested behavior without a real server test.
- Keep V1 backup and rollback instructions.
- Any irreversible or balance-affecting migration must be explicitly reviewed before execution.
