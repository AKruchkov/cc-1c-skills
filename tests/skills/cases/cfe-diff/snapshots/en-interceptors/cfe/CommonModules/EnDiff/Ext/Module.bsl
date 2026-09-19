#Region Public
&ChangeAndValidate("Write")
Procedure Тест_Write(Item)
	BeginTransaction();
	Item.Write();
#Insert // проверка прав
	CheckRights(Item);
#EndInsert
	CommitTransaction();
EndProcedure
#EndRegion
