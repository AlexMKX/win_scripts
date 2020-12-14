#syncs dhcp reservations to DNS in windows and updates hostnames in Unifi controller
# config.js example
#{
#"scope":"192.168.0.0",
#"zone":"your.domain.com",
#"reversezone":"0.168.192.in-addr.arpa",
#"uUsername":"unifi_account",
#"uPassword":"unifi_password",
#"uSiteID":"default",
#"uController":"https://unifi.host.name:8443"
#}
#if there is a 12 option for DHCP - it will use it as a dns hostname
#$scope = "192.168.0.0"
#$zone = "your.domain.com"
#$reversezone = "0.168.192.in-addr.arpa"
param (
    [Parameter(Mandatory=$true)] $config

)
$log = $Env:Temp +"\pslogs\dhcp-sync.log"
Start-TranScript -path $log -append

$script:conf=Get-Content $config | ConvertFrom-Json

$ErrorActionPreference='Stop'


$script:uAuthBody = @{"username" = $script:conf.uUsername; "password" = $script:conf.uPassword }
$script:uHeaders = @{"Content-Type" = "application/json" }

# Allow connection with the Unifi Self Signed Cert
# add-type @"
#using System.Net;
#using System.Security.Cryptography.X509Certificates;
#public class TrustAllCertsPolicy : ICertificatePolicy {
#    public bool CheckValidationResult(
#        ServicePoint srvPoint, X509Certificate certificate,
#        WebRequest request, int certificateProblem) {
#        return true;
#    }
#}
#"@ 
#[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3, [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12


function CheckUnifiDevice(){
    Param ($dhcp_mac,$name)
    $script:uLogin = Invoke-RestMethod -Method Post -Uri "$($script:conf.uController)/api/login" -Body ($script:uAuthBody | convertto-json) -Headers $script:uHeaders -SessionVariable UBNT
    $mac=$dhcp_mac -replace '-', ':'
    try {
        $dev_info = Invoke-RestMethod -Method Get -Uri "$($script:conf.uController)/api/s/$($script:conf.uSiteID)/stat/user/$($mac)" -WebSession $UBNT -Headers $script:uHeaders -ErrorAction SilentlyContinue
    }
    catch { return }
    if ($null -ne $dev_info.data.name)
    {
        if ($name -ne $dev_info.data.name)
        {
            $body = @{
            "name"=$name
             } | ConvertTo-Json
             Write-Output "Changing $($dev_info.data.name) to $($name)"
            $url = "$($script:conf.uController)/api/s/$($script:conf.uSiteID)/rest/user/$($dev_info.data._id)"
            Write-Output $url
            Write-Output $body
            $res = Invoke-RestMethod -Method Put -Uri $url -WebSession $UBNT -Headers $script:uHeaders -Body $body
        }
        return
    }
    if ($null -ne $dev_info.data.hostname)
    {
        if ($name -ne $dev_info.data.hostname)
        {
            $body = @{
            "name"=$name
             } | ConvertTo-Json
             Write-Output "Changing $($dev_info.data.hostname) to $($name)"
            $res = Invoke-RestMethod -Method Put -Uri "$($script:conf.uController)/api/s/$($script:conf.uSiteID)/rest/user/$($dev_info.data.user_id)" -WebSession $UBNT -Headers $script:uHeaders -Body $body
        }
    }
}
function AddDnsEntry {
    Param (
        $zone, $hostname, $ip
   )
    $old_host = Get-DnsServerResourceRecord -ZoneName $zone -RRType "A" | Where-Object {$_.HostName -eq $hostname} -ErrorAction Ignore
    if ($null -ne $old_host){
        if ($old_host.RecordData.IPv4Address.IPAddressToString -ne $ip)
        {
            Write-Host "Removing old record for " $hostname 
            $old_host | Out-Default
            Remove-DnsServerResourceRecord -RRType "A" -Name $hostname -ZoneName $zone -Confirm:$false -Force
            Write-Host "Adding new dns-record for " $hostname $ip
            Add-DnsServerResourceRecordA -AgeRecord -Name $hostname -ZoneName $zone -IPv4Address $ip
        }
    }
    else {
        Write-Host "Adding new dns-record for " $hostname $ip 
        Add-DnsServerResourceRecordA -AgeRecord -Name $hostname -ZoneName $zone -IPv4Address $ip
    }
}

function CheckRR {
  Param ($hostname, $ip,$RRZone)
  $rHost = $ip.Split('.')[3]
  #check by ip
  $rrRec = Get-DnsServerResourceRecord -ZoneName $RRZone -Name $rHost -ErrorAction Ignore
  $AddNew=$false
  if ($null -ne $rrRec)
  {
    if ($rrRec.RecordData.PtrDomainName -ne $hostname)
    {
        Write-Host $rrRec.RecordData.PtrDomainName not match $rrRec.HostName for $hostname deleting the old one   
        Remove-DnsServerResourceRecord -RRType "PTR" -Name $rHost -ZoneName $RRZone -Confirm:$false -Force
        $Addnew = $true
    }
  }
  else {
    $AddNew = $true
  }
  #check by hostname 
  $rRec = Get-DnsServerResourceRecord -ZoneName $RRZone | Where-Object {$_.RecordData.PtrDomainName -eq $hostname}
  if ($null -ne $rrRec)
  {
    if ($rrRec.HostName -ne $rHost)
    {
        Write-Host not match $rrRec.RecordData.PtrDomainName $rrRec.HostName for $hostname deleting old one
        Remove-DnsServerResourceRecord -RRType "PTR" -Name $rrRec.HostName -ZoneName $RRZone -Confirm:$false -Force
        $AddNew = $true
    }
  }
  if ($AddNew){
      Write-Host Adding new record
      Add-DnsServerResourceRecordPtr -AgeRecord -Name $rHost -ZoneName $RRZone -PtrDomainName $hostname
  }
}
function CheckReservation {
  Param ($reservation, $zone,$reversezone)
  $altfqdn=Get-DhcpServerv4OptionValue -ErrorAction Ignore -ReservedIP $reservation.IPAddress -OptionId 12
  if ($null -ne $altfqdn)
  {
    $hostname= @($altfqdn.Value.Split('.'))[0]
    if ($altfqdn -ne $reservation.Name)
    {
        $new_hostname= [System.String] $altfqdn.Value
        Set-DhcpServerv4Reservation -IPAddress $reservation.IPAddress -Name $new_hostname
    }
  }
  else {
    $hostname = @($reservation.Name.Split('.'))[0]
  }
  AddDnsEntry -zone $zone -hostname $hostname -ip $reservation.IPAddress
  CheckRR -hostname "$hostname.$zone." -ip $reservation.IPAddress.IPAddressToString -RRZone $reversezone
  CheckUnifiDevice -dhcp_mac $reservation.ClientId -name $hostname
}


$dhcp_reservations = @(Get-DhcpServerv4Reservation -ScopeId $script:conf.scope)
$dhcp_reservations | ForEach-Object {
   CheckReservation -reservation $_ -zone $script:conf.zone -reversezone $script:conf.reversezone
}

Stop-TranScript
