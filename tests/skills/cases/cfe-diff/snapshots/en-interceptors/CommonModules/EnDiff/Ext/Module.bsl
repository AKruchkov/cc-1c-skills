#Region Public

Procedure Write(Item) Export
	BeginTransaction();
	Item.Write();
	CommitTransaction();
EndProcedure

#EndRegion
