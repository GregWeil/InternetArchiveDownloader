param (
  [Parameter(Mandatory)]
  [string] $Name,
  [string] $Folder,
  [string] $OutPath = "./$($Name)/",
  [switch] $Delete
)

$Folder = if ($Folder) { $Folder.Replace('\', '/').Trim('/') + '/' } else { "" }
Write-Output "Working in $($OutPath)"
$MaxConcurrent = 5
$Pending = @()
$Verified = @()
$Downloaded = @()
$Deleted = @()
$Skipped = @()
$StartTime = Get-Date

try {
  # Step 1: Create output directory
  if (!(Test-Path -PathType Container $OutPath)) {
    New-Item -ItemType Directory -Path $OutPath | Out-Null
  }
  $OutPath = Resolve-Path $OutPath
  function Wait-ArchiveFiles {
    param($MaxRemaining = 0)
    while ($Pending.Length -gt $MaxRemaining) {
      Wait-Job $script:Pending -Any -Timeout 1 | Out-Null
      Receive-Job $script:Pending
      $script:Pending = @($script:Pending | Where-Object { $_.HasMoreData })
    }
  }
  function Request-ArchiveFile {
    param($FileName)
    if ($script:Pending.Length -ge $MaxConcurrent) {
      Wait-ArchiveFiles ($MaxConcurrent - 1)
    }
    if (!$FileName.StartsWith($script:Folder)) {
      throw "$($FileName) is not in $($script:Folder)"
    }
    $OutFile = "$($OutPath)/$($FileName.Substring($script:Folder.Length))"
    if (!(Test-Path -PathType Container (Split-Path $OutFile -Parent))) {
      New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) | Out-Null
    }
    $InputObject = @{
      Name        = $FileName
      StartTime   = Get-Date
      Source      = "https://archive.org/download/$($Name)/$($FileName)"
      Destination = $OutFile
    }
    $script:Pending += Start-Job -Name $FileName -InputObject $InputObject -ScriptBlock {
      $InputObject = @($input)
      Start-BitsTransfer -Source $InputObject.Source -Destination $InputObject.Destination -DisplayName $InputObject.Name
      Write-Output "Downloaded $($InputObject.Name) ($((New-TimeSpan $InputObject.StartTime (Get-Date)).TotalSeconds) seconds)"
    }
    $script:Downloaded += $FileName
  }

  # Step 2: Download the file listing
  [xml]$FileListing = if ($Folder) {
    (Invoke-WebRequest "https://archive.org/download/$($Name)/$($Name)_files.xml" -UseBasicParsing).Content
  }
  else {
    Request-ArchiveFile "$($Name)_files.xml"
    Wait-ArchiveFiles
    Get-Content "$($OutPath)/$($Name)_files.xml"
  }

  # Step 3: Check files in output directory, redownload/delete mismatches
  foreach ($File in (Get-ChildItem -LiteralPath $OutPath -Recurse)) {
    $FileName = $Folder + $File.FullName.Replace($OutPath, '').Replace('\', '/').TrimStart('/')
    $FilePath = $File.FullName.Replace('\', '/').TrimEnd('/')

    function Remove-NonArchiveFile {
      param($Type)
      $script:Deleted += $FileName
      if ($Delete) {
        Write-Output "Deleting $($Type) $($FileName)"
        Remove-Item $FilePath -Recurse
      }
      else {
        Write-Output "Unexpected $($Type) $($FileName), use -Delete to remove"
      }
    }

    # Verify a directory
    if (Test-Path -LiteralPath $FilePath -PathType Container) {
      if (!(Select-Xml -Xml $FileListing -XPath "/files/file[starts-with(@name, '$($FileName)/')]")) {
        Remove-NonArchiveFile "directory"
      }
    }

    # Verify a file
    elseif (Test-Path -LiteralPath $FilePath -PathType Leaf) {
      $XPath = "/files/file[@name='$($FileName)']"
      $FileDefinition = (Select-Xml -Xml $FileListing -XPath $XPath).Node
      if (!$FileDefinition) {
        Remove-NonArchiveFile "file"
      }
      elseif ($FilePath -eq "$($OutPath)/$($Name)_files.xml") {
        # We just downloaded this, no need to check against itself
      }
      elseif (!($File.Length -eq $FileDefinition.Size)) {
        Request-ArchiveFile $FileName $FileDefinition.Size
      }
      elseif (!($(Get-FileHash $FilePath -Algorithm MD5).Hash -eq $FileDefinition.md5)) {
        Request-ArchiveFile $FileName $FileDefinition.Size
      }
      elseif (!($(Get-FileHash $FilePath -Algorithm SHA1).Hash -eq $FileDefinition.sha1)) {
        Request-ArchiveFile $FileName $FileDefinition.Size
      }
      else {
        if (!((Get-Date $File.LastWriteTime.ToUniversalTime() -UFormat %s) -eq $FileDefinition.mtime)) {
          $File.LastWriteTime = (Get-Date "1970-01-01Z").ToUniversalTime().AddSeconds($FileDefinition.mtime).ToLocalTime()
          Write-Output "Corrected file timestamp on $($FileName)"
        }
        $Verified += $FileName
        if (($Verified.Length % 500) -eq 0) {
          Write-Output "Verified $($Verified.Length) files..."
        }
      }
    }

    elseif (!(Test-Path -LiteralPath $FilePath)) {
      # This was probably already removed from an unrecognized folder
    }
    else {
      throw "Something is wrong with $($FileName)"
    }
  }

  # Step 4: Download all files not in the directory
  foreach ($File in (Select-Xml -Xml $FileListing -XPath "/files/file").Node) {
    if (!$File.Name.StartsWith($Folder)) {
      $Skipped += $File.Name
      continue;
    }
    if (!(Test-Path -LiteralPath "$($OutPath)/$($File.Name.Substring($Folder.Length))")) {
      Request-ArchiveFile $File.Name
    }
  }

  # Step 5: Wait for the download to complete
  if ($Pending) {
    Wait-ArchiveFiles
  }

  # Done!
  Write-Output ""
  $TotalFiles = (Select-Xml -Xml $FileListing -XPath "/files/file").Node.Length
  Write-Output "Archive listing contained $($TotalFiles) $(if ($TotalFiles -eq 1) {"file"} else {"files"})"
  if ($Verified) { Write-Output "Verified $($Verified.Length) $(if ($Verified.Length -eq 1) {"file ($($Verified))"} else {"files"}) already present" }
  if ($Downloaded.Length) { Write-Output "Downloaded $($Downloaded.Length) $(if ($Downloaded.Length -eq 1) {"file ($($Downloaded))"} else {"files"})" }
  if ($Deleted.Length) { Write-Output "$(if ($Delete) {"Deleted"} else {"Ignored"}) $($Deleted.Length) $(if ($Deleted.Length -eq 1) {"file ($($Deleted))"} else {"files"}) not in the archive" }
  if ($Skipped.Length) { Write-Output "Skipped $($Skipped.Length) $(if ($Skipped.Length -eq 1) {"file ($($Deleted))"} else {"files"}) not in $($Folder)" }
  Write-Output "Completed in $(New-TimeSpan $StartTime (Get-Date))"
}
finally {
  if ($Pending) {
    Stop-Job $Pending
  }
}
