#!/usr/bin/env pwsh
# Does BC accept an Entra token at all?
#
# Every call below goes to localhost, so a tunnel or proxy is not in the path. If the
# bearer calls succeed here, BC's token validation is fine and the web client or the
# tunnel is at fault. If they fail the same way the browser does, it is BC.
#
# Needs an app registration with a delegated BC scope and device-code flow enabled:
#   BC_AAD_TENANT_ID=<guid> BC_AAD_APP_ID=<guid> pwsh scripts/test-bc-auth.ps1

$ErrorActionPreference = 'Stop'

$TenantId = $env:BC_AAD_TENANT_ID
$ClientId = $env:BC_AAD_APP_ID
if (-not $TenantId -or -not $ClientId) {
    Write-Host 'Set BC_AAD_TENANT_ID and BC_AAD_APP_ID to the registration BC trusts.' -ForegroundColor Red
    exit 1
}

$Scope      = 'https://api.businesscentral.dynamics.com/user_impersonation offline_access openid profile'
$BcUser     = if ($env:BC_SERVER_USERNAME) { $env:BC_SERVER_USERNAME } else { 'BCRUNNER' }
$BcPass     = if ($env:BC_SERVER_PASSWORD) { $env:BC_SERVER_PASSWORD } else { 'Admin123!' }
$SaPass     = if ($env:SA_PASSWORD) { $env:SA_PASSWORD } else { 'Passw0rd123!' }
$SqlServer  = if ($env:SQL_SERVER) { $env:SQL_SERVER } else { 'sql' }
$ODataPort  = if ($env:BC_ODATA_PORT) { $env:BC_ODATA_PORT } else { '7048' }
$DevPort    = if ($env:BC_DEV_PORT) { $env:BC_DEV_PORT } else { '7049' }
$ApiPort    = if ($env:BC_API_PORT) { $env:BC_API_PORT } else { '7052' }

function Show-Result {
    param([string]$Label, [string]$Url, [hashtable]$Headers)
    $r = Invoke-WebRequest -Uri $Url -Headers $Headers -SkipHttpErrorCheck -TimeoutSec 30
    $body = if ($r.Content.Length -gt 160) { $r.Content.Substring(0,160) + '...' } else { $r.Content }
    '{0,-34} {1}' -f $Label, $r.StatusCode
    if ($r.Headers['WWW-Authenticate']) {
        '{0,-34} WWW-Authenticate: {1}' -f '', ($r.Headers['WWW-Authenticate'] -join '; ')
    }
    if ($r.StatusCode -ne 200) { '{0,-34} {1}' -f '', $body.Trim() }
}

Write-Host "`n=== 1. Control: basic auth, no token involved ===" -ForegroundColor Cyan
$basic = @{ Authorization = 'Basic ' + [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${BcUser}:${BcPass}")) }
Show-Result 'OData  /ODataV4/Company' "http://localhost:$ODataPort/BC/ODataV4/Company" $basic
Show-Result 'Dev    /dev/metadata'    "http://localhost:$DevPort/BC/dev/metadata"      $basic

Write-Host "`n=== 2. Sign in to Entra (device code) ===" -ForegroundColor Cyan
$dc = Invoke-RestMethod -Method Post -TimeoutSec 30 `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $ClientId; scope = $Scope }
Write-Host $dc.message -ForegroundColor Yellow

$deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
$token = $null
while (-not $token -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds ([int]$dc.interval)
    try {
        $resp = Invoke-RestMethod -Method Post -TimeoutSec 30 `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body @{ grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                     client_id  = $ClientId
                     device_code = $dc.device_code }
        $token = $resp.access_token
    } catch {
        $err = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue)
        if ($err.error -ne 'authorization_pending') {
            Write-Host "Entra refused: $($err.error) - $($err.error_description)" -ForegroundColor Red
            exit 1
        }
    }
}
if (-not $token) { Write-Host 'Timed out waiting for sign-in.' -ForegroundColor Red; exit 1 }

Write-Host "`n=== 3. What the token actually says ===" -ForegroundColor Cyan
$part = $token.Split('.')[1].Replace('-','+').Replace('_','/')
while ($part.Length % 4) { $part += '=' }
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
foreach ($c in 'aud','iss','ver','oid','upn','unique_name','preferred_username','email','name','sub','idp','acct','appid','azp','scp','tid') {
    if ($claims.PSObject.Properties.Name -contains $c) { '{0,-20} {1}' -f $c, $claims.$c }
}
Write-Host "`n(ValidAudiences must contain 'aud'. BC matches the user by an email-bearing"
Write-Host " claim - upn or unique_name - against [User].[Authentication Email].)" -ForegroundColor DarkGray

Write-Host "`n=== 4. Same endpoints with the Entra token ===" -ForegroundColor Cyan
$bearer = @{ Authorization = "Bearer $token" }
Show-Result 'OData  /ODataV4/Company'    "http://localhost:$ODataPort/BC/ODataV4/Company"   $bearer
Show-Result 'API    /api/v2.0/companies' "http://localhost:$ApiPort/BC/api/v2.0/companies"  $bearer
Show-Result 'Dev    /dev/metadata'       "http://localhost:$DevPort/BC/dev/metadata"        $bearer

Write-Host "`n=== 5. Did BC bind the object id to the user? ===" -ForegroundColor Cyan
$sql = @"
SET NOCOUNT ON;
SELECT u.[User Name] + ' | ' + u.[Authentication Email] + ' | oid=[' + p.[Authentication Object ID] + ']'
FROM [User] u JOIN [User Property] p ON p.[User Security ID] = u.[User Security ID];
"@
docker compose exec -T bc /opt/mssql-tools18/bin/sqlcmd `
    -S $SqlServer -U sa -P $SaPass -C -No -d CRONUS -h -1 -W -Q $sql
Write-Host "`nIf oid is still empty for your user, BC never matched the token to that row." -ForegroundColor DarkGray
