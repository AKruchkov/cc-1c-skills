#Region Public

Procedure Write(Item) Export
	BeginTransaction();
	Item.Write();
	LogEvent();
	CommitTransaction();
EndProcedure

#EndRegion
