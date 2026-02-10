-- =================================================================
-- SQL Server script for creating the Online Store database tables.
-- =================================================================
-- The tables are created in an order that respects foreign key
-- constraints to prevent dependency errors during execution.
-- =================================================================
use OnlineStore

go
-- 1. Customers Table
-- Stores customer account information.
CREATE TABLE Customers (
    CustomerID INT PRIMARY KEY IDENTITY(1,1),
    FirstName NVARCHAR(50) NOT NULL,
    LastName NVARCHAR(50) NOT NULL,
    Email NVARCHAR(100) NOT NULL UNIQUE,
    PasswordHash NVARCHAR(255) NOT NULL,
    PhoneNumber VARCHAR(20) NULL,
    CreatedAt DATETIME2 DEFAULT GETDATE(),
    UpdatedAt DATETIME2 DEFAULT GETDATE()
);
GO

-- 2. Addresses Table
-- Stores shipping and billing addresses linked to customers.
CREATE TABLE Addresses (
    AddressID INT PRIMARY KEY IDENTITY(1,1),
    CustomerID INT NOT NULL,
    AddressLine1 NVARCHAR(255) NOT NULL,
    AddressLine2 NVARCHAR(255) NULL,
    City NVARCHAR(100) NOT NULL,
    State NVARCHAR(100) NOT NULL,
    PostalCode NVARCHAR(20) NOT NULL,
    Country NVARCHAR(50) NOT NULL,
    AddressType NVARCHAR(10) NOT NULL,
    CONSTRAINT FK_Addresses_Customers FOREIGN KEY (CustomerID) REFERENCES Customers(CustomerID),
    CONSTRAINT CHK_AddressType CHECK (AddressType IN ('Shipping', 'Billing'))
);
GO

-- 3. Product_Categories Table
-- Organizes products into a hierarchical structure.
CREATE TABLE Product_Categories (
    CategoryID INT PRIMARY KEY IDENTITY(1,1),
    CategoryName NVARCHAR(100) NOT NULL UNIQUE,
    Description NVARCHAR(MAX) NULL,
    ParentCategoryID INT NULL,
    CONSTRAINT FK_Product_Categories_Self FOREIGN KEY (ParentCategoryID) REFERENCES Product_Categories(CategoryID)
);
GO

-- 4. Products Table
-- Contains detailed information for each product.
CREATE TABLE Products (
    ProductID INT PRIMARY KEY IDENTITY(1,1),
    ProductName NVARCHAR(255) NOT NULL,
    Description NVARCHAR(MAX) NULL,
    Price DECIMAL(10, 2) NOT NULL,
    SKU NVARCHAR(50) NOT NULL UNIQUE,
    StockQuantity INT NOT NULL DEFAULT 0,
    CategoryID INT NULL,
    ImageURL NVARCHAR(2048) NULL,
    CreatedAt DATETIME2 DEFAULT GETDATE(),
    UpdatedAt DATETIME2 DEFAULT GETDATE(),
    CONSTRAINT FK_Products_Product_Categories FOREIGN KEY (CategoryID) REFERENCES Product_Categories(CategoryID),
    CONSTRAINT CHK_Price CHECK (Price >= 0),
    CONSTRAINT CHK_StockQuantity CHECK (StockQuantity >= 0)
);
GO

-- 5. Orders Table
-- Header information for each customer order.
CREATE TABLE Orders (
    OrderID INT PRIMARY KEY IDENTITY(1,1),
    CustomerID INT NOT NULL,
    OrderDate DATETIME2 DEFAULT GETDATE(),
    TotalAmount DECIMAL(10, 2) NOT NULL,
    Status NVARCHAR(20) NOT NULL DEFAULT 'Pending',
    ShippingAddressID INT NOT NULL,
    BillingAddressID INT NOT NULL,
    CONSTRAINT FK_Orders_Customers FOREIGN KEY (CustomerID) REFERENCES Customers(CustomerID),
    CONSTRAINT FK_Orders_ShippingAddress FOREIGN KEY (ShippingAddressID) REFERENCES Addresses(AddressID),
    CONSTRAINT FK_Orders_BillingAddress FOREIGN KEY (BillingAddressID) REFERENCES Addresses(AddressID),
    CONSTRAINT CHK_TotalAmount CHECK (TotalAmount >= 0)
);
GO

-- 6. Order_Items Table
-- A junction table linking products to orders (line items).
CREATE TABLE Order_Items (
    OrderItemID INT PRIMARY KEY IDENTITY(1,1),
    OrderID INT NOT NULL,
    ProductID INT NOT NULL,
    Quantity INT NOT NULL,
    UnitPrice DECIMAL(10, 2) NOT NULL,
    CONSTRAINT FK_Order_Items_Orders FOREIGN KEY (OrderID) REFERENCES Orders(OrderID),
    CONSTRAINT FK_Order_Items_Products FOREIGN KEY (ProductID) REFERENCES Products(ProductID),
    CONSTRAINT CHK_Quantity CHECK (Quantity > 0),
    CONSTRAINT CHK_UnitPrice CHECK (UnitPrice >= 0)
);
GO

-- 7. Payments Table
-- Stores payment details for each order.
CREATE TABLE Payments (
    PaymentID INT PRIMARY KEY IDENTITY(1,1),
    OrderID INT NOT NULL,
    PaymentDate DATETIME2 DEFAULT GETDATE(),
    PaymentMethod NVARCHAR(50) NOT NULL,
    Amount DECIMAL(10, 2) NOT NULL,
    TransactionID NVARCHAR(255) NULL,
    Status NVARCHAR(20) NOT NULL DEFAULT 'Completed',
    CONSTRAINT FK_Payments_Orders FOREIGN KEY (OrderID) REFERENCES Orders(OrderID),
    CONSTRAINT CHK_PaymentStatus CHECK (Status IN ('Completed', 'Failed', 'Pending', 'Refunded'))
);
GO
