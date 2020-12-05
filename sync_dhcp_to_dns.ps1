#syncs dhcp reservations to DNS in windows
#if there is a 12 option for DHCP - it will use it as a dns hostname
#$scope = "192.168.0.0"
#$zone = "your.domain.com"
#$reversezone = "0.168.192.in-addr.arpa"
param (
    [Parameter(Mandatory=$true)] $scope, [Parameter(Mandatory=$true)] $zone, [Parameter(Mandatory=$true)] $reversezone
    )

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
}



$log = $Env:Temp +"\pslogs\dhcp-sync.log"
Start-Transcript -path $log -append
$dhcp_reservations = @(Get-DhcpServerv4Reservation -ScopeId $scope)
$dhcp_reservations | ForEach-Object {
   CheckReservation -reservation $_ -zone $zone -reversezone $reversezone
}

Stop-Transcript
