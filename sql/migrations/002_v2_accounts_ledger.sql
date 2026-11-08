-- BC-Banking V2 additive foundation migration.
-- Safe to apply to V1: no existing tables or rows are altered or deleted.
-- The runtime migration runner executes these statements individually.

CREATE TABLE IF NOT EXISTS `bc_banking_schema_versions` (
    `version` INT NOT NULL,
    `name` VARCHAR(100) NOT NULL,
    `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_accounts` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_number` VARCHAR(24) NOT NULL,
    `account_type` VARCHAR(24) NOT NULL,
    `display_name` VARCHAR(80) NOT NULL,
    `owner_citizenid` VARCHAR(50) NOT NULL,
    `balance` DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_bc_v2_account_number` (`account_number`),
    KEY `idx_bc_v2_owner_type` (`owner_citizenid`, `account_type`),
    KEY `idx_bc_v2_account_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_account_members` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `role` VARCHAR(24) NOT NULL DEFAULT 'owner',
    `permissions` JSON NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_bc_v2_account_member` (`account_id`, `citizenid`),
    KEY `idx_bc_v2_member_citizenid` (`citizenid`, `status`),
    CONSTRAINT `fk_bc_v2_member_account` FOREIGN KEY (`account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_ledger` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `transaction_ref` CHAR(36) NOT NULL,
    `entry_type` VARCHAR(32) NOT NULL,
    `amount` DECIMAL(15,2) NOT NULL,
    `balance_after` DECIMAL(15,2) NOT NULL,
    `actor_citizenid` VARCHAR(50) NOT NULL,
    `description` VARCHAR(255) DEFAULT NULL,
    `metadata` JSON DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_bc_v2_ledger_ref_account` (`transaction_ref`, `account_id`),
    KEY `idx_bc_v2_ledger_account_time` (`account_id`, `id`),
    KEY `idx_bc_v2_ledger_actor_time` (`actor_citizenid`, `created_at`),
    CONSTRAINT `fk_bc_v2_ledger_account` FOREIGN KEY (`account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_idempotency` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `idempotency_key` VARCHAR(96) NOT NULL,
    `actor_citizenid` VARCHAR(50) NOT NULL,
    `operation` VARCHAR(32) NOT NULL,
    `request_hash` CHAR(64) NOT NULL,
    `result_json` JSON DEFAULT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'processing',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `completed_at` TIMESTAMP NULL DEFAULT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_bc_v2_idempotency_key` (`idempotency_key`),
    KEY `idx_bc_v2_idempotency_actor_time` (`actor_citizenid`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Additional V2 feature storage. These tables are independent of V1 data.
CREATE TABLE IF NOT EXISTS `bc_banking_v2_savings_goals` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `name` VARCHAR(80) NOT NULL,
    `target_amount` DECIMAL(15,2) NOT NULL,
    `saved_amount` DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `completed_at` TIMESTAMP NULL DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_bc_v2_goal_owner` (`citizenid`, `status`),
    CONSTRAINT `fk_bc_v2_goal_account` FOREIGN KEY (`account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_cards` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `card_token` CHAR(36) NOT NULL,
    `last_four` CHAR(4) NOT NULL,
    `pin_hash` VARCHAR(255) DEFAULT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `failed_pin_attempts` INT NOT NULL DEFAULT 0,
    `locked_until` TIMESTAMP NULL DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `replaced_at` TIMESTAMP NULL DEFAULT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_bc_v2_card_token` (`card_token`),
    KEY `idx_bc_v2_card_owner` (`citizenid`, `status`),
    CONSTRAINT `fk_bc_v2_card_account` FOREIGN KEY (`account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_businesses` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `business_name` VARCHAR(100) NOT NULL,
    `owner_citizenid` VARCHAR(50) NOT NULL,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_bc_v2_business_account` (`account_id`),
    KEY `idx_bc_v2_business_owner` (`owner_citizenid`, `status`),
    CONSTRAINT `fk_bc_v2_business_account` FOREIGN KEY (`account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_loans` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `citizenid` VARCHAR(50) NOT NULL,
    `account_id` BIGINT UNSIGNED DEFAULT NULL,
    `loan_type` VARCHAR(16) NOT NULL DEFAULT 'personal',
    `principal` DECIMAL(15,2) NOT NULL,
    `apr` DECIMAL(7,4) NOT NULL,
    `months` INT NOT NULL,
    `remaining_balance` DECIMAL(15,2) NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'pending',
    `approved_by` VARCHAR(50) DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `approved_at` TIMESTAMP NULL DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_bc_v2_loan_owner` (`citizenid`, `status`),
    CONSTRAINT `fk_bc_v2_loan_account` FOREIGN KEY (`account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_loan_payments` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `loan_id` BIGINT UNSIGNED NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `amount` DECIMAL(15,2) NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_bc_v2_loan_payment` (`loan_id`, `id`),
    CONSTRAINT `fk_bc_v2_loan_payment_loan` FOREIGN KEY (`loan_id`)
        REFERENCES `bc_banking_v2_loans` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_business_expenses` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `business_id` BIGINT UNSIGNED NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `amount` DECIMAL(15,2) NOT NULL,
    `description` VARCHAR(255) NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_bc_v2_expense_business` (`business_id`, `id`),
    CONSTRAINT `fk_bc_v2_expense_business` FOREIGN KEY (`business_id`)
        REFERENCES `bc_banking_v2_businesses` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_payroll_batches` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `business_id` BIGINT UNSIGNED NOT NULL,
    `created_by` VARCHAR(50) NOT NULL,
    `total_amount` DECIMAL(15,2) NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'processing',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_bc_v2_payroll_business` (`business_id`, `id`),
    CONSTRAINT `fk_bc_v2_payroll_business` FOREIGN KEY (`business_id`)
        REFERENCES `bc_banking_v2_businesses` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_payroll_items` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `batch_id` BIGINT UNSIGNED NOT NULL,
    `employee_citizenid` VARCHAR(50) NOT NULL,
    `amount` DECIMAL(15,2) NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'pending',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_bc_v2_payroll_employee` (`employee_citizenid`, `id`),
    CONSTRAINT `fk_bc_v2_payroll_item_batch` FOREIGN KEY (`batch_id`)
        REFERENCES `bc_banking_v2_payroll_batches` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_scheduled_payments` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `recipient_account_id` BIGINT UNSIGNED DEFAULT NULL,
    `amount` DECIMAL(15,2) NOT NULL,
    `frequency` VARCHAR(16) NOT NULL,
    `next_run_at` TIMESTAMP NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_bc_v2_scheduled_due` (`status`, `next_run_at`),
    CONSTRAINT `fk_bc_v2_scheduled_source` FOREIGN KEY (`account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_bc_v2_scheduled_target` FOREIGN KEY (`recipient_account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_audit_log` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `actor_citizenid` VARCHAR(50) NOT NULL,
    `action` VARCHAR(64) NOT NULL,
    `target_type` VARCHAR(32) DEFAULT NULL,
    `target_id` VARCHAR(64) DEFAULT NULL,
    `details` JSON DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_bc_v2_audit_actor` (`actor_citizenid`, `created_at`),
    KEY `idx_bc_v2_audit_target` (`target_type`, `target_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_v2_interest_runs` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `accrual_date` DATE NOT NULL,
    `interest_amount` DECIMAL(15,2) NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'processing',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_bc_v2_interest_account_date` (`account_id`, `accrual_date`),
    CONSTRAINT `fk_bc_v2_interest_account` FOREIGN KEY (`account_id`)
        REFERENCES `bc_banking_v2_accounts` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
