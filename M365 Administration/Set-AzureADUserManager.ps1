#Set-AzureADUserManager
#-ObjectId rodney.trotter@44vpwy.onmicrosoft.com 
#-RefObjectId 9c8b7ba8-af0a-4ddb-aeb1-6a02347f2cba

$User  = "rodney.trotter@44vpwy.onmicrosoft.com"
$Manager  = "joe.woodruff@44vpwy.onmicrosoft.com"
$ManagerObj = Get-AzureADUser -ObjectId $Manager
Set-AzureADUserManager -ObjectId $User -RefObjectId $ManagerObj.ObjectId