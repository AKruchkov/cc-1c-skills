#Region Public
&ChangeAndValidate("Write")
Procedure Тест_Write(Item)
	BeginTransaction();
	Item.Write();
#Insert
	CheckRights(Item);
#EndInsert
	LogEvent();
	CommitTransaction();
EndProcedure
#EndRegion
