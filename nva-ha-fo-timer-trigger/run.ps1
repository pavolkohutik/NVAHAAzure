Write-Output -InputObject "HA NVA timer trigger function executed at:$(Get-Date)"
<#     
    High Availability (HA) Network Virtual Appliance (NVA) Failover Function

    This script is an example for monitoring HA NVA firewall status and performing
    fail-over and/or fail-back.

    This script is used as part of an Azure Function App called by a Timer Trigger event.  
    
    To setup, the following items must be configured:

    - Pre-create Azure Resource Groups, Virtual Networks and Subnets, Network Virtual Appliances

    - Create Azure Timer Function 

    - Set Function App Settings with credentials
      SP_PASSWORD, SP_USERNAME, TENANTID, SUBSCRIPTIONID, AZURECLOUD must be added
      AZURECLOUD = "AzureCloud" or "AzureUSGovernment"

    - Set Firewall VM names and Resource Group in Function App Settings
      FW1NAME, FW2NAME, FWMONITOR, FW1FQDN, FW1PORT, FW2FQDN, FW2PORT, FWRGNAME, FWTRIES, FWDELAY, FWUDRTAG must be added
      FWMONITOR = "VMStatus" or "TCPPort" - If using "TCPPort", then also set FW1FQDN, FW2FQDN, FW1PORT and FW2PORT values

    - Set Timer Schedule where positions represent: Seconds - Minutes - Hours - Day - Month - DayofWeek
      Example:  "*/30 * * * * *" to run on multiples of 30 seconds
      Example:  "0 */5 * * * *" to run on multiples of 5 minutes on the 0-second mark
#>

#**************************************************************
#          Set firewall monitoring variables here
#**************************************************************

$VMFW1Name = $env:FW1NAME              # Set the Name of the primary NVA firewall
$VMFW2Name = $env:FW2NAME              # Set the Name of the secondary NVA firewall
$FW1RGName = $env:FWRGNAME             # Set the ResourceGroup that contains FW1
$FW2RGName = $env:FWRGNAME             # Set the ResourceGroup that contains FW2

<#
    Set the parameter $Monitor to  "VMStatus" if the current state 
    of the firewall is monitored.  The firewall will be marked as 
    down if function does not receive a "Running" response to the api call

    Set the parameter $Monitor to "TCPPort"  if the forwarding state
    of the firewall is to be tested by connecting through the firewall 
    to internal sites or applications
#>

$Monitor = $env:FWMONITOR              # "VMStatus" or "TCPPort" are valid values

#**************************************************************
#    The parameters below are required if using "TCPPort" mode
#**************************************************************

$TCPFW1Server = $env:FW1FQDN   # Hostname of the site to be monitored if using "TCPPort"
$TCPFW1Port = $env:FW1PORT
$TCPFW2Server = $env:FW2FQDN
$TCPFW2Port = $env:FW2PORT

#**************************************************************
# Set the failover and failback behavior for the firewalls
#**************************************************************

$FailOver = $True          # Trigger to enable fail-over to FW2 if FW1 drops when active
$FailBack = $True          # Trigger to enable fail-back to FW1 if FW2 drops when active

# FW is deemed down if ALL IntTries fail with IntSeconds between tries

$IntTries = $env:FWTRIES          # Number of Firewall tests to try 
$IntSleep = $env:FWDELAY          # Delay in seconds between tries

#**************************************************************
# Functions Code Block
#**************************************************************

Function Send-AlertMessage ($Message)
{
    $MailServers = (Resolve-DnsName -Type MX -Name $env:FWMAILDOMAINMX).NameExchange
    $MailFrom = $env:FWMAILFROM
    $MailTo = $env:FWMAILTO

    try { Send-MailMessage -SmtpServer $MailServers[1] -From $MailFrom -To $MailTo -Subject $Message -Body $Message }
    catch { Send-MailMessage -SmtpServer $MailServers[2] -From $MailFrom -To $MailTo -Subject $Mesage -Body $Message }
}

Function Test-VMStatus ($VM, $FWResourceGroup) 
{
  $VMDetail = Get-AzureRmVM -ResourceGroupName $FWResourceGroup -Name $VM -Status
  foreach ($VMStatus in $VMDetail.Statuses)
  { 
    $Status = $VMStatus.code
      
    if($Status.CompareTo('PowerState/running') -eq 0)
    {
      Return $False
    }
  }
  Return $True  
}

Function Test-TCPPort ($Server, $Port)
{
  $TCPClient = New-Object -TypeName system.Net.Sockets.TcpClient
  $Iar = $TCPClient.BeginConnect($Server, $Port, $Null, $Null)
  $Wait = $Iar.AsyncWaitHandle.WaitOne(1000, $False)
  return $Wait
}

Function Failover 
  {
  foreach ($SubscriptionID in $Script:ListOfSubscriptionIDs){
  Set-AzureRmContext -SubscriptionId $SubscriptionID
  $RTable = @()
  $TagValue = $env:FWUDRTAG
  $Res = Find-AzureRmResource -TagName nva_ha_udr -TagValue $TagValue

  foreach ($RTable in $Res)
    {
    $Table = Get-AzureRmRouteTable -ResourceGroupName $RTable.ResourceGroupName -Name $RTable.Name
    foreach ($RouteName in $Table.Routes){
      Write-Output -InputObject "Updating route table..."
      Write-Output -InputObject $RTable.Name

      for ($i = 0; $i -lt $PrimaryInts.count; $i++)
      {
        if($RouteName.NextHopIpAddress -eq $SecondaryInts[$i])
        {
          Write-Output -InputObject 'Secondary NVA is already ACTIVE' 
          
        }
        elseif($RouteName.NextHopIpAddress -eq $PrimaryInts[$i])
        {
          Set-AzureRmRouteConfig -Name $RouteName.Name  -NextHopType VirtualAppliance -RouteTable $Table -AddressPrefix $RouteName.AddressPrefix -NextHopIpAddress $SecondaryInts[$i] 
        }
      }
    }
  
    $UpdateTable = [scriptblock]{param($Table) Set-AzureRmRouteTable -RouteTable $Table}

    &$UpdateTable $Table

    }
  }

  Send-AlertMessage -message "NVA Alert: Failover to Secondary FW2"

}

Function Failback {
  foreach ($SubscriptionID in $Script:ListOfSubscriptionIDs){
  Set-AzureRmContext -SubscriptionId $SubscriptionID
  $TagValue = $env:FWUDRTAG
  $Res = Find-AzureRmResource -TagName nva_ha_udr -TagValue $TagValue

  foreach ($RTable in $Res)
  {
    $Table = Get-AzureRmRouteTable -ResourceGroupName $RTable.ResourceGroupName -Name $RTable.Name

    foreach ($RouteName in $Table.Routes)
    {
      Write-Output -InputObject "Updating route table..."
      Write-Output -InputObject $RTable.Name
      for ($i = 0; $i -lt $PrimaryInts.count; $i++)
      {
        if($RouteName.NextHopIpAddress -eq $PrimaryInts[$i])
        {
          Write-Output -InputObject 'Primary NVA is already ACTIVE' 
        
        }
        elseif($RouteName.NextHopIpAddress -eq $SecondaryInts[$i])
        {
          Set-AzureRmRouteConfig -Name $RouteName.Name  -NextHopType VirtualAppliance -RouteTable $Table -AddressPrefix $RouteName.AddressPrefix -NextHopIpAddress $PrimaryInts[$i]
        }  
      }  
    }  

    $UpdateTable = [scriptblock]{param($Table) Set-AzureRmRouteTable -RouteTable $Table}

    &$UpdateTable $Table 
    }
  }

  Send-AlertMessage -message "NVA Alert: Failback to Primary FW1"

}

Function Get-FWInterfaces
{
  $Nics = Get-AzureRmNetworkInterface | Where-Object -Property VirtualMachine -NE -Value $Null
  $VMS1 = Get-AzureRmVM -Name $VMFW1Name -ResourceGroupName $FW1RGName
  $VMS2 = Get-AzureRmVM -Name $VMFW2Name -ResourceGroupName $FW2RGName

  foreach($Nic in $Nics)
  {
    if (($Nic.VirtualMachine.Id -EQ $VMS1.Id) -Or ($Nic.VirtualMachine.Id -EQ $VMS2.Id)) 
    {
      $VM = $VMS | Where-Object -Property Id -EQ -Value $Nic.VirtualMachine.Id
      $Prv = $Nic.IpConfigurations | Select-Object -ExpandProperty PrivateIpAddress  
      if ($VM.Name -eq $VMFW1Name)
      {
        $Script:PrimaryInts += $Prv
      }
      elseif($VM.Name -eq $vmFW2Name)
      {
        $Script:SecondaryInts += $Prv
      }
    }
  }
}

Function Get-Subscriptions {
  Write-Output -InputObject "Enumerating all subscriptins ..."
  $Script:ListOfSubscriptionIDs = (Get-AzureRmSubscription).SubscriptionId
  Write-Output -InputObject $Script:ListOfSubscriptionIDs
}

#**************************************************************
# Main Code Block                            
#**************************************************************
# Set Service Principal Credentials and establish your Azure RM Context
# SP_PASSWORD, SP_USERNAME, TENANTID, SUBSCRIPTIONID and AZURECLOUD are app settings

$Password = ConvertTo-SecureString $env:SP_PASSWORD -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($env:SP_USERNAME, $Password)
$AzureEnv = Get-AzureRmEnvironment -Name $env:AZURECLOUD
Add-AzureRmAccount -ServicePrincipal -Tenant $env:TENANTID -Credential $Credential -SubscriptionId $env:SUBSCRIPTIONID -Environment $AzureEnv

$Context = Get-AzureRmContext
Set-AzureRmContext -Context $Context

$Script:PrimaryInts = @()
$Script:SecondaryInts = @()
$Script:ListOfSubscriptionIDs = @()

# Check firewall status $intTries with $intSleep between tries

$CtrFW1 = 0
$CtrFW2 = 0
$FW1Down = $True
$FW2Down = $True

$VMS = Get-AzureRmVM

Get-Subscriptions
Get-FWInterfaces

For ($Ctr = 1; $Ctr -le $IntTries; $Ctr++)
{
  # Test FW States based on VMStatus (if specified)
  if ($Monitor -eq 'VMStatus')
  {
    $FW1Down = Test-VM-Status -VM $VMFW1Name -FwResourceGroup $FW1RGName
    $FW2Down = Test-VM-Status -VM $VMFW2Name -FwResourceGroup $FW2RGName
  }
  # Test FW States based on TCPPort checks (if specified)
  if ($Monitor -eq 'TCPPort')
  {
    $FW1Down = -not (Test-TCP-Port -server $TCPFW1Server -port $TCPFW1Port)
    $FW2Down = -not (Test-TCP-Port -server $TCPFW2Server -port $TCPFW2Port)
  }
  Write-Output -InputObject "Pass $Ctr of $IntTries - FW1Down is $FW1Down, FW2Down is $FW2Down"

  if ($FW1Down) 
  {
    $CtrFW1++
  }
  if ($FW2Down) 
  {
    $CtrFW2++
  }

  Write-Output -InputObject "Sleeping $IntSleep seconds"

  Start-Sleep $IntSleep
}

# Reset individual test status and determine overall firewall status

$FW1Down = $False
$FW2Down = $False

if ($CtrFW1 -eq $intTries) 
{
  $FW1Down = $True
}
if ($CtrFW2 -eq $intTries) 
{
  $FW2Down = $True
}

# Fail-over logic tree

if (($FW1Down) -and -not ($FW2Down))
{
  if ($FailOver)
  {
    Write-Output -InputObject 'FW1 Down - Failing over to FW2'
    Failover 
  }
}
elseif (-not ($FW1Down) -and ($FW2Down))
{
  if ($FailBack)
  {
    Write-Output -InputObject 'FW2 Down - Failing back to FW1'
    Failback
  }
  else 
  {
    Write-Output -InputObject 'FW2 Down - Failing back disabled'
  }
}
elseif (($FW1Down) -and ($FW2Down))
{
  Write-Output -InputObject 'Both FW1 and FW2 Down - Manual recovery action required'
  Send-AlertMessage -message "NVA Alert: Both FW1 and FW2 Down - Manual recovery action is required"
}
else
{
  Write-Output -InputObject 'Both FW1 and FW2 Up - No action is required'
}
