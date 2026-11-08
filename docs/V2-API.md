# BC-Banking V2 API

All exports are server-side unless explicitly stated. Never call money-moving exports from a client script. Resolve the player's citizen ID on the server and pass it to account-scoped exports.

## V2 account exports

### List accounts
~~~lua
local accounts = exports['bc-banking']:GetV2Accounts(citizenid)
~~~

### Create an account
~~~lua
local account = exports['bc-banking']:CreateV2Account(citizenid, 'savings', 'Rainy Day')
~~~
Allowed types: `checking`, `savings`, `business`.

### Authorized balance and ledger
~~~lua
local balance = exports['bc-banking']:GetV2AccountBalance(accountId, citizenid)
local entries = exports['bc-banking']:GetV2Ledger(accountId, citizenid, 50)
local statement = exports['bc-banking']:GetAccountStatement(accountId, citizenid, '2026-01-01', '2026-12-31', 100)
~~~
`nil` balance or an empty result means the character has no active access.

### Deposit / withdraw within V2 account
~~~lua
local ok, reason = exports['bc-banking']:DepositToV2Account(accountId, citizenid, 250.00, 'BC Systems deposit')
local withdrawn, why = exports['bc-banking']:WithdrawFromV2Account(accountId, citizenid, 100.00, 'BC Systems withdrawal')
~~~
These exports operate on V2 ledger balances; they do not debit or credit QBCore cash/bank.

### Charge player using cash or bank
~~~lua
local ok, reason = exports['bc-banking']:ChargePlayer(source, 500.00, 'bank', 'BC-Dealership purchase', 'dealership-order-12345')
~~~
`paymentSource` must be `cash` or `bank`. Only complete the calling resource's purchase after `ok == true`.

### Business expense
~~~lua
local ok, reason = exports['bc-banking']:RecordBusinessExpense(businessId, actorCitizenid, 125.00, 'supplies', 'Office supplies', 'expense-run-unique-123')
~~~
Actor must have active business membership with `withdraw` permission. Pass a unique idempotency key as the sixth argument to prevent duplicate expense debits.

### Card PIN verification
~~~lua
local valid = exports['bc-banking']:VerifyCardPin(cardId, citizenid, pin)
~~~
PINs are salted and hashed by the database; they are not returned to clients or stored as plaintext. Five failed attempts trigger a 15-minute lock. This verifies a PIN only; it is not a card network/payment processor.

### Account status (trusted server resource only)
~~~lua
local ok = exports['bc-banking']:SetV2AccountStatus(accountId, 'frozen', 'BC-Admin')
~~~
Allowed statuses: `active`, `frozen`, `closed`.

## Admin commands

Grant ACE permission `bc-banking.admin` only to trusted administrators.

- `bcbankloan <applicationId> approve|reject`
- `bcbankbusinessloan <applicationId> approve|reject`
- `bcbankaccount <accountId> freeze|unfreeze|close|reopen`
- `bcbankaudit <citizenid>`

## Integration safety

- Never expose server exports as client events without a server-side authorization wrapper.
- Treat `false` as a failed payment and do not deliver the purchased item/vehicle.
- Do not use a V2 ledger balance as a mirror of QBCore bank money; they are separate balances.
- Use an idempotency key in the calling resource's purchase workflow until built-in idempotency enforcement is enabled for every money-moving export.