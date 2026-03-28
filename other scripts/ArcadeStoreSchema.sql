
-- Create Tables
CREATE TABLE Games (
    GameID INT IDENTITY(1,1) PRIMARY KEY,
    Title VARCHAR(100) NOT NULL,
    Publisher VARCHAR(50),
    ReleaseYear INT,
    Genre VARCHAR(50)
);

CREATE TABLE Machines (
    MachineID INT IDENTITY(1,1) PRIMARY KEY,
    GameID INT FOREIGN KEY REFERENCES Games(GameID),
    CabinetType VARCHAR(50), -- e.g., 'Upright', 'Cocktail', 'Candy'
    Condition VARCHAR(20) DEFAULT 'Working' -- 'Working', 'Maintenance', 'Broken'
);

CREATE TABLE Players (
    PlayerID INT IDENTITY(1,1) PRIMARY KEY,
    Gamertag VARCHAR(50) UNIQUE NOT NULL,
    JoinDate DATE DEFAULT GETDATE()
);

CREATE TABLE Scores (
    ScoreID INT IDENTITY(1,1) PRIMARY KEY,
    MachineID INT FOREIGN KEY REFERENCES Machines(MachineID),
    PlayerID INT FOREIGN KEY REFERENCES Players(PlayerID),
    Score BIGINT NOT NULL,
    AchieveDate DATETIME DEFAULT GETDATE()
);

-- Insert Sample Data
INSERT INTO Games (Title, Publisher, ReleaseYear, Genre) VALUES
('Street Fighter II', 'Capcom', 1991, 'Fighting'),
('Pac-Man', 'Namco', 1980, 'Maze'),
('Donkey Kong', 'Nintendo', 1981, 'Platformer'),
('Metal Slug', 'SNK', 1996, 'Run and Gun'),
('Alien vs. Predator', 'Capcom', 1994, 'Beat em up');

INSERT INTO Machines (GameID, CabinetType, Condition) VALUES
(1, 'Candy', 'Working'),
(1, 'Upright', 'Maintenance'),
(2, 'Cocktail', 'Working'),
(3, 'Upright', 'Working'),
(4, 'Candy', 'Broken'),
(5, 'Candy', 'Working');

INSERT INTO Players (Gamertag, JoinDate) VALUES
('QuarterMuncher', '2025-01-15'),
('ComboKing', '2025-02-10'),
('GhostEater', '2025-03-05'),
('PixelJunkie', '2025-03-20');

INSERT INTO Scores (MachineID, PlayerID, Score, AchieveDate) VALUES
(1, 2, 950000, '2025-04-01 14:30:00'),
(1, 1, 820000, '2025-04-02 16:45:00'),
(3, 3, 3333360, '2025-04-05 10:15:00'),
(3, 4, 125000, '2025-04-06 11:20:00'),
(4, 1, 45000, '2025-04-10 19:00:00'),
(6, 2, 1200500, '2025-04-12 21:00:00'),
(6, 1, 980000, '2025-04-13 22:30:00'),
(1, 2, 975000, '2025-04-15 15:00:00');


-- Create New Tables
CREATE TABLE HardwareComponents (
    ComponentID INT IDENTITY(1,1) PRIMARY KEY,
    MachineID INT FOREIGN KEY REFERENCES Machines(MachineID),
    ComponentType VARCHAR(50), -- e.g., 'Monitor', 'Joystick', 'Buttons', 'Motherboard'
    Brand VARCHAR(50),         -- e.g., 'Sanwa', 'Happ', 'Dell', 'Sony'
    InstallDate DATE
);

CREATE TABLE Technicians (
    TechID INT IDENTITY(1,1) PRIMARY KEY,
    TechName VARCHAR(50),
    HourlyRate DECIMAL(10,2)
);

CREATE TABLE MaintenanceLogs (
    LogID INT IDENTITY(1,1) PRIMARY KEY,
    MachineID INT FOREIGN KEY REFERENCES Machines(MachineID),
    TechID INT FOREIGN KEY REFERENCES Technicians(TechID),
    ComponentID INT NULL FOREIGN KEY REFERENCES HardwareComponents(ComponentID),
    IssueDescription VARCHAR(255),
    PartsCost DECIMAL(10,2),
    LaborHours INT,
    ServiceDate DATETIME DEFAULT GETDATE()
);

CREATE TABLE TokenTransactions (
    TransactionID INT IDENTITY(1,1) PRIMARY KEY,
    PlayerID INT FOREIGN KEY REFERENCES Players(PlayerID),
    TransactionType VARCHAR(50), -- 'Purchase', 'Played Game', 'Refund'
    TokenAmount INT,             -- Positive for bought, negative for spent
    TransactionDate DATETIME DEFAULT GETDATE()
);

-- Insert Sample Data
INSERT INTO HardwareComponents (MachineID, ComponentType, Brand, InstallDate) VALUES
(1, 'Joystick', 'Sanwa', '2024-11-01'),
(1, 'Buttons', 'Sanwa', '2024-11-01'),
(3, 'Monitor', 'Sony CRT', '2023-05-15'),
(4, 'Motherboard', 'Dell Mini', '2025-01-10'),
(4, 'GPU', 'GTX 750 Ti', '2025-01-10'),
(5, 'Power Supply', 'Happ', '2022-08-20');

INSERT INTO Technicians (TechName, HourlyRate) VALUES
('Sparky Dave', 45.00),
('Solder Sarah', 55.00);

INSERT INTO MaintenanceLogs (MachineID, TechID, ComponentID, IssueDescription, PartsCost, LaborHours, ServiceDate) VALUES
(5, 1, 6, 'Replaced blown fuses in power supply', 15.00, 2, '2025-03-10 09:00:00'),
(1, 2, 1, 'Lubricated Player 1 joystick', 0.00, 1, '2025-03-15 14:00:00'),
(4, 2, 4, 'OS update and emulator configuration', 0.00, 3, '2025-04-01 11:30:00'),
(3, 1, 3, 'CRT geometry adjustment', 0.00, 1, '2025-04-10 16:00:00');

INSERT INTO TokenTransactions (PlayerID, TransactionType, TokenAmount, TransactionDate) VALUES
(1, 'Purchase', 100, '2025-04-01 10:00:00'),
(1, 'Played Game', -4, '2025-04-02 16:40:00'),
(2, 'Purchase', 50, '2025-04-01 14:00:00'),
(2, 'Played Game', -4, '2025-04-01 14:25:00'),
(1, 'Played Game', -4, '2025-04-10 18:55:00'),
(3, 'Purchase', 200, '2025-04-05 09:30:00'),
(3, 'Played Game', -4, '2025-04-05 10:10:00');