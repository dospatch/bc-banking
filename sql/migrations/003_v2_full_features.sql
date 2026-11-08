-- BC-Banking V2 additive feature migration; run after 002_v2_accounts_ledger.sql.
-- The server migration runner applies these CREATE TABLE statements automatically.
CREATE TABLE IF NOT EXISTS bc_banking_v2_savings_goals (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, citizenid VARCHAR(50) NOT NULL,
 name VARCHAR(80) NOT NULL, target_amount DECIMAL(15,2) NOT NULL,
 current_amount DECIMAL(15,2) NOT NULL DEFAULT 0, status VARCHAR(16) NOT NULL DEFAULT 'active',
 created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
 PRIMARY KEY(id), KEY idx_bc_v2_goal_owner(citizenid,status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_cards (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, citizenid VARCHAR(50) NOT NULL,
 account_id BIGINT UNSIGNED NOT NULL, card_hash VARCHAR(128) NOT NULL,
 card_last4 CHAR(4) NOT NULL, card_type VARCHAR(16) NOT NULL DEFAULT 'debit',
 status VARCHAR(16) NOT NULL DEFAULT 'active', expires_at DATETIME NOT NULL,
 created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(id),
 KEY idx_bc_v2_cards_owner(citizenid,status),
 CONSTRAINT fk_bc_v2_card_account FOREIGN KEY(account_id) REFERENCES bc_banking_v2_accounts(id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_card_secrets (
 card_id BIGINT UNSIGNED NOT NULL, pin_salt VARCHAR(64) NOT NULL, pin_hash CHAR(64) DEFAULT NULL,
 pin_attempts INT NOT NULL DEFAULT 0, pin_locked_until DATETIME DEFAULT NULL,
 updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
 PRIMARY KEY(card_id),
 CONSTRAINT fk_bc_v2_card_secret FOREIGN KEY(card_id) REFERENCES bc_banking_v2_cards(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_loans (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, citizenid VARCHAR(50) NOT NULL,
 principal DECIMAL(15,2) NOT NULL, apr DECIMAL(7,3) NOT NULL DEFAULT 0,
 term_months INT NOT NULL, monthly_payment DECIMAL(15,2) NOT NULL DEFAULT 0,
 balance_due DECIMAL(15,2) NOT NULL DEFAULT 0, status VARCHAR(16) NOT NULL DEFAULT 'pending',
 created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, reviewed_at DATETIME DEFAULT NULL,
 next_payment_at DATETIME DEFAULT NULL, PRIMARY KEY(id), KEY idx_bc_v2_loan_owner(citizenid,status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_businesses (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, name VARCHAR(80) NOT NULL,
 owner_citizenid VARCHAR(50) NOT NULL, account_id BIGINT UNSIGNED DEFAULT NULL,
 status VARCHAR(16) NOT NULL DEFAULT 'active', created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
 PRIMARY KEY(id), KEY idx_bc_v2_business_owner(owner_citizenid,status),
 CONSTRAINT fk_bc_v2_business_account FOREIGN KEY(account_id) REFERENCES bc_banking_v2_accounts(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_business_members (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, business_id BIGINT UNSIGNED NOT NULL,
 citizenid VARCHAR(50) NOT NULL, role VARCHAR(24) NOT NULL DEFAULT 'employee',
 permissions JSON NOT NULL, status VARCHAR(16) NOT NULL DEFAULT 'active',
 created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(id),
 UNIQUE KEY uq_bc_v2_business_member(business_id,citizenid),
 CONSTRAINT fk_bc_v2_business_member FOREIGN KEY(business_id) REFERENCES bc_banking_v2_businesses(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_payroll (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, business_id BIGINT UNSIGNED NOT NULL,
 employee_citizenid VARCHAR(50) NOT NULL, amount DECIMAL(15,2) NOT NULL,
 actor_citizenid VARCHAR(50) NOT NULL, status VARCHAR(16) NOT NULL DEFAULT 'paid',
 created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(id),
 KEY idx_bc_v2_payroll_business(business_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_business_expenses (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, business_id BIGINT UNSIGNED NOT NULL,
 actor_citizenid VARCHAR(50) NOT NULL, amount DECIMAL(15,2) NOT NULL,
 category VARCHAR(48) NOT NULL, description VARCHAR(255) DEFAULT NULL,
 created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(id),
 KEY idx_bc_v2_expense_business(business_id,created_at),
 CONSTRAINT fk_bc_v2_expense_business FOREIGN KEY(business_id) REFERENCES bc_banking_v2_businesses(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_interest_accruals (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, account_id BIGINT UNSIGNED NOT NULL,
 accrual_date DATE NOT NULL, annual_rate DECIMAL(7,3) NOT NULL,
 amount DECIMAL(15,2) NOT NULL, balance_after DECIMAL(15,2) NOT NULL,
 created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(id),
 UNIQUE KEY uq_bc_v2_interest_day(account_id,accrual_date),
 CONSTRAINT fk_bc_v2_interest_account FOREIGN KEY(account_id) REFERENCES bc_banking_v2_accounts(id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS bc_banking_v2_scheduled_payments (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, owner_citizenid VARCHAR(50) NOT NULL,
 source_account_id BIGINT UNSIGNED NOT NULL, destination_account_id BIGINT UNSIGNED NOT NULL,
 amount DECIMAL(15,2) NOT NULL, description VARCHAR(120) NOT NULL,
 frequency VARCHAR(16) NOT NULL DEFAULT 'once', next_run_at DATETIME NOT NULL,
 status VARCHAR(16) NOT NULL DEFAULT 'active',
 created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
 PRIMARY KEY(id), KEY idx_bc_v2_schedule_due(status,next_run_at),
 KEY idx_bc_v2_schedule_owner(owner_citizenid,status),
 CONSTRAINT fk_bc_v2_schedule_source FOREIGN KEY(source_account_id) REFERENCES bc_banking_v2_accounts(id) ON DELETE RESTRICT,
 CONSTRAINT fk_bc_v2_schedule_dest FOREIGN KEY(destination_account_id) REFERENCES bc_banking_v2_accounts(id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS bc_banking_v2_audit (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, actor_citizenid VARCHAR(50) NOT NULL,
 action VARCHAR(64) NOT NULL, target_type VARCHAR(32) NOT NULL, target_id VARCHAR(64) NOT NULL,
 details JSON DEFAULT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
 PRIMARY KEY(id), KEY idx_bc_v2_audit_actor(actor_citizenid,created_at),
 KEY idx_bc_v2_audit_target(target_type,target_id,created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS bc_banking_v2_business_loans (
 id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, business_id BIGINT UNSIGNED NOT NULL,
 applicant_citizenid VARCHAR(50) NOT NULL, principal DECIMAL(15,2) NOT NULL,
 apr DECIMAL(7,3) NOT NULL DEFAULT 0, term_months INT NOT NULL,
 monthly_payment DECIMAL(15,2) NOT NULL DEFAULT 0, balance_due DECIMAL(15,2) NOT NULL DEFAULT 0,
 status VARCHAR(16) NOT NULL DEFAULT 'pending', created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
 reviewed_at DATETIME DEFAULT NULL, next_payment_at DATETIME DEFAULT NULL,
 PRIMARY KEY(id), KEY idx_bc_v2_business_loan(business_id,status),
 CONSTRAINT fk_bc_v2_business_loan FOREIGN KEY(business_id) REFERENCES bc_banking_v2_businesses(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
