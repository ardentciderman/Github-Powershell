# Set the colleague's manager in the AzureAD/M365

Connect-AzureAD -confirm

$User  = "rodney.trotter@44vpwy.onmicrosoft.com"
$Manager  = "joe.woodruff@44vpwy.onmicrosoft.com"
$ManagerObj = Get-AzureADUser -ObjectId $Manager
Set-AzureADUserManager -ObjectId $User -RefObjectId $ManagerObj.ObjectId