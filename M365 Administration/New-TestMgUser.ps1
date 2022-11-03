$NewPassword = @{}
$NewPassword["Password"]= "Liverp00l1."
$NewPassword["ForceChangePasswordNextSignIn"] = $True

New-MgUser -UserPrincipalName "Paul.Nixon@44vpwy.onmicrosoft.com" -DisplayName "Paul Nixon" -PasswordProfile $NewPassword -MailNickName "paul.nixon" -AccountEnabled