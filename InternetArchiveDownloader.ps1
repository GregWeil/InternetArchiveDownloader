param (
  [string] $Name,
  [switch] $Delete
)

$OutPath = "./$($Name)/"
Write-Output "Working in $($OutPath)"
$Verified = 0
$Downloaded = 0
$Deleted = 0
$StartTime = Get-Date

# Step 1: Create output directory
If (!(Test-Path -PathType Container $OutPath)) {
  New-Item -ItemType Directory -Path $OutPath | Out-Null
}
$OutPath = Resolve-Path $OutPath

# Step 2: Download the file listing
function Get-ArchiveFile {
  param($FileName, $FileSize)
  $OutFile = "$($OutPath)/$($FileName)"
  Write-Host "Downloading $($FileName)" -NoNewline
  if ($FileSize) { Write-Host " ($($FileSize) bytes)" -NoNewline }
  If (!(Test-Path -PathType Container (Split-Path $OutFile -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $OutFile -Parent) | Out-Null
  }
  $StartTime = Get-Date
  Invoke-WebRequest "https://archive.org/download/$($Name)/$($FileName)" -OutFile $OutFile
  Write-Host "`rDownloaded $($FileName) ($((New-TimeSpan $StartTime (Get-Date)).TotalSeconds) seconds)"
  $script:Downloaded += 1
}
Get-ArchiveFile "$($Name)_files.xml"
[xml]$FileListing = Get-Content "$($OutPath)/$($Name)_files.xml"
# (Invoke-WebRequest "https://archive.org/download/$($Name)/$($Name)_files.xml" -UseBasicParsing).Content

# Step 3: Check files in output directory, redownload/delete mismatches
foreach ($File in (Get-ChildItem -LiteralPath $OutPath -Recurse)) {
  $FileName = $File.FullName.Replace($OutPath, '').Replace('\', '/').TrimStart('/')
  $FilePath = "$($OutPath)/$($FileName)".TrimEnd('/')

  function Remove-NonArchiveFile {
    param($Type)
    $script:Deleted += 1
    if ($Delete) {
      Write-Host "Deleting $($Type) $($FileName)"
      Remove-Item $FilePath -Recurse
    }
    else {
      Write-Host "Unexpected $($Type) $($FileName), use -Delete to remove"
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
      Get-ArchiveFile $FileName $FileDefinition.Size
    }
    elseif (!($(Get-FileHash $FilePath -Algorithm MD5).Hash -eq $FileDefinition.MD5)) {
      Get-ArchiveFile $FileName $FileDefinition.Size
    }
    elseif (!($(Get-FileHash $FilePath -Algorithm SHA1).Hash -eq $FileDefinition.SHA1)) {
      Get-ArchiveFile $FileName $FileDefinition.Size
    }
    else {
      $Verified += 1
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
  if (!(Test-Path -LiteralPath "$($OutPath)/$($File.Name)")) {
    Get-ArchiveFile $File.Name $File.Size
  }
}

# Done!
Write-Host ""
$TotalFiles = (Select-Xml -Xml $FileListing -XPath "/files/file").Node.Length
Write-Output "Archive listing contained $($TotalFiles) $(if ($TotalFiles -eq 1) {"file"} else {"files"})"
if ($Downloaded -gt 0) { Write-Output "Downloaded $($Downloaded) $(if ($Downloaded -eq 1) {"file"} else {"files"})" }
if ($Verified -gt 0) { Write-Output "Verified $($Verified) $(if ($Verified -eq 1) {"file"} else {"files"}) already present" }
if ($Deleted -gt 0) { Write-Output "$(if ($Delete) {"Deleted"} else {"Ignored"}) $($Deleted) $(if ($Deleted -eq 1) {"file"} else {"files"}) not in the archive" }
Write-Output "Completed in $(New-TimeSpan $StartTime (Get-Date))"
