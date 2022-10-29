# Assign the user's manager in Azure AD

Set-AzureADUserManager -ObjectId rodney.trotter@44vpwy.onmicrosoft.com
-RefObjectId (Get-AzureADuser -ObjectID joe.woodruff@44vpwy.onmicrosoft.com).objectId