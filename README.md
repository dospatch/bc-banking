# 🏦 BC-Banking

**A modern, professional banking system for FiveM powered by QBCore and oxmysql.**

BC-Banking provides your FiveM roleplay server with a clean banking interface, player accounts, deposits, withdrawals, transfers, transaction history, ATM support, and a fully integrated NUI experience.

Built for **QBCore** with **oxmysql**, BC-Banking is designed to be simple to install, easy to configure, and ready to expand as your server grows.

---

## 🚧 V2.0.0 Development

V2 is being developed on `feature/bc-banking-v2`. It is **not released** and must not be installed on a production server until migration and runtime test gates pass. V1.0.1 on `main` remains the stable release.

V2 currently adds:
- Multiple checking, savings and business accounts with separate balances and a transaction ledger.
- Cash/bank funding and withdrawals, account transfers, statements and integration exports.
- Savings goals and configurable daily savings interest.
- Debit-card records, freeze/unfreeze, replacement, salted PIN hashes and failed-PIN lockout.
- Personal and business loan applications, staff approval/rejection and repayments.
- Business accounts, employee permissions, payroll and expense recording.
- One-time, weekly and monthly scheduled account payments.
- Admin account controls, audit records and BC Systems payment/business exports.
- V2 NUI panels for these workflows.

**Release status:** feature implementation in progress; not fully runtime-tested. See [V2 implementation plan](docs/V2-IMPLEMENTATION-PLAN.md), [V2 API](docs/V2-API.md), and [V2 test plan](docs/V2-TESTING.md).

### V2 installation and migration
1. Keep your current V1.0.1 resource and take a complete database backup.
2. Test V2 only on a staging server and a copy of your V1 database.
3. The resource runs additive V2 schema migrations on startup; V1 tables and records are not intentionally modified.
4. Do not manually run V2 SQL migrations if the runtime migration has already created the tables.
5. Set a private `Config.V2.CardPepper` value in the installed server copy; do not commit it to GitHub.
6. Keep production on V1 until all V2 tests pass and a release is explicitly approved.

## ✨ Features

### 💳 Banking System

* Modern banking NUI
* Player banking dashboard
* Cash balance display
* Bank balance display
* Total balance display
* Unique player account numbers
* Automatic account creation
* Account information
* Transaction history
* Refresh banking data
* Close banking interface

### 💵 Deposits & Withdrawals

* Deposit cash into your bank account
* Withdraw money from your bank account
* Server-side amount validation
* Configurable deposit limits
* Configurable withdrawal limits
* Transaction logging
* QBCore money integration

### 🔄 Player Transfers

* Transfer money to another player
* Account-number based transfers
* Online player transfers
* Offline player transfers
* Configurable transfer limits
* Configurable transfer fees
* Sender transaction records
* Receiver transaction records
* Self-transfer protection
* Insufficient-funds protection
* Invalid-account protection

### 🏧 ATM Support

* ATM interaction system
* Configurable ATM locations
* Banking interface through ATMs
* ATM command support
* Easy-to-expand ATM system

### 🏦 Bank Locations

* Configurable bank locations
* World interaction markers
* Use **ox_target** to access banking
* Easy configuration for custom locations

### 🔐 Security

* Server-side validation
* Amount validation
* Maximum transaction limits
* Account validation
* Citizen ID verification
* Self-transfer protection
* Insufficient-balance protection
* QBCore server-side money handling
* QBCore bank balance is authoritative; the BC-Banking account balance column is synchronized as a mirror
* Per-character operation locks to serialize simultaneous requests
* Request cooldown to reduce rapid duplicate submissions
* Money-removal and credit-result checks with compensating refunds on failed credits
* Offline recipient database credit verification

---

# 🖥️ Requirements

BC-Banking requires:

* **FiveM**
* **QBCore**
* **oxmysql**
* **ox_target**
* **ox_inventory** (optional; works alongside QBCore money accounts)

Make sure these resources are installed and started before BC-Banking.

Recommended start order:

```cfg
ensure qb-core
ensure oxmysql
ensure ox_target
ensure ox_inventory
ensure bc-banking
```

---

# 📦 Installation

## 1. Download BC-Banking

Download the latest version of BC-Banking from the official repository.

Place the resource inside your FiveM resources directory.

Example:

```text
resources/
└── [bc]/
    └── bc-banking/
```

---

## 2. Import the Database

Locate:

```text
sql/bc_banking.sql
```

Import the SQL file into your server database.

This creates the required BC-Banking tables.

The resource uses:

```text
bc_banking_accounts
bc_banking_transactions
```

---

## 3. Configure the Resource

Open:

```text
config.lua
```

Configure the banking settings to match your server.

Example:

```lua
Config.Debug = false

Config.BankCommand = 'bank'
Config.ATMCommand = 'atm'

Config.Currency = '$'

Config.AccountNumberLength = 10
Config.StartingBankBalance = 0

Config.MaxDeposit = 1000000
Config.MaxWithdrawal = 1000000
Config.MaxTransfer = 1000000

Config.TransferFee = 0

Config.TransactionCooldown = 1000

Config.TransactionHistoryLimit = 50

Config.DiscordLogs = true
```

---

# ⚙️ Server Configuration

Add BC-Banking to your `server.cfg`:

```cfg
ensure qb-core
ensure oxmysql
ensure bc-banking
```

Make sure `qb-core`, `oxmysql`, and `ox_target` are started before BC-Banking. `ox_inventory` may also be started before it when used by your server.

---

# 🔔 Discord Transaction Logs

BC-Banking supports multiple Discord webhooks. You can send every transaction to one general channel, or send deposits, withdrawals, transfers, fees, and other activity to separate channels.

## Setup

1. Open `config.lua`.
2. Find `Config.DiscordWebhooks`.
3. Paste your own Discord webhook URLs into the destinations you want to use.
4. Leave unused destinations as empty strings.
5. Keep `Config.DiscordLogs = true`.
6. Restart `bc-banking`.

Example:

```lua
Config.DiscordLogs = true

Config.DiscordWebhooks = {
    general = '',
    deposits = '',
    withdrawals = '',
    transfers = '',
    fees = '',
    other = ''
}
```

| Setting | Receives |
| --- | --- |
| `general` | Every banking transaction |
| `deposits` | Deposits |
| `withdrawals` | Withdrawals |
| `transfers` | Incoming and outgoing transfers |
| `fees` | Transfer fees |
| `other` | Other transaction types |

You do not need to fill in every field. If both the general webhook and a category webhook are configured, matching transactions go to both channels. If only a category webhook is configured, only that category goes to its channel. Duplicate URLs are sent only once per event.

Each server owner can customize these values in their own installed copy of `config.lua`. **Never commit real webhook URLs to the public GitHub repository**; the public template must keep these values blank. Set `Config.DiscordLogs = false` to disable all Discord transaction logs.

Logs include the character name when online, citizen ID, amount, transaction description, related account, and transaction ID.

---

# 🎮 Commands

| Command | Description                 |
| ------- | --------------------------- |
| `/bank` | Opens the banking interface |
| `/atm`  | Opens the banking interface |

Commands can be changed inside `config.lua`.

Example:

```lua
Config.BankCommand = 'bank'
Config.ATMCommand = 'atm'
```

---

# 🏦 Banking Interface

The BC-Banking interface provides players with a complete overview of their finances.

The dashboard displays:

* Player name
* Citizen ID
* Account number
* Cash balance
* Bank balance
* Total balance
* Recent transactions

Players can also perform:

* Deposits
* Withdrawals
* Transfers
* Account lookups
* Transaction refreshes

---

# 💰 Deposits

Players can deposit cash into their bank account.

The server validates:

* Deposit amount
* Player cash balance
* Maximum deposit limit

Example:

```text
Cash: $5,000
Deposit: $1,000
Bank: $1,000
Cash: $4,000
```

Every successful deposit is recorded in the transaction history.

---

# 💸 Withdrawals

Players can withdraw money from their bank account.

The server validates:

* Withdrawal amount
* Available bank balance
* Maximum withdrawal limit

Example:

```text
Bank: $5,000
Withdraw: $1,000
Bank: $4,000
Cash: $1,000
```

Every successful withdrawal is recorded.

---

# 🔄 Transfers

Players can send money to another player's bank account.

Transfers use the recipient's unique account number.

Example:

```text
Sender Account: 1234567890
Recipient Account: 0987654321
Amount: $500
```

The system checks:

* Valid account number
* Valid transfer amount
* Sender's bank balance
* Maximum transfer amount
* Self-transfer protection
* Recipient availability

Successful transfers create transaction records for both players.

---

# 👤 Account Numbers

BC-Banking automatically creates a unique account number for players.

Default account number length:

```lua
Config.AccountNumberLength = 10
```

Example:

```text
BC-BANK ACCOUNT
1234567890
```

Account numbers are associated with the player's:

```text
Citizen ID
```

---

# 🧾 Transaction History

BC-Banking records player banking activity.

Supported transaction types include:

```text
deposit
withdraw
transfer_out
transfer_in
```

Transaction information includes:

* Transaction type
* Amount
* Description
* Related account
* Date/time

The number of transactions displayed can be configured:

```lua
Config.TransactionHistoryLimit = 50
```

---

# 🏧 ATM System

BC-Banking includes configurable ATM locations.

ATM interactions can be configured through:

```text
config.lua
```

Players can interact with configured ATMs to access the banking interface.

The resource also provides:

```text
/atm
```

for quick ATM access.

---

# 🗺️ Bank Locations

Bank locations are configured inside:

```text
config.lua
```

Players can approach a configured bank location and press:

```text
E
```

to open the banking interface.

---

# 🛠️ Configuration

The main configuration file is:

```text
config.lua
```

Available configuration options include:

### Debug

```lua
Config.Debug = false
```

Enable debug functionality when troubleshooting.

---

### Commands

```lua
Config.BankCommand = 'bank'
Config.ATMCommand = 'atm'
```

Change the commands used to open the banking interface.

---

### Currency

```lua
Config.Currency = '$'
```

Change the currency symbol displayed by the banking interface.

---

### Account Numbers

```lua
Config.AccountNumberLength = 10
```

Controls the length of generated account numbers.

---

### Starting Balance

```lua
Config.StartingBankBalance = 0
```

Legacy setting retained for configuration compatibility. V1.0 uses the player's QBCore bank balance as the authoritative balance and initializes/synchronizes the account mirror from it.

---

### Transaction Limits

```lua
Config.MaxDeposit = 1000000
Config.MaxWithdrawal = 1000000
Config.MaxTransfer = 1000000
```

Controls the maximum amount players can deposit, withdraw, or transfer.

---

### Transfer Fee

```lua
Config.TransferFee = 0
```

`Config.TransactionCooldown` sets the minimum delay between deposit, withdrawal, and transfer requests from the same character (default: 1000 ms).

Set a transfer fee if your server wants to charge players for transfers.

Example:

```lua
Config.TransferFee = 25
```

---

### Transaction History

```lua
Config.TransactionHistoryLimit = 50
```

Controls how many recent transactions are displayed.

---

# 📁 Resource Structure

```text
bc-banking/
│
├── client/
│   ├── atm.lua
│   ├── banking.lua
│   ├── commands.lua
│   ├── main.lua
│   └── nui.lua
│
├── html/
│   ├── css/
│   │   └── style.css
│   │
│   ├── js/
│   │   └── app.js
│   │
│   └── index.html
│
├── server/
│   ├── accounts.lua
│   ├── banking.lua
│   ├── main.lua
│   ├── players.lua
│   ├── transactions.lua
│   └── transfers.lua
│
├── shared/
│   └── utils.lua
│
├── sql/
│   └── bc_banking.sql
│
├── config.lua
├── fxmanifest.lua
└── README.md
```

---

# 🔌 QBCore Integration

BC-Banking is designed specifically around QBCore.

The resource uses QBCore for:

* Player identification
* Citizen IDs
* Player cash
* Player bank balances
* Player character information
* Server-side money operations
* Player loading

Bank and ATM interactions are handled by `ox_target`. The resource uses QBCore cash and bank money accounts as its authoritative balances. The `bc_banking_accounts.balance` column is a synchronized mirror, not a separate wallet. `ox_inventory` can run alongside it without creating a second cash balance. BC-Banking V1 reads and changes QBCore's `cash` and `bank` money accounts; it does not yet include a custom inventory-item cash adapter.

BC-Banking initializes QBCore through:

```lua
local QBCore = exports['qb-core']:GetCoreObject()
```

---

# 🗄️ oxmysql Integration

BC-Banking uses oxmysql for database operations.

The resource stores banking-related information in its own database tables.

Required dependency:

```text
oxmysql
```

The manifest loads:

```lua
@oxmysql/lib/MySQL.lua
```

---

# 🧩 Exports

BC-Banking provides exports that can be used by other resources.

### Get Bank Balance

```lua
local balance = exports['bc-banking']:GetBankBalance(source)
```

Example:

```lua
local bankBalance = exports['bc-banking']:GetBankBalance(source)

print('Player bank balance: ' .. bankBalance)
```

---

### Get Account by Citizen ID

```lua
local account = exports['bc-banking']:GetAccountByCitizenId(citizenid)
```

---

### Get Account by Account Number

```lua
local account = exports['bc-banking']:GetAccountByNumber(accountNumber)
```

---

### Create Account

```lua
local Player = QBCore.Functions.GetPlayer(source)\nlocal account = exports['bc-banking']:CreateAccount(Player)
```

---

### Add Transaction

```lua
exports['bc-banking']:AddTransaction(
    citizenid,
    'deposit',
    amount,
    'Cash deposit'
)
```

---

### Get Transactions

```lua
local transactions = exports['bc-banking']:GetTransactions(
    citizenid,
    50
)
```

---

# 🔒 Security

BC-Banking performs important banking validation server-side.

Clients should never be trusted to determine:

* Available funds
* Transfer amounts
* Deposit amounts
* Withdrawal amounts
* Recipient accounts

BC-Banking validates banking operations on the server before modifying player money.

This helps prevent basic client-side manipulation of banking operations.

---

# ⚠️ Important

BC-Banking is designed for **QBCore**.

It is **not currently designed for ESX**.

Do not attempt to use BC-Banking on an ESX server without modifying the framework integration.

---

# 🧪 Testing Checklist

Before deploying BC-Banking to a production server, test the following:

### Installation

* [ ] Resource starts without errors
* [ ] oxmysql starts correctly
* [ ] QBCore starts correctly
* [ ] SQL tables are created
* [ ] BC-Banking loads successfully

### Banking

* [ ] `/bank` works
* [ ] `/atm` works
* [ ] Bank location interaction works
* [ ] ATM interaction works
* [ ] Banking UI opens
* [ ] Banking UI closes
* [ ] Player information displays
* [ ] Account number displays
* [ ] Cash balance displays
* [ ] Bank balance displays

### Deposits

* [ ] Deposit works
* [ ] Cash decreases
* [ ] Bank balance increases
* [ ] Transaction is recorded
* [ ] Invalid amounts are rejected
* [ ] Insufficient cash is rejected

### Withdrawals

* [ ] Withdrawal works
* [ ] Bank balance decreases
* [ ] Cash increases
* [ ] Transaction is recorded
* [ ] Invalid amounts are rejected
* [ ] Insufficient funds are rejected

### Transfers

* [ ] Transfer works
* [ ] Recipient account is found
* [ ] Sender balance decreases
* [ ] Recipient balance increases
* [ ] Sender transaction is recorded
* [ ] Recipient transaction is recorded
* [ ] Self-transfer is rejected
* [ ] Invalid accounts are rejected
* [ ] Insufficient funds are rejected

---

# 🐛 Troubleshooting

## BC-Banking Does Not Start

Check that:

```cfg
ensure qb-core
ensure oxmysql
ensure bc-banking
```

are in the correct order.

Then check your FiveM server console for errors.

---

## Database Errors

Make sure:

1. oxmysql is installed.
2. oxmysql is started.
3. `sql/bc_banking.sql` has been imported.
4. Your database credentials are correct.
5. Your database is online.

---

## QBCore Errors

Make sure you are running a compatible QBCore version.

BC-Banking requires QBCore.

---

## NUI Does Not Open

Check:

```text
html/index.html
html/css/style.css
html/js/app.js
```

Also check the FiveM client console for JavaScript or NUI errors.

---

# 📋 Version

**Development Version:** `2.0.0-dev`

**Release Status:** V2.0.0 development build — not released; implementation and FiveM runtime testing are still in progress. V1.0.1 remains the stable release.

---

# 📝 Changelog

## v1.0.1

### Updated

* Added category-based multiple Discord webhook destinations configured directly in `config.lua`
* Kept webhook URL values blank in the public repository so server owners add their own URLs locally
* Confirmed NUI manifest paths point to `html/css/style.css` and `html/js/app.js`

## v1.0.0

### Added

* Complete banking NUI
* QBCore integration
* oxmysql integration
* Bank locations
* ATM locations
* `/bank` command
* `/atm` command
* Player account numbers
* Automatic account creation
* Deposits
* Withdrawals
* Player transfers
* Offline transfers
* Transaction history
* Account lookup
* Server-side validation
* Configurable transaction limits
* Configurable transfer fees
* Banking exports
* SQL database structure
* Responsive banking interface

---

# 🚀 Future Development

Future BC-Banking updates may include additional banking functionality such as:

* Multiple account types
* Shared accounts
* Business accounts
* Government accounts
* Savings accounts
* Account statements
* Bank cards
* ATM card support
* PIN systems
* Banking notifications
* Scheduled payments
* Direct deposits
* Business banking
* Employee payroll integration
* Improved transaction filtering
* Advanced banking administration
* Expanded banking API
* Additional framework compatibility

Future features are subject to development and may change between versions.

---

# 🏢 BC Systems

BC-Banking is part of the **BC Systems** FiveM development ecosystem.

BC Systems focuses on creating professional FiveM resources for modern roleplay communities.

Current and planned BC Systems products include:

* BC-MDT
* BC-Dispatch
* BC-Radio
* BC-DOJ
* BC-Banking
* BC-AdminMenu
* BC-HUD
* BC-CMS
* And more

---

# 📜 License

Copyright © 2026 **BCGAMING / BC Systems**

This software is provided for use by licensed customers and authorized users.

Redistribution, reselling, re-uploading, or claiming this resource as your own is prohibited unless explicitly authorized by BC Systems.

Do not redistribute paid versions of BC-Banking.

---

# 💬 Support

For support, updates, announcements, and development information, join the official BCGAMING community.

**BCGAMING San Andreas Roleplay**

Serious RP • Realism • Community Driven

Official Discord:

https://discord.gg/YN6AgpU9F5

---

# 🛒 Purchase

BC-Banking is available through the official BC Systems / BCGAMING Tebex store.

Tebex:

https://bcgaming.tebex.io/

Please purchase BC-Banking only through the official store to ensure you receive legitimate files, updates, and support.

---

# ❤️ Credits

**Developer:** BCGAMING / BC Systems

**Framework:** QBCore

**Database:** oxmysql

**Platform:** FiveM

Thank you for supporting BC Systems and helping us continue developing quality FiveM resources.

---

## 🏦 BC-BANKING

**Professional banking for serious FiveM roleplay.**

**QBCore • oxmysql • Modern NUI • Secure Server-Side Banking**