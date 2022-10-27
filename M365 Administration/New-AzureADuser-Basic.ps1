# This script uses only the minimum parameters needed for creating a user account. 
# It does not allow the assignment of licenses or add admin roles. We will need to use 
# separate commands to do that. A key thing to understand before using the New-AzureADUSer
# cmdlet is that it requires the password to be passed to it using a Password Profile object. 
# This object contains the password along with other properties such as requiring the user 
# to change the password upon first login. Understanding that you need a password 
# profile object informs us that our first steps will be to create the basic password
# profile in order to provision the new user.

# Connect to the Tenant

# Connect-AzureAD
# Connect-ExchangeOnline

$PasswordProfile = New-Object -TypeName Microsoft.Open.AzureAD.Model.PasswordProfile
$PasswordProfile.Password = "Pas13579"

# Provision the base user account

New-AzureADUser -DisplayName "Derek Trotter" -PasswordProfile $PasswordProfile -UserPrincipalName "derek.trotter@44vpwy.onmicrosoft.com" -MailNickname "derek.trotter" -AccountEnabled $true

