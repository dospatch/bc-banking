# 🏦 BC-Banking

**BC-Banking** is a modern, lightweight banking system for **FiveM QBCore servers**, built with **QBCore, oxmysql, and ox_target**.

BC-Banking provides players with a clean and professional banking interface for managing their money, accessing ATMs, making transfers, and viewing transaction history.

---

## ✨ Features

* 🏦 Modern BC-branded banking NUI
* 💵 View bank balance
* 💰 View cash balance
* 💳 Deposit money
* 💸 Withdraw money
* 🔄 Player-to-player money transfers
* 📜 Transaction history
* 🏧 ATM support
* 🎯 ox_target integration
* 🗺️ Configurable bank locations
* 📍 Bank blips
* ⚙️ Configurable transaction limits
* 💰 Configurable transfer fees
* 🛡️ Server-side money validation
* 🎮 `/bank` command
* 🏧 `/atm` command
* ⌨️ F7 banking keybind
* 🗄️ oxmysql database support
* 🚀 Lightweight and optimized
* 🔧 Easy configuration

---

## 🔧 Requirements

BC-Banking requires the following resources:

* **QBCore**
* **oxmysql**
* **ox_target**
* **FiveM Server**

Make sure all dependencies are installed and running before starting BC-Banking.

---

## 📦 Installation

### 1. Download BC-Banking

Download the latest release from the GitHub Releases page or your Tebex purchase.

### 2. Install the Resource

Place the `bc-banking` folder inside your FiveM resources directory.

Example:

```text
resources/
└── [bc]/
    └── bc-banking/
```

### 3. Import the Database

Import the following SQL file into your server database:

```text
sql/bc_banking.sql
```

BC-Banking uses **oxmysql** for database communication.

### 4. Start Dependencies

Make sure the following resources are started before BC-Banking:

```cfg
ensure qb-core
ensure oxmysql
ensure ox_target
```

### 5. Start BC-Banking

Add:

```cfg
ensure bc-banking
```

Your final `server.cfg` section should look similar to:

```cfg
ensure qb-core
ensure oxmysql
ensure ox_target
ensure bc-banking
```

### 6. Restart Your Server

Restart your FiveM server and check the server console for any errors.

---

## ⚙️ Configuration

All major BC-Banking settings can be found inside:

```text
config.lua
```

You can configure:

* Banking command
* ATM command
* Bank opening distance
* ATM opening distance
* Deposit minimum
* Deposit maximum
* Withdrawal minimum
* Withdrawal maximum
* Transfer minimum
* Transfer maximum
* Transfer fees
* Transaction history limit
* Bank locations
* ATM models
* Bank blips
* Notifications
* Debug mode

---

## 🏦 Banking

Players can access their bank through configured bank locations.

The banking interface allows players to:

* View their bank balance
* View their cash balance
* Deposit money
* Withdraw money
* Transfer money
* View recent transactions

Players can also use:

```text
/bank
```

to open the banking interface.

---

## 🏧 ATMs

BC-Banking supports ATM interaction through **ox_target**.

Players can interact with supported ATM models and access their banking account without needing to visit a bank.

Players can also use:

```text
/atm
```

to access the ATM interface.

---

## 💸 Transfers

Players can transfer money to another player using their server ID.

Transfers are processed server-side and include configurable:

* Minimum transfer amount
* Maximum transfer amount
* Transfer fee

Example configuration:

```lua
Config.Transfer = {
    Enabled = true,
    Minimum = 1,
    Maximum = 100000,
    Fee = 0
}
```

---

## 📜 Transaction History

BC-Banking records banking transactions in the database.

Transactions can include:

* Deposits
* Withdrawals
* Transfers

Transaction records contain:

* Transaction ID
* Citizen ID
* Transaction type
* Amount
* Description
* Date/time

---

## 🗄️ Database

BC-Banking uses **oxmysql**.

The included database table is:

```text
bc_banking_transactions
```

The SQL installation file is located at:

```text
sql/bc_banking.sql
```

---

## 📁 Resource Structure

```text
bc-banking/
│
├── client/
│   ├── main.lua
│   ├── banking.lua
│   ├── atm.lua
│   └── nui.lua
│
├── server/
│   ├── main.lua
│   ├── accounts.lua
│   ├── transactions.lua
│   └── transfers.lua
│
├── shared/
│   └── utils.lua
│
├── html/
│   ├── index.html
│   ├── css/
│   │   └── style.css
│   └── js/
│       └── app.js
│
├── sql/
│   └── bc_banking.sql
│
├── config.lua
├── fxmanifest.lua
└── README.md
```

---

## 🎮 Commands & Controls

| Command / Key | Function         |
| ------------- | ---------------- |
| `/bank`       | Open banking     |
| `/atm`        | Open ATM banking |
| `F7`          | Open banking     |

Commands and controls can be changed or disabled through the configuration.

---

## 🔐 Security

BC-Banking performs important money operations server-side.

The server validates:

* Transaction amounts
* Deposit amounts
* Withdrawal amounts
* Transfer amounts
* Player balances
* Transfer targets
* Configured transaction limits

Never rely on client-side values for financial transactions.

---

## 🛠️ Troubleshooting

### Banking UI does not open

Check that:

```cfg
ensure bc-banking
```

is present in your `server.cfg`.

Also verify that QBCore is running.

### Database errors

Make sure:

```cfg
ensure oxmysql
```

starts before BC-Banking.

Also make sure `sql/bc_banking.sql` has been imported into your server database.

### ATM interaction does not work

Make sure:

```cfg
ensure ox_target
```

is running.

Also verify the ATM models configured in:

```text
config.lua
```

### Transfers are not working

Check:

* The target player is online.
* The target server ID is correct.
* The sender has enough money.
* The transfer amount is within the configured limits.
* The transfer system is enabled.

---

## 🚀 Roadmap

Future BC-Banking updates may introduce additional financial features.

Potential future features include:

* 💳 Debit cards
* 🔢 PIN systems
* 🏢 Business banking
* 🧾 Advanced transaction filtering
* 📊 Banking statistics
* 🏦 Multiple account types
* 👥 Shared accounts
* 💰 Savings accounts
* 🏧 Additional ATM functionality
* 📱 Mobile banking integration

Features listed in the roadmap are **not included unless specifically stated in the current release notes**.

---

## 📋 Version

**Current Version:** `1.0.0`

**Status:** 🟢 Initial Release

---

## 📜 License

BC-Banking is a **BCGAMING / BC Systems** product.

Unless otherwise stated, redistribution, reselling, reuploading, or claiming this resource as your own is prohibited.

See the included license or purchase terms for additional information.

---

## 🆘 Support

For support, installation assistance, bug reports, or configuration questions, contact the **BCGAMING / BC Systems** support team through the official support channels.

When requesting support, please provide:

* BC-Banking version
* FiveM server artifacts version
* QBCore version
* oxmysql version
* ox_target version
* Relevant console errors
* Steps to reproduce the issue

---

## ❤️ Credits

**BC-Banking**

Developed by:

### BCGAMING / BC Systems

Built for FiveM communities running QBCore.

---

## 📢 Official Links

**BCGAMING San Andreas Roleplay**

Discord: https://discord.gg/YN6AgpU9F5

**BCGAMING Tebex**

https://bcgaming.tebex.io/

---

# 🏦 BC-Banking

### Built for FiveM. Built for QBCore. Built by BC Systems.

**© 2026 BCGAMING / BC Systems — All Rights Reserved.**
