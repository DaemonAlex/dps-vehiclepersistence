-- DPS Vehicle Persistence - Database Table
-- This table is automatically created on resource start
-- Run this manually only if automatic creation fails

CREATE TABLE IF NOT EXISTS `dps_world_vehicles` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `plate` VARCHAR(8) NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `model` VARCHAR(50) NOT NULL,
    `coords` LONGTEXT NOT NULL,
    `heading` FLOAT NOT NULL,
    `props` LONGTEXT,
    `fuel` FLOAT DEFAULT 100.0,
    `body` FLOAT DEFAULT 1000.0,
    `engine` FLOAT DEFAULT 1000.0,
    `saved_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY `plate_unique` (`plate`),
    INDEX `idx_citizenid` (`citizenid`),
    INDEX `idx_saved_at` (`saved_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
