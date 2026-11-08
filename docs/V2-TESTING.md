# BC-Banking V2.0.0 Test Plan

**Status: not yet runtime-tested.** Run on a staging FiveM server and a disposable copy of a V1 database. Never run balance tests against production characters.

## Preflight
- Back up database and resource directory.
- Record V1 account/transaction counts and sample balances.
- Confirm QBCore, oxmysql, ox_target versions and `players.money` format.
- Set a private `Config.V2.CardPepper`; keep Discord webhook templates blank.
- Verify migration version 4 and all V2 tables.
- Confirm V1 tables and rows remain unchanged.

## Personal accounts and ledger
- Create checking/savings accounts; reject invalid types and account-limit overflow.
- Attempt another citizen's account ID; expect denial.
- Deposit from cash/bank and withdraw to cash/bank; verify each balance changes once.
- Test invalid, non-finite, over-limit and insufficient-funds amounts.
- Test owned-account and other-character transfers, self-transfer denial, and ledger failure reversal.
- Verify statements, balance-after values and date filters.

## Savings
- Create, contribute to and complete a goal.
- Attempt to contribute to another citizen's goal; expect denial.
- Run interest twice for one date; expect one accrual per account/date.
- Test zero APR and cent rounding.

## Cards
- Issue physical-style and virtual cards, freeze, unfreeze and replace each type; replacement must preserve card type.
- Set and verify 4-, 5- and 6-digit PINs.
- Wrong PIN increments attempts; fifth failure locks for 15 minutes.
- Confirm PIN/full token never appears in UI, plaintext DB, Discord or console.
- Confirm frozen/replaced cards fail verification.

## Loans
- Submit valid applications; reject invalid terms and duplicate open loans.
- Approve/reject as ACE-authorized staff; deny unauthorized staff.
- Verify online/offline disbursement against the deployed QBCore JSON schema.
- Repay partially and fully; cap overpayment at remaining balance.

## Business and business loans
- Create business and linked account.
- Add/update employee permissions and test each permission independently.
- Confirm employees cannot gain owner/manage rights.
- Test online/offline payroll and rollback on failure.
- Record expenses; verify business balance, expense row and ledger.
- Deny non-members and employees without permissions.

## Scheduled payments and administration
- Test one-time, weekly and monthly payments, due time, source debit and destination credit.
- Test insufficient funds, invalid membership, cancellation, duplicate runs and resource restart while processing.
- Freeze/close account and verify transactions are blocked; reopen and verify access.
- Verify audit records and ACE restrictions.

## V1 regression
- Test `/bank`, `/atm`, bank/ATM targets, deposits, withdrawals, online/offline transfers.
- Compare V1 balances and transaction history before/after migration.
- Verify V1 stays available if V2 migration fails.
- Confirm `main` and stable release remain unchanged.

## Release gate
All critical tests must pass, migration rehearsal and restore must succeed, no balance duplication/loss bugs can remain, and a manual FiveM runtime test report must be documented before V2.0.0 is tagged.