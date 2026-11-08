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
