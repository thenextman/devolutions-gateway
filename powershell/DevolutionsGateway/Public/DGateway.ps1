
. "$PSScriptRoot/../Private/CertificateHelper.ps1"
. "$PSScriptRoot/../Private/PlatformHelper.ps1"
. "$PSScriptRoot/../Private/TokenHelper.ps1"

$script:DGatewayConfigFileName = 'gateway.json'
$script:DGatewayCertificateFileName = 'server.crt'
$script:DGatewayPrivateKeyFileName = 'server.key'
$script:DGatewayProvisionerPublicKeyFileName = 'provisioner.pem'
$script:DGatewayProvisionerPrivateKeyFileName = 'provisioner.key'
$script:DGatewayDelegationPublicKeyFileName = 'delegation.pem'
$script:DGatewayDelegationPrivateKeyFileName = 'delegation.key'

function Get-DGatewayVersion {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('PSModule', 'Installed')]
        [string] $Type
    )

    if ($Type -eq 'PSModule') {
        $ManifestPath = "$PSScriptRoot/../DevolutionsGateway.psd1"
        $Manifest = Import-PowerShellDataFile -Path $ManifestPath
        $DGatewayVersion = $Manifest.ModuleVersion
    } elseif ($Type -eq 'Installed') {
        if ($IsWindows) {
            $UninstallReg = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' `
            | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_ -Match 'Devolutions Gateway' }
            if ($UninstallReg) {
                $DGatewayVersion = '20' + $UninstallReg.DisplayVersion
            }
        } elseif ($IsMacOS) {
            throw 'not supported'
        } elseif ($IsLinux) {
            $PackageName = 'devolutions-gateway'
            $DpkgStatus = $(dpkg -s $PackageName 2>$null)
            $DpkgMatches = $($DpkgStatus | Select-String -AllMatches -Pattern 'version: (\S+)').Matches
            if ($DpkgMatches) {
                $VersionQuad = $DpkgMatches.Groups[1].Value
                $VersionTriple = $VersionQuad -Replace '^(\d+)\.(\d+)\.(\d+)\.(\d+)$', "`$1.`$2.`$3"
                $DGatewayVersion = $VersionTriple
            }
        }
    }

    $DGatewayVersion
}

class DGatewayListener {
    [string] $InternalUrl
    [string] $ExternalUrl

    DGatewayListener() { }

    DGatewayListener([string] $InternalUrl, [string] $ExternalUrl) {
        $this.InternalUrl = $InternalUrl
        $this.ExternalUrl = $ExternalUrl
    }
}

function New-DGatewayListener() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $ListenerUrl,
        [Parameter(Mandatory = $true, Position = 1)]
        [string] $ExternalUrl
    )

    return [DGatewayListener]::new($ListenerUrl, $ExternalUrl)
}

class DGatewaySubProvisionerKey {
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Id

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Value

    [ValidateNotNullOrEmpty()]
    [ValidateSet('Spki','Rsa')]
    [string] $Format

    [ValidateNotNullOrEmpty()]
    [ValidateSet('Multibase','Base64', 'Base64Pad', 'Base64Url', 'Base64UrlPad')]
    [string] $Encoding

    DGatewaySubProvisionerKey(
        [string] $Id,
        [string] $Value,
        [string] $Format = 'Spki',
        [string] $Encoding = 'Multibase'
    ) {
        $this.Id = $Id
        $this.Value = $Value
        $this.Format = $Format
        $this.Encoding = $Encoding
    }

    DGatewaySubProvisionerKey([PSCustomObject] $object) {
        $this.Id = $object.Id
        $this.Value = $object.Value
        $this.Format = $object.Format
        $this.Encoding = $object.Encoding
    }

    DGatewaySubProvisionerKey([Hashtable] $table) {
        $this.Id = $table.Id
        $this.Value = $table.Value
        $this.Format = $table.Format
        $this.Encoding = $table.Encoding
    }
}

class DGatewaySubscriber {
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.Uri] $Url

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Token

    DGatewaySubscriber(
        [System.Uri] $Url,
        [string] $Token
    ) {
        $this.Url = $Url
        $this.Token = $Token
    }

    DGatewaySubscriber([PSCustomObject] $object) {
        $this.Url = $object.Url
        $this.Token = $object.Token
    }

    DGatewaySubscriber([Hashtable] $table) {
        $this.Url = $table.Url
        $this.Token = $table.Token
    }
}

class DGatewayConfig {
    [System.Nullable[Guid]] $Id
    [string] $Hostname

    [string] $RecordingPath

    [string] $TlsCertificateFile
    [string] $TlsPrivateKeyFile
    [string] $ProvisionerPublicKeyFile
    [string] $ProvisionerPrivateKeyFile
    [string] $DelegationPublicKeyFile
    [string] $DelegationPrivateKeyFile
    [DGatewaySubProvisionerKey] $SubProvisionerPublicKey

    [DGatewayListener[]] $Listeners
    [DGatewaySubscriber] $Subscriber

    [string] $LogDirective
}

function Save-DGatewayConfig {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory = $true)]
        [DGatewayConfig] $Config
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $ConfigFile = Join-Path $ConfigPath $DGatewayConfigFileName

    $Properties = $Config.PSObject.Properties.Name
    $NonNullProperties = $Properties.Where( { -Not [string]::IsNullOrEmpty($Config.$_) })
    $ConfigData = $Config | Select-Object $NonNullProperties | ConvertTo-Json

    [System.IO.File]::WriteAllLines($ConfigFile, $ConfigData, $(New-Object System.Text.UTF8Encoding $False))
}

function Set-DGatewayConfig {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $Force,

        [Guid] $Id,
        [string] $Hostname,

        [string] $RecordingPath,

        [DGatewayListener[]] $Listeners,
        [DGatewaySubscriber] $Subscriber,

        [string] $TlsCertificateFile,
        [string] $TlsPrivateKeyFile,

        [string] $ProvisionerPublicKeyFile,
        [string] $ProvisionerPrivateKeyFile,

        [string] $DelegationPublicKeyFile,
        [string] $DelegationPrivateKeyFile,

        [DGatewaySubProvisionerKey] $SubProvisionerPublicKey
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath

    if (-Not (Test-Path -Path $ConfigPath -PathType 'Container')) {
        New-Item -Path $ConfigPath -ItemType 'Directory'
    }

    $ConfigFile = Join-Path $ConfigPath $DGatewayConfigFileName

    if (-Not (Test-Path -Path $ConfigFile -PathType 'Leaf')) {
        $config = [DGatewayConfig]::new()
    } else {
        $config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    }

    $properties = [DGatewayConfig].GetProperties() | ForEach-Object { $_.Name }
    foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($properties -Contains $param.Key) {
            $config.($param.Key) = $param.Value
        }
    }

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Get-DGatewayConfig {
    [CmdletBinding()]
    [OutputType('DGatewayConfig')]
    param(
        [string] $ConfigPath,
        [switch] $NullProperties,
        [switch] $Expand
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath

    $ConfigFile = Join-Path $ConfigPath $DGatewayConfigFileName

    $config = [DGatewayConfig]::new()

    if (-Not (Test-Path -Path $ConfigFile -PathType 'Leaf')) {
        if ($NullProperties) {
            return $config
        }
    }

    $ConfigData = Get-Content -Path $ConfigFile -Encoding UTF8
    $json = $ConfigData | ConvertFrom-Json

    [DGatewayConfig].GetProperties() | ForEach-Object {
        $Name = $_.Name
        if ($json.PSObject.Properties[$Name]) {
            $Property = $json.PSObject.Properties[$Name]
            $Value = $Property.Value
            $config.$Name = $Value
        }
    }

    if ($Expand) {
        Expand-DGatewayConfig $config
    }

    if (-Not $NullProperties) {
        $Properties = $Config.PSObject.Properties.Name
        $NonNullProperties = $Properties.Where( { -Not [string]::IsNullOrEmpty($Config.$_) })
        $Config = $Config | Select-Object $NonNullProperties
    }

    return $config
}

function Expand-DGatewayConfig {
    param(
        [DGatewayConfig] $Config
    )
}

function Find-DGatewayConfig {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    if (-Not $ConfigPath) {
        $CurrentPath = Get-Location
        $ConfigFile = Join-Path $CurrentPath $DGatewayConfigFileName

        if (Test-Path -Path $ConfigFile -PathType 'Leaf') {
            $ConfigPath = $CurrentPath
        }
    }

    if (-Not $ConfigPath) {
        $ConfigPath = Get-DGatewayPath
    }

    if ($Env:DGATEWAY_CONFIG_PATH) {
        $ConfigPath = $Env:DGATEWAY_CONFIG_PATH
    }

    return $ConfigPath
}

function Enter-DGatewayConfig {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [switch] $ChangeDirectory
    )

    if ($ConfigPath) {
        $ConfigPath = Resolve-Path $ConfigPath
        $Env:DGATEWAY_CONFIG_PATH = $ConfigPath
    }

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath

    if ($ChangeDirectory) {
        Set-Location $ConfigPath
    }
}

function Exit-DGatewayConfig {
    Remove-Item Env:DGATEWAY_CONFIG_PATH
}

function Get-DGatewayPath() {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('ConfigPath')]
        [string] $PathType = 'ConfigPath'
    )

    $DisplayName = 'Gateway'
    $CompanyName = 'Devolutions'

    if ($IsWindows) {
        $ConfigPath = $Env:ProgramData + "\${CompanyName}\${DisplayName}"
    } elseif ($IsMacOS) {
        $ConfigPath = "/Library/Application Support/${CompanyName} ${DisplayName}"
    } elseif ($IsLinux) {
        $ConfigPath = '/etc/devolutions-gateway'
    }

    switch ($PathType) {
        'ConfigPath' { $ConfigPath }
        default { throw("Invalid path type: $PathType") }
    }
}

function Get-DGatewayRecordingPath {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    $RecordingPath = $Config.RecordingPath

    if ([string]::IsNullOrEmpty($RecordingPath)) {
        $RecordingPath = Join-Path $ConfigPath "recordings"
    }

    $RecordingPath
}

function Set-DGatewayRecordingPath {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $RecordingPath
    )

    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.RecordingPath = $RecordingPath
    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Reset-DGatewayRecordingPath {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.RecordingPath = $null
    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Get-DGatewayHostname {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $(Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties).Hostname
}

function Set-DGatewayHostname {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Hostname
    )

    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.Hostname = $Hostname
    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Get-DGatewayListeners {
    [CmdletBinding()]
    [OutputType('DGatewayListener[]')]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.Listeners
}

function Set-DGatewayListeners {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [DGatewayListener[]] $Listeners
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties
    $Config.Listeners = $Listeners
    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Import-DGatewayCertificate {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $CertificateFile,
        [string] $PrivateKeyFile,
        [string] $Password
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    $result = Get-PemCertificate -CertificateFile:$CertificateFile `
        -PrivateKeyFile:$PrivateKeyFile -Password:$Password
        
    $CertificateData = $result.Certificate
    $PrivateKeyData = $result.PrivateKey

    New-Item -Path $ConfigPath -ItemType 'Directory' -Force | Out-Null

    $CertificateFile = Join-Path $ConfigPath $DGatewayCertificateFileName
    $PrivateKeyFile = Join-Path $ConfigPath $DGatewayPrivateKeyFileName

    Set-Content -Path $CertificateFile -Value $CertificateData -Force
    Set-Content -Path $PrivateKeyFile -Value $PrivateKeyData -Force

    $Config.TlsCertificateFile = $DGatewayCertificateFileName
    $Config.TlsPrivateKeyFile = $DGatewayPrivateKeyFileName

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function New-DGatewayProvisionerKeyPair {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [int] $KeySize = 2048,
        [switch] $Force
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    if (-Not (Test-Path -Path $ConfigPath)) {
        New-Item -Path $ConfigPath -ItemType 'Directory' -Force | Out-Null
    }

    $PublicKeyFile = Join-Path $ConfigPath $DGatewayProvisionerPublicKeyFileName
    $PrivateKeyFile = Join-Path $ConfigPath $DGatewayProvisionerPrivateKeyFileName

    if ((Test-Path -Path $PublicKeyFile) -Or (Test-Path -Path $PrivateKeyFile)) {
        if (-Not $Force) {
            throw "$PublicKeyFile or $PrivateKeyFile already exists, use -Force to overwrite"
        }

        Remove-Item $PublicKeyFile -Force | Out-Null
        Remove-Item $PrivateKeyFile -Force | Out-Null
    }

    $KeyPair = New-RsaKeyPair -KeySize:$KeySize

    $PublicKeyData = $KeyPair.PublicKey
    $Config.ProvisionerPublicKeyFile = $DGatewayProvisionerPublicKeyFileName
    Set-Content -Path $PublicKeyFile -Value $PublicKeyData -Force

    $PrivateKeyData = $KeyPair.PrivateKey
    $Config.ProvisionerPrivateKeyFile = $DGatewayProvisionerPrivateKeyFileName
    Set-Content -Path $PrivateKeyFile -Value $PrivateKeyData -Force

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Import-DGatewayProvisionerKey {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $PublicKeyFile,
        [string] $PrivateKeyFile
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    if ($PublicKeyFile) {
        if (-Not (Test-Path -Path $PublicKeyFile)) {
            throw "$PublicKeyFile doesn't exist"
        }

        $PublicKeyData = Get-Content -Path $PublicKeyFile -Encoding UTF8

        if (!$PublicKeyData) {
            throw "$PublicKeyFile appears to be empty"          
        }

        $OutputFile = Join-Path $ConfigPath $DGatewayProvisionerPublicKeyFileName
        $Config.ProvisionerPublicKeyFile = $DGatewayProvisionerPublicKeyFileName
        New-Item -Path $ConfigPath -ItemType 'Directory' -Force | Out-Null
        Set-Content -Path $OutputFile -Value $PublicKeyData -Force
    }

    if ($PrivateKeyFile) {
        if (-Not (Test-Path -Path $PrivateKeyFile)) {
            throw "$PrivateKeyFile doesn't exist"
        }

        $PrivateKeyData = Get-Content -Path $PrivateKeyFile -Encoding UTF8

        if (!$PrivateKeyData) {
            throw "$PrivateKeyFile appears to be empty"          
        }

        $OutputFile = Join-Path $ConfigPath $DGatewayProvisionerPrivateKeyFileName
        $Config.ProvisionerPrivateKeyFile = $DGatewayProvisionerPrivateKeyFileName
        New-Item -Path $ConfigPath -ItemType 'Directory' -Force | Out-Null
        Set-Content -Path $OutputFile -Value $PrivateKeyData -Force
    }

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function New-DGatewayDelegationKeyPair {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [int] $KeySize = 2048,
        [switch] $Force
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    if (-Not (Test-Path -Path $ConfigPath)) {
        New-Item -Path $ConfigPath -ItemType 'Directory' -Force | Out-Null
    }

    $PublicKeyFile = Join-Path $ConfigPath $DGatewayDelegationPublicKeyFileName
    $PrivateKeyFile = Join-Path $ConfigPath $DGatewayDelegationPrivateKeyFileName

    if ((Test-Path -Path $PublicKeyFile) -Or (Test-Path -Path $PrivateKeyFile)) {
        if (-Not $Force) {
            throw "$PublicKeyFile or $PrivateKeyFile already exists, use -Force to overwrite"
        }

        Remove-Item $PublicKeyFile -Force | Out-Null
        Remove-Item $PrivateKeyFile -Force | Out-Null
    }

    $KeyPair = New-RsaKeyPair -KeySize:$KeySize

    $PublicKeyData = $KeyPair.PublicKey
    $Config.DelegationPublicKeyFile = $DGatewayDelegationPublicKeyFileName
    Set-Content -Path $PublicKeyFile -Value $PublicKeyData -Force

    $PrivateKeyData = $KeyPair.PrivateKey
    $Config.DelegationPrivateKeyFile = $DGatewayDelegationPrivateKeyFileName
    Set-Content -Path $PrivateKeyFile -Value $PrivateKeyData -Force

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function Import-DGatewayDelegationKey {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,
        [string] $PublicKeyFile,
        [string] $PrivateKeyFile
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    if ($PublicKeyFile) {
        $PublicKeyData = Get-Content -Path $PublicKeyFile -Encoding UTF8
        $OutputFile = Join-Path $ConfigPath $DGatewayDelegationPublicKeyFileName
        $Config.DelegationPublicKeyFile = $DGatewayDelegationPublicKeyFileName
        New-Item -Path $ConfigPath -ItemType 'Directory' -Force | Out-Null
        Set-Content -Path $OutputFile -Value $PublicKeyData -Force
    }

    if ($PrivateKeyFile) {
        $PrivateKeyData = Get-Content -Path $PrivateKeyFile -Encoding UTF8
        $OutputFile = Join-Path $ConfigPath $DGatewayDelegationPrivateKeyFileName
        $Config.DelegationPrivateKeyFile = $DGatewayDelegationPrivateKeyFileName
        New-Item -Path $ConfigPath -ItemType 'Directory' -Force | Out-Null
        Set-Content -Path $OutputFile -Value $PrivateKeyData -Force
    }

    Save-DGatewayConfig -ConfigPath:$ConfigPath -Config:$Config
}

function New-DGatewayToken {
    [CmdletBinding()]
    param(
        [string] $ConfigPath,

        [ValidateSet('ASSOCIATION', 'SCOPE', 'BRIDGE', 'JMUX', 'JREC')]
        [Parameter(Mandatory = $true)]
        [string] $Type, # token type

        # public common claims
        [DateTime] $ExpirationTime, # exp
        [DateTime] $NotBefore, # nbf
        [DateTime] $IssuedAt, # iat

        # private association claims
        [string] $AssociationId, # jet_aid
        [ValidateSet('unknown', 'wayk', 'rdp', 'ard', 'vnc', 'ssh', 'ssh-pwsh', 'sftp', 'scp',
            'winrm-http-pwsh', 'winrm-https-pwsh', 'http', 'https', 'ldap', 'ldaps')]
        [string] $ApplicationProtocol, # jet_ap
        [ValidateSet('fwd', 'rdv')]
        [string] $ConnectionMode, # jet_cm
        [string] $DestinationHost, # dst_hst

        # private jrec claims
        [ValidateSet('push', 'pull')]
        [string] $RecordingOperation = 'push', # jet_rop

        # private scope claims
        [string] $Scope, # scope

        # private bridge claims
        [string] $Target, # target

        # signature parameters
        [string] $PrivateKeyFile
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    $Config = Get-DGatewayConfig -ConfigPath:$ConfigPath -NullProperties

    if (-Not $PrivateKeyFile) {
        if (-Not $Config.ProvisionerPrivateKeyFile) {
            throw "Config file is missing ``ProvisionerPrivateKeyFile``. Alternatively, use -PrivateKeyFile argument."
        }

        if ([System.IO.Path]::IsPathRooted($Config.ProvisionerPrivateKeyFile)) {
            $PrivateKeyFile = $Config.ProvisionerPrivateKeyFile
        } else {
            $PrivateKeyFile = Join-Path $ConfigPath $Config.ProvisionerPrivateKeyFile
        }
    }

    if (-Not (Test-Path -Path $PrivateKeyFile -PathType 'Leaf')) {
        throw "$PrivateKeyFile cannot be found."
    }

    $PrivateKey = ConvertTo-RsaPrivateKey $(Get-Content $PrivateKeyFile -Raw)

    $CurrentTime = Get-Date

    if (-Not $NotBefore) {
        $NotBefore = $CurrentTime
    }

    if (-Not $IssuedAt) {
        $IssuedAt = $CurrentTime
    }

    if (-Not $ExpirationTime) {
        $ExpirationTime = $CurrentTime.AddMinutes(2)
    }

    $iat = [System.DateTimeOffset]::new($IssuedAt).ToUnixTimeSeconds()
    $nbf = [System.DateTimeOffset]::new($NotBefore).ToUnixTimeSeconds()
    $exp = [System.DateTimeOffset]::new($ExpirationTime).ToUnixTimeSeconds()
    $jti = (New-Guid).ToString()

    $Header = [PSCustomObject]@{
        alg = 'RS256'
        typ = 'JWT'
        cty = $Type
    }

    $Payload = [PSCustomObject]@{
        iat    = $iat
        nbf    = $nbf
        exp    = $exp
        jti    = $jti
    }

    if ($Type -eq 'ASSOCIATION') {
        if (-Not $ApplicationProtocol) {
            if ($ConnectionMode -eq 'fwd') {
                $ApplicationProtocol = 'rdp'
            } else {
                $ApplicationProtocol = 'wayk'
            }
        }

        $Payload | Add-Member -MemberType NoteProperty -Name 'jet_ap' -Value $ApplicationProtocol
        
        if (-Not $ConnectionMode) {
            if ($DestinationHost) {
                $ConnectionMode = 'fwd'
            } else {
                $ConnectionMode = 'rdv'
            }
        }
            
        $Payload | Add-Member -MemberType NoteProperty -Name 'jet_cm' -Value $ConnectionMode

        if (-Not $AssociationId) {
            $AssociationId = New-Guid
        }

        $Payload | Add-Member -MemberType NoteProperty -Name 'jet_aid' -Value $AssociationId

        if ($DestinationHost) {
            $Payload | Add-Member -MemberType NoteProperty -Name 'dst_hst' -Value $DestinationHost
        }
    }

    if ($Type -eq 'JMUX') {
        if (-Not $DestinationHost) {
            throw "DestinationHost is required"
        }

        if ($ApplicationProtocol) {
            $Payload | Add-Member -MemberType NoteProperty -Name 'jet_ap' -Value $ApplicationProtocol
        }
        
        if (-Not $AssociationId) {
            $AssociationId = New-Guid
        }

        $Payload | Add-Member -MemberType NoteProperty -Name 'jet_aid' -Value $AssociationId

        $Payload | Add-Member -MemberType NoteProperty -Name 'dst_hst' -Value $DestinationHost
    }

    if ($Type -eq 'JREC') {
        if (-Not $RecordingOperation) {
            throw "RecordingOperation is required"
        }

        if ($ApplicationProtocol) {
            $Payload | Add-Member -MemberType NoteProperty -Name 'jet_ap' -Value $ApplicationProtocol
        }

        $Payload | Add-Member -MemberType NoteProperty -Name 'jet_rop' -Value $RecordingOperation.ToLower()
        
        if (-Not $AssociationId) {
            $AssociationId = New-Guid
        }

        $Payload | Add-Member -MemberType NoteProperty -Name 'jet_aid' -Value $AssociationId

        if ($DestinationHost) {
            $Payload | Add-Member -MemberType NoteProperty -Name 'dst_hst' -Value $DestinationHost
        }
    }

    if (($Type -eq 'SCOPE') -and ($Scope)) {
        $Payload | Add-Member -MemberType NoteProperty -Name 'scope' -Value $Scope
    }

    if (($Type -eq 'BRIDGE') -and ($Target)) {
        $Payload | Add-Member -MemberType NoteProperty -Name 'target' -Value $Target
    }

    New-JwtRs256 -Header $Header -Payload $Payload -PrivateKey $PrivateKey
}

function Get-DGatewayPackage {
    [CmdletBinding()]
    param(
        [string] $RequiredVersion,
        [ValidateSet('Windows', 'Linux')]
        [string] $Platform
    )

    $Version = Get-DGatewayVersion 'PSModule'

    if ($RequiredVersion) {
        $Version = $RequiredVersion
    }

    if (-Not $Platform) {
        if ($IsWindows) {
            $Platform = 'Windows'
        } else {
            $Platform = 'Linux'
        }
    }

    $GitHubDownloadUrl = 'https://github.com/Devolutions/devolutions-gateway/releases/download/'

    if ($Platform -eq 'Windows') {
        $Architecture = 'x86_64'
        $PackageFileName = "DevolutionsGateway-${Architecture}-${Version}.msi"
    } elseif ($Platform -eq 'Linux') {
        $Architecture = 'amd64'
        $PackageFileName = "devolutions-gateway_${Version}.0_${Architecture}.deb"
    }

    $DownloadUrl = "${GitHubDownloadUrl}v${Version}/$PackageFileName"

    [PSCustomObject]@{
        Url     = $DownloadUrl;
        Version = $Version;
    }
}

function Install-DGatewayPackage {
    [CmdletBinding()]
    param(
        [string] $RequiredVersion,
        [switch] $Quiet,
        [switch] $Force
    )

    $Version = Get-DGatewayVersion 'PSModule'

    if ($RequiredVersion) {
        $Version = $RequiredVersion
    }

    $InstalledVersion = Get-DGatewayVersion 'Installed'

    if (($InstalledVersion -eq $Version) -and (-Not $Force)) {
        Write-Host "Devolutions Gateway is already installed ($Version)"
        return
    }

    $TempPath = Join-Path $([System.IO.Path]::GetTempPath()) "dgateway-${Version}"
    New-Item -ItemType Directory -Path $TempPath -ErrorAction SilentlyContinue | Out-Null

    $Package = Get-DGatewayPackage -RequiredVersion $Version
    $DownloadUrl = $Package.Url

    $DownloadFile = Split-Path -Path $DownloadUrl -Leaf
    $DownloadFilePath = Join-Path $TempPath $DownloadFile
    Write-Host "Downloading $DownloadUrl"

    $WebClient = [System.Net.WebClient]::new()
    $WebClient.DownloadFile($DownloadUrl, $DownloadFilePath)
    $WebClient.Dispose()

    $DownloadFilePath = Resolve-Path $DownloadFilePath

    if ($IsWindows) {
        $Display = '/passive'
        if ($Quiet) {
            $Display = '/quiet'
        }
        $InstallLogFile = Join-Path $TempPath 'DGateway_Install.log'
        $MsiArgs = @(
            '/i', "`"$DownloadFilePath`"",
            $Display,
            '/norestart',
            '/log', "`"$InstallLogFile`""
        )

        Start-Process 'msiexec.exe' -ArgumentList $MsiArgs -Wait -NoNewWindow

        Remove-Item -Path $InstallLogFile -Force -ErrorAction SilentlyContinue
    } elseif ($IsMacOS) {
        throw  'unsupported platform'
    } elseif ($IsLinux) {
        $DpkgArgs = @(
            '-i', $DownloadFilePath
        )
        if ((id -u) -eq 0) {
            Start-Process 'dpkg' -ArgumentList $DpkgArgs -Wait
        } else {
            $DpkgArgs = @('dpkg') + $DpkgArgs
            Start-Process 'sudo' -ArgumentList $DpkgArgs -Wait
        }
    }

    Remove-Item -Path $TempPath -Force -Recurse
}

function Uninstall-DGatewayPackage {
    [CmdletBinding()]
    param(
        [switch] $Quiet
    )

    if ($IsWindows) {
        $UninstallReg = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' `
        | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_ -Match 'Devolutions Gateway' }
        if ($UninstallReg) {
            $UninstallString = $($UninstallReg.UninstallString `
                    -Replace 'msiexec.exe', '' -Replace '/I', '' -Replace '/X', '').Trim()
            $Display = '/passive'
            if ($Quiet) {
                $Display = '/quiet'
            }
            $MsiArgs = @(
                '/X', $UninstallString, $Display
            )
            Start-Process 'msiexec.exe' -ArgumentList $MsiArgs -Wait
        }
    } elseif ($IsMacOS) {
        throw  'unsupported platform'
    } elseif ($IsLinux) {
        if (Get-DGatewayVersion 'Installed') {
            $AptArgs = @(
                '-y', 'remove', 'devolutions-gateway', '--purge'
            )
            if ((id -u) -eq 0) {
                Start-Process 'apt-get' -ArgumentList $AptArgs -Wait
            } else {
                $AptArgs = @('apt-get') + $AptArgs
                Start-Process 'sudo' -ArgumentList $AptArgs -Wait
            }
        }
    }
}

function Start-DGateway {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    if ($IsWindows) {
        Start-Service 'DevolutionsGateway'
    } else {
        throw 'not implemented'
    }
}

function Stop-DGateway {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    if ($IsWindows) {
        Stop-Service 'DevolutionsGateway'
    } else {
        throw 'not implemented'
    }
}

function Restart-DGateway {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $ConfigPath = Find-DGatewayConfig -ConfigPath:$ConfigPath
    Stop-DGateway -ConfigPath:$ConfigPath
    Start-DGateway -ConfigPath:$ConfigPath
}
