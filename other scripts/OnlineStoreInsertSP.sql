-- =================================================================
-- Stored Procedure: usp_CreateFullOrder
-- =================================================================
-- Description:
-- This procedure creates a complete customer order by inserting
-- records into multiple tables sequentially within a single transaction.
-- It handles the creation of a new customer, address, product,
-- order, order item, and payment.
--
-- Parameters:
--   - Customer Information
--   - Address Information (used for both shipping and billing)
--   - Product Information (including category)
--   - Order and Payment details
--
-- Output:
--   - @NewOrderID: The ID of the newly created order.
--
-- Usage Example:
-- DECLARE @OrderID INT;
-- EXEC usp_CreateFullOrder
--     @FirstName = N'John',
--     @LastName = N'Doe',
--     @Email = N'john.doe@example.com',
--     @PasswordHash = N'a_very_secure_hash',
--     @PhoneNumber = N'555-0101',
--     @AddressLine1 = N'123 Maple Street',
--     @City = N'Anytown',
--     @State = N'Anystate',
--     @PostalCode = N'12345',
--     @Country = N'USA',
--     @CategoryName = N'Electronics',
--     @ProductName = N'SuperWidget 2.0',
--     @ProductDescription = N'A new and improved widget.',
--     @Price = 199.99,
--     @SKU = N'SW20-XYZ',
--     @StockQuantity = 100,
--     @OrderQuantity = 2,
--     @PaymentMethod = N'Credit Card',
--     @TransactionID = N'txn_123456789',
--     @NewOrderID = @OrderID OUTPUT;
-- SELECT @OrderID AS NewOrderID;
-- =================================================================
CREATE PROCEDURE usp_CreateFullOrder
    -- Customer Parameters
    @FirstName NVARCHAR(50),
    @LastName NVARCHAR(50),
    @Email NVARCHAR(100),
    @PasswordHash NVARCHAR(255),
    @PhoneNumber VARCHAR(20),
    -- Address Parameters (for both Shipping and Billing)
    @AddressLine1 NVARCHAR(255),
    @City NVARCHAR(100),
    @State NVARCHAR(100),
    @PostalCode NVARCHAR(20),
    @Country NVARCHAR(50),
    -- Category & Product Parameters
    @CategoryName NVARCHAR(100),
    @ProductName NVARCHAR(255),
    @ProductDescription NVARCHAR(MAX),
    @Price DECIMAL(10, 2),
    @SKU NVARCHAR(50),
    @StockQuantity INT,
    -- Order & Payment Parameters
    @OrderQuantity INT,
    @PaymentMethod NVARCHAR(50),
    @TransactionID NVARCHAR(255),
    -- Output Parameter
    @NewOrderID INT OUTPUT
AS
BEGIN
    -- SET NOCOUNT ON prevents the sending of DONE_IN_PROC messages for each statement
    -- in a stored procedure.
    SET NOCOUNT ON;

    -- Declare variables to hold the new IDs from IDENTITY columns
    DECLARE @CustomerID INT;
    DECLARE @AddressID INT;
    DECLARE @CategoryID INT;
    DECLARE @ProductID INT;
    DECLARE @TotalAmount DECIMAL(10, 2);

    -- Start a transaction
    BEGIN TRANSACTION;

    BEGIN TRY
        -- 1. Insert into Customers
        INSERT INTO Customers (FirstName, LastName, Email, PasswordHash, PhoneNumber)
        VALUES (@FirstName, @LastName, @Email, @PasswordHash, @PhoneNumber);
        -- Get the ID of the new customer
        SET @CustomerID = SCOPE_IDENTITY();

        -- 2. Insert into Addresses
        -- For this example, we use the same address for shipping and billing
        INSERT INTO Addresses (CustomerID, AddressLine1, AddressLine2, City, State, PostalCode, Country, AddressType)
        VALUES (@CustomerID, @AddressLine1, NULL, @City, @State, @PostalCode, @Country, 'Shipping');
        -- Get the ID of the new address
        SET @AddressID = SCOPE_IDENTITY();

        -- 3. Check for Product Category and insert if it doesn't exist
        SELECT @CategoryID = CategoryID FROM Product_Categories WHERE CategoryName = @CategoryName;
        IF @CategoryID IS NULL
        BEGIN
            INSERT INTO Product_Categories (CategoryName, Description)
            VALUES (@CategoryName, 'Auto-generated category');
            SET @CategoryID = SCOPE_IDENTITY();
        END

        -- 4. Insert into Products
        INSERT INTO Products (ProductName, Description, Price, SKU, StockQuantity, CategoryID)
        VALUES (@ProductName, @ProductDescription, @Price, @SKU, @StockQuantity, @CategoryID);
        -- Get the ID of the new product
        SET @ProductID = SCOPE_IDENTITY();

        -- 5. Calculate Total Amount for the Order
        SET @TotalAmount = @Price * @OrderQuantity;

        -- 6. Insert into Orders
        INSERT INTO Orders (CustomerID, TotalAmount, ShippingAddressID, BillingAddressID)
        VALUES (@CustomerID, @TotalAmount, @AddressID, @AddressID); -- Using same address for billing
        -- Get the ID of the new order
        SET @NewOrderID = SCOPE_IDENTITY();

        -- 7. Insert into Order_Items
        INSERT INTO Order_Items (OrderID, ProductID, Quantity, UnitPrice)
        VALUES (@NewOrderID, @ProductID, @OrderQuantity, @Price);

        -- 8. Insert into Payments
        INSERT INTO Payments (OrderID, PaymentMethod, Amount, TransactionID)
        VALUES (@NewOrderID, @PaymentMethod, @TotalAmount, @TransactionID);
        
        -- If all statements succeeded, commit the transaction
        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        -- If an error occurred, roll back the transaction
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- You can re-throw the error for the calling application to handle
        -- Or log the error details to a table
        THROW;
    END CATCH
END;
GO
