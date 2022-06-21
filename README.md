# InternetArchiveDownloader

A powershell script to download items from the Internet Archive

## Usage

`./InternetArchiveDownloader.ps1 item-name`
Downloads https://archive.org/download/item-name into ./item-name

### Optional Parameters
- `-Delete` Remove any files in the download directory not found in the archive

## Key Features

- Download all files in an item, maintaining original folder structure
- Stop/resume by killing the script and starting it again later
- Run on an existing folder to verify hashes and redownload changed files