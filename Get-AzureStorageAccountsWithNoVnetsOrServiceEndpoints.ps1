<#
.SYNOPSIS
    Script to search for Azure Storage Accounts with No VNets or Service Endpoints

.DESCRIPTION
    This script will search every Subscription for Storage Accounts.
    Each Storage Account will be checked for firewal rules.
    It will examine each rule to look for:
        Is the rule defined?
        If the rule is defined, are there Subnets added?
        If there are Subnets, do the have Service Endpoints for Microsoft.Storage?
    All Storage Accounts that do not have firewall rules fully configured with Subnets and Service Endpoints will be added to the CSV file.

.PARAMETER FileSaveLocation
    Specify the output location for the CSV File
    Example: 'C:\Temp'
    Default location is \UserProfile\Documents\

.PARAMETER Environment
    Specify the target Azure Environment for logon. 
    Example AzureCloud or AzureUSGovernment

.EXAMPLE
    .\Get-AzureStorageAccountsWithNoVnetsOrServiceEndpoints.ps1 -FileSaveLocation 'C:\Temp' -Environment 'AzureCloud'
#>
[CmdletBinding()]
param
(
	# Specify the output location for the CSV File
	[Parameter(Mandatory=$false,HelpMessage="Specify the output location for the CSV File. Example C:\Temp")]
	[String]$FileSaveLocation = "$env:USERPROFILE\Documents\",

	[Parameter(Mandatory=$true,HelpMessage="Specify the target Azure Environment for logon. Example AzureCloud or AzureUSGovernment")]
    [ValidateSet('AzureCloud','AzureUSGovernment')]
	[String]$Environment
)

# Set verbose preference
$VerbosePreference = 'Continue'

# Connect to Azure (Azure Cloud)
if ($Environment -eq 'AzureCloud')
{
    Connect-AzureRmAccount
}

# Connect to Azure (Azure US Government)
if ($Environment -eq 'AzureUSGovernment')
{
    Connect-AzureRmAccount -Environment 'AzureUSGovernment'
}

# Create Data Table Structure
#Write-Output 'Creating DataTable Structure'
$DataTable = New-Object System.Data.DataTable
$DataTable.Columns.Add("StorageAccountName","string") | Out-Null
$DataTable.Columns.Add("Notes","string") | Out-Null
$DataTable.Columns.Add("StorageAccountSubscriptionName","string") | Out-Null
$DataTable.Columns.Add("StorageAccountResourceGroupName","string") | Out-Null
$DataTable.Columns.Add("VNetName","string") | Out-Null
$DataTable.Columns.Add("VNetResourceGroupName","string") | Out-Null
$DataTable.Columns.Add("SubnetName","string") | Out-Null
$DataTable.Columns.Add("VNetSubscriptionName","string") | Out-Null

# Get All Subscriptions
$Subscriptions = Get-AzureRmSubscription
Write-Verbose "Found $($Subscriptions.Count) Subscriptions"

# loop through each subscription
foreach ($Subscription in $Subscriptions)
{
    # Set the working subscription
    Select-AzureRmSubscription -Subscription $Subscription | Out-Null
    Write-Verbose "Looking for Storage Accounts in Subscription $($Subscription.Name)"

    # Find all storage accounts in the subscription
    $StorageAccounts = Get-AzureRmStorageAccount
    Write-Verbose "Found $($StorageAccounts.Count) Storage Accounts"

    # Loop through the storage accounts
    foreach ($StorageAccount in $StorageAccounts)
    {
        Write-Verbose "Checking Storage Account $($StorageAccount.StorageAccountName)"

        # Check if the storage account has a virtual network rule applied
        if ($($StorageAccount.NetworkRuleSet.VirtualNetworkRules))
        {
            if ($($StorageAccount.NetworkRuleSet.DefaultAction) -eq 'Allow')
            {
                Write-Warning "Storage Account $($StorageAccount.StorageAccountName) is set to allow access from all networks"
                # Add row of data to the CSV file
                $NewRow = $DataTable.NewRow()
                $NewRow.StorageAccountName = $($StorageAccount.StorageAccountName)
                $NewRow.StorageAccountSubscriptionName = $($Subscription.Name)
                $NewRow.StorageAccountResourceGroupName = $($StorageAccount.ResourceGroupName)
                $NewRow.VNetName = ''
                $NewRow.VNetResourceGroupName = ''
                $NewRow.SubnetName = ''
                $NewRow.VNetSubscriptionName = ''
                $NewRow.Notes = 'Storage Account is set to allow access from all networks'
                $DataTable.Rows.Add($NewRow)
            }
            else
            {
                Write-Verbose "Found $(($StorageAccount.NetworkRuleSet.VirtualNetworkRules).Count) Virtual Network Rules"
                foreach ($Rule in $StorageAccount.NetworkRuleSet.VirtualNetworkRules)
                {
                    # Extract relevant VNet information from the Virtual Network Resource Id
                    $VNetName = ($Rule.VirtualNetworkResourceId.Split('/') | Select-Object -Last 3)[0]
                    $VNetResourceGroupName = ($Rule.VirtualNetworkResourceId.Split('/') | Select-Object -Last 7)[0]
                    $VNetSubscriptionID = ($Rule.VirtualNetworkResourceId.Split('/'))[2]
                    $SubnetName = ($Rule.VirtualNetworkResourceId.Split('/') | Select-Object -Last 1)

                    Write-Verbose "Checking VNet $VNetName to see if the subnets are properly configured"

                    # If the VNet is in a subscription that is different than the Storage Account, switch the working subscription
                    if ($($Subscription.SubscriptionId) -ne $VNetSubscriptionID)
                    {
                        Write-Verbose "The storage account is not in the same subscription as the VNet. Switching Subscriptions"
                        $VNetIsInDifferentSubscription = $true
                        $VNetSubscription = Get-AzureRmSubscription -SubscriptionId $VNetSubscriptionID
                        Select-AzureRmSubscription $VNetSubscription | Out-Null
                    }

                    # Get the subnet configuration for the extracted VNet
                    try
                    {
                        $SubnetConfigs = Get-AzureRmVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroupName -WarningAction SilentlyContinue -ErrorAction Stop | Get-AzureRmVirtualNetworkSubnetConfig -ErrorAction Stop
                    }
                    catch
                    {
                        # Check to see if there is a 404 error returned
                        If ($Error[0].Exception -like "*StatusCode: 404*")
                        {
                            Write-Warning 'Assigned Subnet or VNet may have been deleted.'
                            $NewRow = $DataTable.NewRow()
                            $NewRow.StorageAccountName = $($StorageAccount.StorageAccountName)
                            $NewRow.StorageAccountSubscriptionName = $($Subscription.Name)
                            $NewRow.StorageAccountResourceGroupName = $($StorageAccount.ResourceGroupName)
                            $NewRow.VNetName = $VNetName
                            $NewRow.VNetResourceGroupName = $VNetResourceGroupName
                            $NewRow.SubnetName = ($SubnetConfig.Name)
                            if ($VNetIsInDifferentSubscription -eq $true)
                            {
                                $NewRow.VNetSubscriptionName = ($VNetSubscription.Name)
                            }
                            else
                            {
                                $NewRow.VNetSubscriptionName = ($Subscription.Name)
                            }
                            $NewRow.Notes = 'VNet was assigned, but seems to have been deleted.'
                            $DataTable.Rows.Add($NewRow)
                            Continue
                        }
                        else
                        {
                            $_.Exception
                            break
                        }
                    }
                    Write-Verbose "Found $($SubnetConfigs.Count) Subnets"

                    # Loop through Subnet Configurations to check for Service Endpoints
                    foreach ($SubnetConfig in $SubnetConfigs)
                    {
                        Write-Verbose "Checking Subnet $($SubnetConfig.Name)"
                        # Check to see if the attached access VNet Subnet has a Service Endpoint for Microsoft.Storage
                        if ($($SubnetConfig.ServiceEndpoints.Service) -contains "Microsoft.Storage")
                        {
                            Write-Verbose "Storage Account Subnet $($SubnetConfig.Name) has a Service Endpoint for Microsoft.Storage"
                        }
                        else
                        {
                            Write-Warning "Storage Account $($StorageAccount.StorageAccountName) in Resource Group $($StorageAccount.ResourceGroupName) has no Service Endpoint for Subnet $($SubnetConfig.Name) in VNet $VNetName"
                            # Add row of data to the CSV file
                            $NewRow = $DataTable.NewRow()
                            $NewRow.StorageAccountName = $($StorageAccount.StorageAccountName)
                            $NewRow.StorageAccountSubscriptionName = $($Subscription.Name)
                            $NewRow.StorageAccountResourceGroupName = $($StorageAccount.ResourceGroupName)
                            $NewRow.VNetName = $VNetName
                            $NewRow.VNetResourceGroupName = $VNetResourceGroupName
                            $NewRow.SubnetName = ($SubnetConfig.Name)
                            if ($VNetIsInDifferentSubscription -eq $true)
                            {
                                $NewRow.VNetSubscriptionName = ($VNetSubscription.Name)
                            }
                            else
                            {
                                $NewRow.VNetSubscriptionName = ($Subscription.Name)
                            }
                            $NewRow.Notes = 'VNet is assigned, but is missing the Service Endpoint'
                            $DataTable.Rows.Add($NewRow)
                        }
                    }

                    if ($VNetIsInDifferentSubscription -eq $true)
                    {
                        # Set the working subscription back to where we started
                        $VNetIsInDifferentSubscription = $null
                        Select-AzureRmSubscription -Subscription $Subscription | Out-Null
                    }
                }
            }
        }
        else
        {
            Write-Warning "Storage Account $($StorageAccount.StorageAccountName) in Resource Group $($StorageAccount.ResourceGroupName) has no assigned VNets"
            # Add row of data to the CSV file
            $NewRow = $DataTable.NewRow()
            $NewRow.StorageAccountName = $($StorageAccount.StorageAccountName)
            $NewRow.StorageAccountSubscriptionName = $($Subscription.Name)
            $NewRow.StorageAccountResourceGroupName = $($StorageAccount.ResourceGroupName)
            $NewRow.VNetName = ''
            $NewRow.VNetResourceGroupName = ''
            $NewRow.SubnetName = ''
            $NewRow.VNetSubscriptionName = ''
            $NewRow.Notes = 'Storage Account has no assigned VNets'
            $DataTable.Rows.Add($NewRow)
        }
    }
}

$CSVFileName = 'StorageAccountWithNoServiceEndpoints' + $(Get-Date -f yyyy-MM-dd) + '.csv'
$DataTable | Export-Csv "$FileSaveLocation\$CSVFileName" -NoTypeInformation