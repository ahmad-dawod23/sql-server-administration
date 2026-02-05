/*
    API LOGGIN CLEAN UP SCRITP
     APPLICATION EXCLUSION LIST:
    'EDC.API.CreditInsurance.InternalService',
    'EDC.API.CreditInsurance.InternalService.CLZ2',
    'EDC.API.CreditInsurance.Service',
    'EDC.API.CreditInsurance.CLZ2',
    'EDC.API.DigitalPayments',
    'EDC.API.DigitalPayments.CLZ2',
    'EDC.API.PeoplesoftPayment',
    'EDC.API.PeoplesoftPayment.CLZ2',
    'EDC.Func.DigitalPayments',
    'EDC.Func.DigitalPayments.CLZ2'
 
    DELETE ROWS FROM `dbo.EventEntry` OLDER THAN 90 DAYS
    DELETE ROWS FROM `dbo.ExceptionEntry` OLDER THAN 2 YEARS
*/
 
--- EventEntry
DECLARE @sumEventEntryToDelete INT;
DECLARE @DeletedRowsTable1 INT;
DECLARE @DeletedRowsTable2 INT;
 
SELECT @sumEventEntryToDelete = COUNT(ID)
FROM dbo.EventEntry WITH (NOLOCK) WHERE Timestamp < DATEADD(DAY, -90, GETDATE()) and  Application not in (
'EDC.API.CreditInsurance.InternalService',
'EDC.API.CreditInsurance.InternalService.CLZ2',
'EDC.API.CreditInsurance.Service',
        'EDC.API.CreditInsurance.CLZ2',
        'EDC.API.DigitalPayments',
        'EDC.API.DigitalPayments.CLZ2',
        'EDC.API.PeoplesoftPayment',
        'EDC.API.PeoplesoftPayment.CLZ2',
        'EDC.Func.DigitalPayments',
        'EDC.Func.DigitalPayments.CLZ2')
 
DECLARE @batchSize INT = 5000;
DECLARE @eventEntryIterations INT = @sumEventEntryToDelete/@batchSize;
DECLARE @eventEntryIterator INT = 0;
 
WHILE @eventEntryIterations > @eventEntryIterator
BEGIN
    BEGIN TRANSACTION
        DELETE TOP (@batchSize)
        FROM dbo.EventEntry
        WHERE Timestamp < DATEADD(DAY, -90, GETDATE()) and  Application not in (
        'EDC.API.CreditInsurance.InternalService',
        'EDC.API.CreditInsurance.InternalService.CLZ2',
        'EDC.API.CreditInsurance.Service',
                'EDC.API.CreditInsurance.CLZ2',
                'EDC.API.DigitalPayments',
                'EDC.API.DigitalPayments.CLZ2',
                'EDC.API.PeoplesoftPayment',
                'EDC.API.PeoplesoftPayment.CLZ2',
                'EDC.Func.DigitalPayments',
                'EDC.Func.DigitalPayments.CLZ2')
 
        SET @eventEntryIterator = @eventEntryIterator + 1;
		SET @DeletedRowsTable1 = @@ROWCOUNT;
    COMMIT TRANSACTION
 
	PRINT CONCAT('EventEntry - Deleted rows in this batch: ', @DeletedRowsTable1);
END;
--- EventEntry
 
 
--- ExceptionEntry
DECLARE @sumExceptionEntryToDelete INT;
SELECT @sumExceptionEntryToDelete = COUNT(ID) 
FROM dbo.ExceptionEntry WITH (NOLOCK) WHERE Timestamp < DATEADD(YEAR, -2, GETDATE()) and  Application not in (
'EDC.API.CreditInsurance.InternalService',
'EDC.API.CreditInsurance.InternalService.CLZ2',
'EDC.API.CreditInsurance.Service',
        'EDC.API.CreditInsurance.CLZ2',
        'EDC.API.DigitalPayments',
        'EDC.API.DigitalPayments.CLZ2',
        'EDC.API.PeoplesoftPayment',
        'EDC.API.PeoplesoftPayment.CLZ2',
        'EDC.Func.DigitalPayments',
        'EDC.Func.DigitalPayments.CLZ2')
 
DECLARE @exceptionEntryIterations INT = @sumExceptionEntryToDelete/@batchSize;
DECLARE @exceptionEntryIterator INT = 0;
 
WHILE @exceptionEntryIterations > @exceptionEntryIterator
BEGIN
    BEGIN TRANSACTION
        DELETE TOP (@batchSize)
        FROM dbo.ExceptionEntry
        WHERE Timestamp < DATEADD(YEAR, -2, GETDATE()) and  Application not in (
        'EDC.API.CreditInsurance.InternalService',
        'EDC.API.CreditInsurance.InternalService.CLZ2',
        'EDC.API.CreditInsurance.Service',
                'EDC.API.CreditInsurance.CLZ2',
                'EDC.API.DigitalPayments',
                'EDC.API.DigitalPayments.CLZ2',
                'EDC.API.PeoplesoftPayment',
                'EDC.API.PeoplesoftPayment.CLZ2',
                'EDC.Func.DigitalPayments',
                'EDC.Func.DigitalPayments.CLZ2')
 
        SET @eventEntryIterator = @eventEntryIterator + 1;
 
		SET @DeletedRowsTable2 = @@ROWCOUNT;
    COMMIT TRANSACTION
 
	PRINT CONCAT('ExceptionEntry - Deleted rows in this batch: ', @DeletedRowsTable2);
END;
--- ExceptionEntry