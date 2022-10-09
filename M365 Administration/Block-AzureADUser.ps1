# Block and Unblock an Office user account

# We need to set the user associated property BlockCredential 
# to block user access to Office 365 service

# Block the acount

Set-AzureADUser -ObjectID lisa.pownall@44vpwy.onmicrosoft.com -AccountEnabled $false

# Ensure the account is blocked with a forced sign-out for all apps

Revoke-AzureADUserAllRefreshToken -ObjectId lisa.pownall@44vpwy.onmicrosoft.com