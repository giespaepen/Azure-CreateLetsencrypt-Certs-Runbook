[OutputType([string])]

param(
    [Parameter()]
    [String] $KeyVault = "name-of-thekeyvault",

    [Parameter()]
    [String] $ResourceGroup = "resource-group",

    [Parameter()]
    [String] $ContactEmail = "contact-email",

    [Parameter()]
    [Boolean] $IsRunbook = $True
)

#region Imports

# Make sure that this modules are present in the runbook environment. Go to
# Modules galery in the automations account and import the following modules:

Import-Module "Az.KeyVault";
Import-Module "Az.Dns";
Import-Module 'ACME-PS';

#endregion

#region Logging

function Log-Message {
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [String] $LogMessage,

        [Parameter()]
        [String] $Prefix = "general",

        [Parameter()]
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [String] $Level = "INFO"
    )

    $Message = "$(Get-Date) $Level [$Prefix] $LogMessage";

    # Write default to output
    Write-Output $Message;

    # Write errors to error stream
    if ($Level -eq "ERROR") {
        Write-Error $Message;
    }
}

function Log-Title {
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [String] $LogMessage
    )

    Log-Message $LogMessage
}

# endregion

#region Login

# Check if the context is a runbook, set by the following flag. If so, try to login using the
# AzureRunAsConnection. Script taken from: https://docs.microsoft.com/en-us/azure/automation/learn/automation-tutorial-runbook-textual-powershell
if ($IsRunbook) {
    # Ensures you do not inherit an AzContext in your runbook
    Disable-AzContextAutosave –Scope Process

    $Connection = Get-AutomationConnection -Name AzureRunAsConnection

    # Wrap authentication in retry logic for transient network failures
    $LogonAttempt = 0
    while (!($ConnectionResult) -And ($LogonAttempt -le 10)) {
        $LogonAttempt++
        # Logging in to Azure...
        $ConnectionResult = Connect-AzAccount `
            -ServicePrincipal `
            -Tenant $Connection.TenantID `
            -ApplicationId $Connection.ApplicationID `
            -CertificateThumbprint $Connection.CertificateThumbprint

        Start-Sleep -Seconds 30
    }

    Log-Message "Logged in to AzureRunAsConnection"
}

#endregion

#region Main program

Log-Title "ACME Renew Runbook Script"

# Temp dir
$AcmeTempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "acme";
Log-Message "Using temp dir $AcmeTempDir"
$AcmeService = "LetsEncrypt";

# Find all the A DNS records within a subscription
Log-Message "Finding A DNS records in this subscription"
$Records = Get-AzDnsZone | ForEach-Object { 
    Get-AzDnsRecordSet -ZoneName $_.Name -ResourceGroupName $_.ResourceGroupName
} | Where-Object { $_.RecordType -eq "A" }

Log-Message "Found $($Records.length) DNS record(s)"
$Records | Foreach-Object -Process {
    Log-Message "$($_.ZoneName) - $($_.Name)"
}

# Prepare ACME account to negotiate the certificates
try {
    Log-Message "Preparing ACME account" -Prefix "acme-account"
    if (!(Test-Path (Join-Path -Path $AcmeTempDir -ChildPath "Account.xml") -PathType leaf)) {
        # Remove-Item $AcmeTempDir -Force -Recurse;
        New-ACMEState -Path $AcmeTempDir;
        Get-ACMEServiceDirectory -State $AcmeTempDir -ServiceName $AcmeService;
        New-ACMENonce -State $AcmeTempDir;
        New-ACMEAccountKey -State $AcmeTempDir -PassThru;
        New-ACMEAccount -State $AcmeTempDir -EmailAddresses $ContactEmail -AcceptTOS;
    }
    else {
        Log-Message "Account exists" -Prefix "acme-account"
    }
}
catch {
    Log-Message "An error occured while creating the ACME account." -Level "WARN" -Prefix "acme-account"
    Log-Message $_ -Level "WARN" -Prefix "acme-account"
}
finally {
    Log-Message "ACME account created" -Prefix "acme-account";
}

# Process all the A DNS records
$Records | ForEach-Object -Process {
    # Get the full domain name
    $Domain = "$($_.Name).$($_.ZoneName)"

    # Get the first part of the full domain name as the subdomain
    $SubDomain = $_.Name.Split(".")[0];

    # Set some local vars for handling and storing the certificate
    $CertificatePassword = ConvertTo-SecureString $_.ZoneName -AsPlainText -Force
    $CertificateExportPath = Join-Path -Path $AcmeTempDir -ChildPath "$($SubDomain).pfx"

    Log-Message "Processing subdomain" -Prefix $SubDomain;

    # Try to get the certificate
    $Certificate = Get-AzKeyVaultCertificate -VaultName $KeyVault -Name $SubDomain;
    
    # Get information on the certificate if it exists;
    # check its expiry and return if it is still fresh enough
    if ($Certificate) {
        $Expires = $Certificate.Expires;
        $ExpiresSpan = New-TimeSpan -Start (Get-Date) -End $Expires;

        Log-Message "Certificate expiring: $Expires" -Prefix $SubDomain
        if ($ExpiresSpan.Days -gt 10) {
            Log-Message "Certificate will not expire next week. Skipping this one." -Prefix $SubDomain;
            return;
        }
    }

    # If not returned, start first to create an ACME order
    $DnsIdentifier = New-ACMEIdentifier $Domain;
    $Order = New-ACMEOrder -State $AcmeTempDir -Identifiers $DnsIdentifier;
    Log-Message "Created order $($Order.ResourceUrl)"

    # When the order is created we can get the authorization and try to fullfil the challenges
    try {
        # Fetch authorization and create a DNS challenge (dns-01)
        $Authorization = Get-ACMEAuthorization -State $AcmeTempDir -Order $Order;
        $Challenge = Get-ACMEChallenge -State $AcmeTempDir -Authorization $Authorization -Type "dns-01"

        # Get the record name and content
        $DnsTxtRecordName = $Challenge.Data.TxtRecordName -replace ".$($_.ZoneName)", "";
        $DnsTxtValue = $Challenge.Data.Content;

        # Create a challenge TXT record
        Log-Message "Creating DNS record $DnsTxtRecordName"
        New-AzDnsRecordSet -Name $DnsTxtRecordName -RecordType TXT -ZoneName $_.ZoneName -TTL 3600 -ResourceGroupName $_.ResourceGroupName -DnsRecords @(New-AzDnsRecordConfig -Value $DnsTxtValue)

        # Complete the order, ACME will check for the DNS TXT record
        Log-Message "Completing ACME order" -Prefix $SubDomain;
        $Challenge | Complete-ACMEChallenge -State $AcmeTempDir;

        # Wait for the order to update
        Log-Message "Waiting for the order to complete" -Prefix $SubDomain
        while ($Order.Status -notin ("ready", "invalid")) {
            Start-Sleep -Seconds 5;
            $Order | Update-ACMEOrder -State $AcmeTempDir -PassThru;
        }

        # If the order seems to be invalid, loop over it and go to the catch block
        if ($Order.Status -eq "invalid") {
            $InvalidMessage = "Your order has been marked as invalid - certificate cannot be issued."
            Log-Message $InvalidMessage -Prefix $SubDomain -Level "ERROR";
            throw $InvalidMessage;
        }

        # Complete the order - this will issue a certificate singing request
        Complete-ACMEOrder -State $AcmeTempDir -Order $Order -GenerateCertificateKey;

        # Now we wait until the ACME service provides the certificate url
        Log-Message "Waiting for the Certificate URL"
        while (-not $Order.CertificateUrl) {
            Start-Sleep -Seconds 15
            $Order | Update-ACMEOrder -State $AcmeTempDir -PassThru
        }

        # Create a password for the certificate and export it
        Log-Message "Exporting certificate to $CertificateExportPath" -Prefix $SubDomain;
        Export-ACMECertificate -State $AcmeTempDir `
            -Order $Order `
            -Path $CertificateExportPath `
            -Password $CertificatePassword

        # Importing the certificate
        Log-Message "Importing certificate to $KeyVault" -Prefix $SubDomain;
        Import-AzKeyVaultCertificate -VaultName $KeyVault -Name $SubDomain -FilePath $CertificateExportPath -Password $CertificatePassword

        Log-Message "Done" -Prefix $SubDomain;
    }
    catch {
        Log-Message "Processing of $SubDomain failed" -Level "WARN" -Prefix $SubDomain;
        Log-Message $_ -Level "WARN" -Prefix $SubDomain;
    }
    finally {
        # Cleanup the DNS record
        Remove-AzDnsRecordSet -Name $DnsTxtRecordName -RecordType TXT -ZoneName $_.ZoneName -ResourceGroupName $_.ResourceGroupName
    }
};

#endregion
