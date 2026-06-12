<#
.SYNOPSIS
    Exports a Sessionize event to a static Hugo Markdown archive page.

.DESCRIPTION
    Calls the Sessionize read-only JSON API for a given endpoint ID, extracts
    accepted sessions and speakers, and generates a Hugo Markdown content file
    in the evenementen/ section. The output file contains:
      - TOML front matter with event metadata
      - A speaker section with name, title, and bio
      - A placeholder Verslag (report) section for manual completion

    When -AgendaOutputPath is provided, the session schedule is written as a
    separate JSON agenda file (data/agenda/ducug-NN.json) that the site renders
    as the programme timeline (including live event-day highlighting). Session
    types are auto-detected as "break" (service sessions) or "talk"; refine to
    sponsor/org/social by editing the JSON afterwards. Without
    -AgendaOutputPath, the schedule is embedded as a static Markdown table
    instead (legacy behaviour).

    The generated file sets the event as archived. A board member can then add
    the verslag text directly in the file or via Sveltia CMS.

    Supports both manual execution and GitHub Actions automation via the
    -GitHubActionsOutput switch.

.NOTES
    Script    : Export-SessionizeEvent.ps1
    Author    : John Billekens
    Copyright : Copyright (c) John Billekens Consultancy
    Version   : 2026.0608.1200
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory, HelpMessage = "Sessionize API endpoint ID (alphanumeric, from the Sessionize API/Embed page).")]
    [ValidateNotNullOrEmpty()]
    [string]$SessionizeEndpointId,

    [Parameter(Mandatory, HelpMessage = "DuCUG event number (e.g. 29).")]
    [ValidateRange(1, 999)]
    [int]$EventNumber,

    [Parameter(Mandatory, HelpMessage = "Event date in yyyy-MM-dd format.")]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$EventDate,

    [Parameter(Mandatory, HelpMessage = "Event venue/location string.")]
    [ValidateNotNullOrEmpty()]
    [string]$EventLocation,

    [Parameter(Mandatory, HelpMessage = "Path to the Hugo content/evenementen directory.")]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(HelpMessage = "Path to the Hugo data/agenda directory. If provided, the schedule is written as ducug-NN.json instead of a Markdown table.")]
    [string]$AgendaOutputPath = "",

    [Parameter(HelpMessage = "Eventbrite event URL. If omitted, the field is left empty in the front matter.")]
    [string]$EventbriteUrl = "",

    [Parameter(HelpMessage = "Overwrite the output file if it already exists.")]
    [switch]$Force,

    [Parameter(HelpMessage = "Emit GitHub Actions output variables (for use in workflow steps).")]
    [switch]$GitHubActionsOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helper functions ---

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to the console.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Prefix = switch ($Level) {
        "INFO"  { "[INFO ]" }
        "WARN"  { "[WARN ]" }
        "ERROR" { "[ERROR]" }
    }
    Write-Verbose "$($Timestamp) $($Prefix) $($Message)"
}

function ConvertTo-SafeMarkdown {
    <#
    .SYNOPSIS
        Escapes pipe characters in strings used inside Markdown table cells.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$InputString
    )
    process {
        if ([string]::IsNullOrWhiteSpace($InputString)) {
            return ""
        }
        return $InputString.Replace("|", "\|").Replace("`n", " ").Replace("`r", "")
    }
}

function Format-SpeakerBio {
    <#
    .SYNOPSIS
        Truncates and sanitizes a speaker bio for Markdown output.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Bio,

        [Parameter()]
        [int]$MaxLength = 500
    )
    process {
        if ([string]::IsNullOrWhiteSpace($Bio)) {
            return "*Bio niet beschikbaar.*"
        }
        $Sanitized = $Bio.Trim() -replace '\r?\n', ' ' -replace '\s{2,}', ' '
        if ($Sanitized.Length -gt $MaxLength) {
            return "$($Sanitized.Substring(0, $MaxLength).TrimEnd())..."
        }
        return $Sanitized
    }
}

#endregion

#region --- Input validation ---

Write-Log "Starting Export-SessionizeEvent.ps1 for DuCUG #$($EventNumber)"
Write-Log "Sessionize endpoint ID: $($SessionizeEndpointId)"
Write-Log "Output path: $($OutputPath)"

if (-not (Test-Path -Path $OutputPath -PathType Container)) {
    throw "Output path does not exist or is not a directory: $($OutputPath)"
}

$OutputFile = Join-Path -Path $OutputPath -ChildPath "ducug-$($EventNumber).md"

if ((Test-Path -Path $OutputFile) -and (-not $Force)) {
    throw "Output file already exists: $($OutputFile). Use -Force to overwrite."
}

$WriteAgendaJson = -not [string]::IsNullOrWhiteSpace($AgendaOutputPath)
$AgendaFile = $null

if ($WriteAgendaJson) {
    if (-not (Test-Path -Path $AgendaOutputPath -PathType Container)) {
        throw "Agenda output path does not exist or is not a directory: $($AgendaOutputPath)"
    }
    $AgendaFile = Join-Path -Path $AgendaOutputPath -ChildPath "ducug-$($EventNumber).json"
    if ((Test-Path -Path $AgendaFile) -and (-not $Force)) {
        throw "Agenda file already exists: $($AgendaFile). Use -Force to overwrite."
    }
}

#endregion

#region --- Sessionize API call ---

$SessionizeUrl = "https://sessionize.com/api/v2/$($SessionizeEndpointId)/view/All"
Write-Log "Calling Sessionize API: $($SessionizeUrl)"

try {
    $ApiParams = @{
        Uri             = $SessionizeUrl
        Method          = "GET"
        UseBasicParsing = $true
        ErrorAction     = "Stop"
        TimeoutSec      = 30
    }
    $Response = Invoke-WebRequest @ApiParams
}
catch [System.Net.WebException] {
    throw "Sessionize API request failed: $($_.Exception.Message). Verify the endpoint ID '$($SessionizeEndpointId)' is correct and the event is published."
}
catch {
    throw "Unexpected error calling Sessionize API: $($_.Exception.Message)"
}

try {
    $Data = $Response.Content | ConvertFrom-Json
}
catch {
    throw "Failed to parse Sessionize API response as JSON: $($_.Exception.Message)"
}

Write-Log "Sessionize API response received and parsed."

#endregion

#region --- Parse sessions and speakers ---

# The v2 /view/All endpoint returns an array of category objects, each with
# a 'sessions' array. The top-level objects are:
#   [0] = sessions (array of session objects)
#   [1] = speakers (array of speaker objects)
#   [2] = questions
#   [3] = categories
#   [4] = rooms
#
# Sessions array structure per item:
#   id, title, description, startsAt, endsAt, isServiceSession,
#   isPlenumSession, speakers (array of {id, name}), roomId, room, categoryItems
#
# Speakers array structure per item:
#   id, firstName, lastName, bio, tagLine, profilePicture, sessions (array of ids),
#   fullName, categoryItems, links

$Sessions = $null
$Speakers = $null

foreach ($Category in $Data) {
    if ($Category.PSObject.Properties.Name -contains "sessions") {
        $Sessions = $Category.sessions
    }
    if ($Category.PSObject.Properties.Name -contains "speakers") {
        $Speakers = $Category.speakers
    }
}

if ($null -eq $Sessions) {
    throw "No sessions array found in Sessionize API response. Ensure the endpoint is configured to include sessions and that sessions are accepted and speakers have been notified."
}

if ($null -eq $Speakers) {
    Write-Log "No speakers array found in Sessionize response. Speaker section will be omitted." -Level "WARN"
    $Speakers = @()
}

Write-Log "Parsed $($Sessions.Count) session(s) and $($Speakers.Count) speaker(s)."

# Build a speaker lookup hashtable by ID for fast resolution
$SpeakerLookup = @{}
foreach ($Speaker in $Speakers) {
    $SpeakerLookup[$Speaker.id] = $Speaker
}

# Sort sessions by start time; handle sessions without a scheduled time gracefully
$SortedSessions = $Sessions | Sort-Object -Property {
    if ($null -ne $_.startsAt -and $_.startsAt -ne "") {
        [datetime]$_.startsAt
    }
    else {
        [datetime]::MaxValue
    }
}

#endregion

#region --- Build Markdown content ---

Write-Log "Building Markdown content."

$Lines = [System.Collections.Generic.List[string]]::new()

# --- Front matter (TOML) ---
$Lines.Add("+++")
$Lines.Add("title          = `"DuCUG #$($EventNumber)`"")
$Lines.Add("eventNumber    = $($EventNumber)")
$Lines.Add("date           = `"$($EventDate)`"")
$Lines.Add("location       = `"$($EventLocation)`"")
$Lines.Add("eventbriteUrl  = `"$($EventbriteUrl)`"")
$Lines.Add("archived       = true")
$Lines.Add("draft          = false")
$Lines.Add("+++")
$Lines.Add("")

# --- Verslag placeholder ---
$Lines.Add("## Verslag")
$Lines.Add("")
$Lines.Add("*Verslag wordt nog toegevoegd door het bestuur.*")
$Lines.Add("")
$Lines.Add("---")
$Lines.Add("")

# --- Schedule rows (shared between JSON agenda and Markdown table) ---
$ScheduleRows = [System.Collections.Generic.List[hashtable]]::new()

foreach ($Session in $SortedSessions) {
    # Format start/end times
    $StartTime = ""
    $EndTime = ""
    if ($null -ne $Session.startsAt -and $Session.startsAt -ne "") {
        try {
            $StartTime = ([datetime]$Session.startsAt).ToString("HH:mm")
            if ($null -ne $Session.endsAt -and $Session.endsAt -ne "") {
                $EndTime = ([datetime]$Session.endsAt).ToString("HH:mm")
            }
        }
        catch {
            $StartTime = ""
            $EndTime = ""
        }
    }

    # Resolve speaker names from the speakers sub-array on the session
    $SpeakerNames = @()
    if ($null -ne $Session.speakers -and $Session.speakers.Count -gt 0) {
        foreach ($SessionSpeaker in $Session.speakers) {
            if ($SpeakerLookup.ContainsKey($SessionSpeaker.id)) {
                $SpeakerNames += $SpeakerLookup[$SessionSpeaker.id].fullName
            }
            else {
                $SpeakerNames += $SessionSpeaker.name
            }
        }
    }

    $IsService = $false
    if ($Session.PSObject.Properties.Name -contains "isServiceSession") {
        $IsService = [bool]$Session.isServiceSession
    }

    $ScheduleRows.Add(@{
        Start    = $StartTime
        End      = $EndTime
        Title    = [string]$Session.title
        Speakers = ($SpeakerNames -join ", ")
        Type     = if ($IsService) { "break" } else { "talk" }
    })
}

if ($WriteAgendaJson) {
    # Schedule lives in data/agenda/ducug-NN.json; the site renders the timeline.
    Write-Log "Schedule will be written to JSON agenda file; Markdown table omitted."
}
else {
    # --- Programme table (legacy: no agenda JSON requested) ---
    $Lines.Add("## Programma")
    $Lines.Add("")
    $Lines.Add("| Tijd | Sessie | Spreker(s) |")
    $Lines.Add("|------|--------|------------|")

    foreach ($Row in $ScheduleRows) {
        $TimeSlot = $Row.Start
        if ($Row.End -ne "") {
            $TimeSlot = "$($Row.Start)–$($Row.End)"
        }
        $SpeakerCell = if ($Row.Speakers -ne "") { $Row.Speakers } else { "—" }

        $TitleCell   = ConvertTo-SafeMarkdown -InputString $Row.Title
        $SpeakerCell = ConvertTo-SafeMarkdown -InputString $SpeakerCell
        $TimeCell    = ConvertTo-SafeMarkdown -InputString $TimeSlot

        $Lines.Add("| $($TimeCell) | $($TitleCell) | $($SpeakerCell) |")
    }

    $Lines.Add("")
    $Lines.Add("---")
    $Lines.Add("")
}

# --- Speakers section ---
if ($Speakers.Count -gt 0) {
    $Lines.Add("## Sprekers")
    $Lines.Add("")

    foreach ($Speaker in $Speakers) {
        $FullName = ConvertTo-SafeMarkdown -InputString $Speaker.fullName
        $TagLine  = if ($null -ne $Speaker.tagLine -and $Speaker.tagLine -ne "") {
            ConvertTo-SafeMarkdown -InputString $Speaker.tagLine
        }
        else { "" }
        $Bio = Format-SpeakerBio -Bio $Speaker.bio

        $Lines.Add("### $($FullName)")
        if ($TagLine -ne "") {
            $Lines.Add("")
            $Lines.Add("*$($TagLine)*")
        }
        $Lines.Add("")
        $Lines.Add($Bio)
        $Lines.Add("")
    }

    $Lines.Add("---")
    $Lines.Add("")
}

# --- Footer note ---
$Lines.Add("*Deze pagina is automatisch gegenereerd op $(Get-Date -Format 'dd-MM-yyyy') op basis van de Sessionize-agenda voor DuCUG #$($EventNumber).*")

#endregion

#region --- Write output file ---

$MarkdownContent = $Lines -join "`n"

if ($PSCmdlet.ShouldProcess($OutputFile, "Write Hugo archive page")) {
    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($OutputFile, $MarkdownContent, $Utf8NoBom)
    Write-Log "Written: $($OutputFile)"
}

if ($WriteAgendaJson) {
    $AgendaSessions = foreach ($Row in $ScheduleRows) {
        $Entry = [ordered]@{ start = $Row.Start }
        if ($Row.End -ne "")      { $Entry["end"] = $Row.End }
        $Entry["title"] = $Row.Title
        if ($Row.Speakers -ne "") { $Entry["speakers"] = $Row.Speakers }
        $Entry["type"] = $Row.Type
        $Entry
    }

    $Agenda = [ordered]@{
        '$schema' = "../../schemas/agenda.schema.json"
        sessions  = @($AgendaSessions)
    }

    if ($PSCmdlet.ShouldProcess($AgendaFile, "Write JSON agenda")) {
        $AgendaJson = $Agenda | ConvertTo-Json -Depth 4
        $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($AgendaFile, "$($AgendaJson)`n", $Utf8NoBom)
        Write-Log "Written: $($AgendaFile)"
    }
}

#endregion

#region --- GitHub Actions output ---

if ($GitHubActionsOutput) {
    $GhOutputPath = $env:GITHUB_OUTPUT
    if (-not [string]::IsNullOrEmpty($GhOutputPath)) {
        "output_file=$($OutputFile)" | Out-File -FilePath $GhOutputPath -Encoding utf8 -Append
        "event_number=$($EventNumber)"  | Out-File -FilePath $GhOutputPath -Encoding utf8 -Append
        if ($WriteAgendaJson) {
            "agenda_file=$($AgendaFile)" | Out-File -FilePath $GhOutputPath -Encoding utf8 -Append
        }
        Write-Log "GitHub Actions output variables written."
    }
    else {
        Write-Log "GITHUB_OUTPUT environment variable not set — skipping GitHub Actions output." -Level "WARN"
    }
}

#endregion

Write-Log "Export-SessionizeEvent.ps1 completed successfully."
Write-Output $OutputFile
