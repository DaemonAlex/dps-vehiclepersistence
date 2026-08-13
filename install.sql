-- DPS Vehicle Persistence - Database Table
-- This table is automatically created on resource start
-- Run this manually only if automatic creation fails

CREATE TABLE IF NOT EXISTS `dps_world_vehicles` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `plate` VARCHAR(8) NOT NULL,
    `citizenid` VARCHAR(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    `model` VARCHAR(50) NOT NULL,
    `vehicle_type` VARCHAR(24) NOT NULL DEFAULT 'automobile',
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
