# Block and Unblock an Office user account

# We need to set the user associated property BlockCredential 
# to block user access to Office 365 service

Set-AzureADUser -ObjectID lisa.pownall@44vpwy.onmicrosoft.com -AccountEnabled $false