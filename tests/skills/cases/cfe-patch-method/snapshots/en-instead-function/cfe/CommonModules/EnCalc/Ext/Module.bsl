#Region Private

#If Server Then

&Around("Rate")
Function Тест_Rate(Val Currency, Period)
	Result = ProceedWithCall(Currency, Period);
	// TODO: доработать поведение
	Return Result;
EndFunction

#EndIf

#EndRegion
