CREATE TABLE IF NOT EXISTS `bc_banking_accounts` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `citizenid` VARCHAR(50) NOT NULL,
    `account_number` VARCHAR(20) NOT NULL,
    `account_type` VARCHAR(30) NOT NULL DEFAULT 'checking',
    `balance` DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (`id`),
    UNIQUE KEY `unique_citizenid` (`citizenid`),
    UNIQUE KEY `unique_account_number` (`account_number`),

    INDEX `idx_citizenid` (`citizenid`),
    INDEX `idx_account_number` (`account_number`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `bc_banking_transactions` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `citizenid` VARCHAR(50) NOT NULL,
    `transaction_type` VARCHAR(30) NOT NULL,
    `amount` DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    `description` VARCHAR(255) DEFAULT NULL,
    `related_account` VARCHAR(20) DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (`id`),

    INDEX `idx_transaction_citizenid` (`citizenid`),
    INDEX `idx_transaction_type` (`transaction_type`),
    INDEX `idx_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
