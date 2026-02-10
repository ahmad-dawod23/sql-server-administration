/*step 1*/

Update STATISTICS HumanResources.Employee 

/*step 2*/

Update STATISTICS HumanResources.Employee IX_Employee_OrganizationLevel_OrganizationNode 

/*step 3*/
Update STATISTICS HumanResources.Employee IX_Employee_OrganizationLevel_OrganizationNode WITH FULLSCAN 

/*step 4*/
Update STATISTICS HumanResources.Employee IX_Employee_OrganizationLevel_OrganizationNode WITH SAMPLE 100 PERCENT 

/*step 5*/
Update STATISTICS HumanResources.Employee IX_Employee_OrganizationLevel_OrganizationNode WITH SAMPLE 10 PERCENT 

/*step 6*/

sp_updatestats
