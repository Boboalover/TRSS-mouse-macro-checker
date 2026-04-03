Clear-Host
$ErrorActionPreference = 'SilentlyContinue'

function Bolum-Yaz {
    param([string]$Baslik)
    Write-Host ""
    Write-Host ("=" * 90) -ForegroundColor DarkGray
    Write-Host $Baslik -ForegroundColor Cyan
    Write-Host ("=" * 90) -ForegroundColor DarkGray
}

function Bilgi-Yaz {
    param(
        [string]$Ad,
        [object]$Deger
    )
    $goster = if ($null -eq $Deger -or $Deger -eq '') { '<boþ>' } else { $Deger }
    Write-Host ("{0,-26}: {1}" -f $Ad, $goster)
}

function Dosya-Zaman-Goster {
    param(
        [string]$Etiket,
        [string]$Yol
    )

    Write-Host ""
    Write-Host "[$Etiket]" -ForegroundColor Magenta
    Bilgi-Yaz "Yol" $Yol

    if (-not (Test-Path $Yol)) {
        Write-Host "Durum                     : Bulunamadý" -ForegroundColor Yellow
        return
    }

    $f = Get-Item $Yol
    $fark = (Get-Date) - $f.LastWriteTime

    Bilgi-Yaz "Durum" "Bulundu"
    Bilgi-Yaz "Boyut" "$($f.Length) byte"
    Bilgi-Yaz "Oluþturulma" $f.CreationTime
    Bilgi-Yaz "Son deðiþtirilme" $f.LastWriteTime
    Bilgi-Yaz "Son eriþim" $f.LastAccessTime
    Bilgi-Yaz "Kaç gün önce" ([math]::Round($fark.TotalDays, 2))
    Bilgi-Yaz "Kaç saat önce" ([math]::Round($fark.TotalHours, 2))

    if ($fark.TotalDays -le 1) {
        Write-Host "Uyarý                     : Son 1 gün içinde deðiþmiþ" -ForegroundColor Red
    } else {
        Write-Host "Uyarý                     : Son 1 gün içinde deðiþiklik görünmüyor" -ForegroundColor Green
    }
}

function Klasor-EnSon-Degisenleri-Goster {
    param(
        [string]$Etiket,
        [string]$Klasor,
        [int]$Limit = 10
    )

    Write-Host ""
    Write-Host "[$Etiket]" -ForegroundColor Magenta
    Bilgi-Yaz "Klasör" $Klasor

    if (-not (Test-Path $Klasor)) {
        Write-Host "Durum                     : Bulunamadý" -ForegroundColor Yellow
        return
    }

    $dosyalar = Get-ChildItem -Path $Klasor -Recurse -Force -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if (-not $dosyalar) {
        Write-Host "Durum                     : Dosya bulunamadý" -ForegroundColor Yellow
        return
    }

    Write-Host "En son deðiþen dosyalar:" -ForegroundColor DarkCyan
    $dosyalar | Select-Object -First $Limit | ForEach-Object {
        Write-Host ""
        Bilgi-Yaz "Ad" $_.Name
        Bilgi-Yaz "Yol" $_.FullName
        Bilgi-Yaz "Son deðiþtirilme" $_.LastWriteTime
        Bilgi-Yaz "Oluþturulma" $_.CreationTime
        Bilgi-Yaz "Son eriþim" $_.LastAccessTime
    }
}

function ModelO-MCF-Dosyalarini-Goster {
    Bolum-Yaz 'Glorious Model O Software / BY-COMBO2 Mac Kontrolü'

    $klasor = Join-Path $env:LOCALAPPDATA 'BY-COMBO2\Mac'
    Bilgi-Yaz 'Klasör' $klasor

    if (-not (Test-Path $klasor)) {
        Write-Host "Durum                     : Klasör bulunamadý" -ForegroundColor Yellow
        return
    }

    $dosyalar = Get-ChildItem -Path $klasor -Filter '*.mcf' -File -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if (-not $dosyalar -or $dosyalar.Count -eq 0) {
        Write-Host "Durum                     : .mcf dosyasý bulunamadý" -ForegroundColor Yellow
        return
    }

    $enSon = $dosyalar | Select-Object -First 1
    $fark = (Get-Date) - $enSon.LastWriteTime

    Write-Host ""
    Write-Host "[En Son Deðiþen .mcf Dosyasý]" -ForegroundColor Magenta
    Bilgi-Yaz 'Ad' $enSon.Name
    Bilgi-Yaz 'Yol' $enSon.FullName
    Bilgi-Yaz 'Boyut' "$($enSon.Length) byte"
    Bilgi-Yaz 'Oluþturulma' $enSon.CreationTime
    Bilgi-Yaz 'Son deðiþtirilme' $enSon.LastWriteTime
    Bilgi-Yaz 'Son eriþim' $enSon.LastAccessTime
    Bilgi-Yaz 'Kaç gün önce' ([math]::Round($fark.TotalDays, 2))
    Bilgi-Yaz 'Kaç saat önce' ([math]::Round($fark.TotalHours, 2))

    if ($fark.TotalDays -le 1) {
        Write-Host "Uyarý                     : Son 1 gün içinde .mcf deðiþikliði var" -ForegroundColor Red
    } else {
        Write-Host "Uyarý                     : Son 1 gün içinde .mcf deðiþikliði görünmüyor" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Bulunan .mcf dosyalarý:" -ForegroundColor DarkCyan

    foreach ($dosya in $dosyalar) {
        $dfark = (Get-Date) - $dosya.LastWriteTime

        Write-Host ""
        Bilgi-Yaz 'Ad' $dosya.Name
        Bilgi-Yaz 'Yol' $dosya.FullName
        Bilgi-Yaz 'Boyut' "$($dosya.Length) byte"
        Bilgi-Yaz 'Oluþturulma' $dosya.CreationTime
        Bilgi-Yaz 'Son deðiþtirilme' $dosya.LastWriteTime
        Bilgi-Yaz 'Son eriþim' $dosya.LastAccessTime
        Bilgi-Yaz 'Kaç gün önce' ([math]::Round($dfark.TotalDays, 2))
        Bilgi-Yaz 'Kaç saat önce' ([math]::Round($dfark.TotalHours, 2))

        if ($dfark.TotalDays -le 1) {
            Write-Host "Durum                     : Son 1 gün içinde deðiþmiþ" -ForegroundColor Red
        } else {
            Write-Host "Durum                     : Son 1 gün içinde deðiþmemiþ" -ForegroundColor Green
        }
    }
}

function ModelD-DCT-Dosyalarini-Goster {
    Bolum-Yaz 'Glorious Model D Software / BY-COMBO2 DCT Kontrolü'

    $klasor = Join-Path $env:LOCALAPPDATA 'BY-COMBO2'
    Bilgi-Yaz 'Klasör' $klasor

    if (-not (Test-Path $klasor)) {
        Write-Host "Durum                     : Klasör bulunamadý" -ForegroundColor Yellow
        return
    }

    $dosyalar = Get-ChildItem -Path $klasor -Filter '*.dct' -File -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if (-not $dosyalar -or $dosyalar.Count -eq 0) {
        Write-Host "Durum                     : .dct dosyasý bulunamadý" -ForegroundColor Yellow
        return
    }

    $enSon = $dosyalar | Select-Object -First 1
    $fark = (Get-Date) - $enSon.LastWriteTime

    Write-Host ""
    Write-Host "[En Son Deðiþen .dct Dosyasý]" -ForegroundColor Magenta
    Bilgi-Yaz 'Ad' $enSon.Name
    Bilgi-Yaz 'Yol' $enSon.FullName
    Bilgi-Yaz 'Boyut' "$($enSon.Length) byte"
    Bilgi-Yaz 'Oluþturulma' $enSon.CreationTime
    Bilgi-Yaz 'Son deðiþtirilme' $enSon.LastWriteTime
    Bilgi-Yaz 'Son eriþim' $enSon.LastAccessTime
    Bilgi-Yaz 'Kaç gün önce' ([math]::Round($fark.TotalDays, 2))
    Bilgi-Yaz 'Kaç saat önce' ([math]::Round($fark.TotalHours, 2))

    if ($fark.TotalDays -le 1) {
        Write-Host "Uyarý                     : Son 1 gün içinde .dct deðiþikliði var" -ForegroundColor Red
    } else {
        Write-Host "Uyarý                     : Son 1 gün içinde .dct deðiþikliði görünmüyor" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Bulunan .dct dosyalarý:" -ForegroundColor DarkCyan

    foreach ($dosya in $dosyalar) {
        $dfark = (Get-Date) - $dosya.LastWriteTime

        Write-Host ""
        Bilgi-Yaz 'Ad' $dosya.Name
        Bilgi-Yaz 'Yol' $dosya.FullName
        Bilgi-Yaz 'Boyut' "$($dosya.Length) byte"
        Bilgi-Yaz 'Oluþturulma' $dosya.CreationTime
        Bilgi-Yaz 'Son deðiþtirilme' $dosya.LastWriteTime
        Bilgi-Yaz 'Son eriþim' $dosya.LastAccessTime
        Bilgi-Yaz 'Kaç gün önce' ([math]::Round($dfark.TotalDays, 2))
        Bilgi-Yaz 'Kaç saat önce' ([math]::Round($dfark.TotalHours, 2))

        if ($dfark.TotalDays -le 1) {
            Write-Host "Durum                     : Son 1 gün içinde deðiþmiþ" -ForegroundColor Red
        } else {
            Write-Host "Durum                     : Son 1 gün içinde deðiþmemiþ" -ForegroundColor Green
        }
    }
}

function Bloody7-Makro-Dosyalarini-Goster {
    Bolum-Yaz 'Bloody7 Macro Kontrolü'

    $klasor = "${env:ProgramFiles(x86)}\Bloody7\Bloody7\Data\Mouse\English\ScriptsMacros\GunLib\MMO,FPS,Office COMBO Examples"
    Bilgi-Yaz 'Klasör' $klasor

    if (-not (Test-Path $klasor)) {
        Write-Host "Durum                     : Klasör bulunamadý" -ForegroundColor Yellow
        return
    }

    $dosyalar = Get-ChildItem -Path $klasor -File -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if (-not $dosyalar -or $dosyalar.Count -eq 0) {
        Write-Host "Durum                     : Dosya bulunamadý" -ForegroundColor Yellow
        return
    }

    $enSon = $dosyalar | Select-Object -First 1
    $fark = (Get-Date) - $enSon.LastWriteTime

    Write-Host ""
    Write-Host "[En Son Deðiþen Bloody Dosyasý]" -ForegroundColor Magenta
    Bilgi-Yaz 'Ad' $enSon.Name
    Bilgi-Yaz 'Yol' $enSon.FullName
    Bilgi-Yaz 'Boyut' "$($enSon.Length) byte"
    Bilgi-Yaz 'Oluþturulma' $enSon.CreationTime
    Bilgi-Yaz 'Son deðiþtirilme' $enSon.LastWriteTime
    Bilgi-Yaz 'Son eriþim' $enSon.LastAccessTime
    Bilgi-Yaz 'Kaç gün önce' ([math]::Round($fark.TotalDays, 2))
    Bilgi-Yaz 'Kaç saat önce' ([math]::Round($fark.TotalHours, 2))

    if ($fark.TotalDays -le 1) {
        Write-Host "Uyarý                     : Son 1 gün içinde Bloody makro klasöründe deðiþiklik var" -ForegroundColor Red
    } else {
        Write-Host "Uyarý                     : Son 1 gün içinde deðiþiklik görünmüyor" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Bulunan dosyalar:" -ForegroundColor DarkCyan

    foreach ($dosya in $dosyalar) {
        $dfark = (Get-Date) - $dosya.LastWriteTime

        Write-Host ""
        Bilgi-Yaz 'Ad' $dosya.Name
        Bilgi-Yaz 'Yol' $dosya.FullName
        Bilgi-Yaz 'Uzantý' $dosya.Extension
        Bilgi-Yaz 'Boyut' "$($dosya.Length) byte"
        Bilgi-Yaz 'Oluþturulma' $dosya.CreationTime
        Bilgi-Yaz 'Son deðiþtirilme' $dosya.LastWriteTime
        Bilgi-Yaz 'Son eriþim' $dosya.LastAccessTime
        Bilgi-Yaz 'Kaç gün önce' ([math]::Round($dfark.TotalDays, 2))
        Bilgi-Yaz 'Kaç saat önce' ([math]::Round($dfark.TotalHours, 2))

        if ($dfark.TotalDays -le 1) {
            Write-Host "Durum                     : Son 1 gün içinde deðiþmiþ" -ForegroundColor Red
        } else {
            Write-Host "Durum                     : Son 1 gün içinde deðiþmemiþ" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Öne çýkan uzantýlar:" -ForegroundColor DarkCyan
    $ilgili = $dosyalar | Where-Object { $_.Extension -match '^\.(amc2|mgn2|bwp|bmc|bwd|cfg|ini)$' }

    if ($ilgili) {
        foreach ($d in $ilgili) {
            Write-Host ("- {0} ({1}) | {2}" -f $d.Name, $d.Extension, $d.LastWriteTime)
        }
    } else {
        Write-Host "Ýlgili uzantýda dosya bulunamadý." -ForegroundColor Yellow
    }
}

function Corsair-CUE-Config-Goster {
    Bolum-Yaz 'Corsair CUE Config Kontrolü'

    $klasor = Join-Path $env:APPDATA 'Corsair\CUE'
    $dosya  = Join-Path $klasor 'config.cuecfg'

    Bilgi-Yaz 'Klasör' $klasor
    Bilgi-Yaz 'Dosya'  $dosya

    if (-not (Test-Path $dosya)) {
        Write-Host "Durum                     : config.cuecfg bulunamadý" -ForegroundColor Yellow
        return
    }

    $f = Get-Item $dosya
    $fark = (Get-Date) - $f.LastWriteTime

    Write-Host ""
    Write-Host "[config.cuecfg]" -ForegroundColor Magenta
    Bilgi-Yaz 'Ad' $f.Name
    Bilgi-Yaz 'Yol' $f.FullName
    Bilgi-Yaz 'Boyut' "$($f.Length) byte"
    Bilgi-Yaz 'Oluþturulma' $f.CreationTime
    Bilgi-Yaz 'Son deðiþtirilme' $f.LastWriteTime
    Bilgi-Yaz 'Son eriþim' $f.LastAccessTime
    Bilgi-Yaz 'Kaç gün önce' ([math]::Round($fark.TotalDays, 2))
    Bilgi-Yaz 'Kaç saat önce' ([math]::Round($fark.TotalHours, 2))

    if ($fark.TotalDays -le 1) {
        Write-Host "Uyarý                     : Son 1 gün içinde config.cuecfg deðiþmiþ" -ForegroundColor Red
    } else {
        Write-Host "Uyarý                     : Son 1 gün içinde deðiþiklik görünmüyor" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Ayný klasördeki diðer öðeler:" -ForegroundColor DarkCyan

    $ogeler = Get-ChildItem -Path $klasor -Force -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    foreach ($oge in $ogeler) {
        Write-Host ""
        Bilgi-Yaz 'Ad' $oge.Name
        Bilgi-Yaz 'Tür' ($(if ($oge.PSIsContainer) { 'Klasör' } else { 'Dosya' }))
        Bilgi-Yaz 'Yol' $oge.FullName
        Bilgi-Yaz 'Son deðiþtirilme' $oge.LastWriteTime
        Bilgi-Yaz 'Oluþturulma' $oge.CreationTime
        Bilgi-Yaz 'Son eriþim' $oge.LastAccessTime
    }
}

Bolum-Yaz 'TRSS Mouse Macro / Profile Time Checker'

# Logitech G HUB
$logitechBase = Join-Path $env:LOCALAPPDATA 'LGHUB'
$logitechSettings = Join-Path $logitechBase 'settings.db'
Dosya-Zaman-Goster -Etiket 'Logitech G HUB - settings.db' -Yol $logitechSettings

# Glorious Core
$gloriousBase = Join-Path $env:APPDATA 'Glorious Core\datastore'
$gloriousProfiles = Join-Path $gloriousBase 'DeviceProfiles.json'
$gloriousMacros = Join-Path $gloriousBase 'Macros.json'
Dosya-Zaman-Goster -Etiket 'Glorious Core - DeviceProfiles.json' -Yol $gloriousProfiles
Dosya-Zaman-Goster -Etiket 'Glorious Core - Macros.json' -Yol $gloriousMacros

# ROCCAT / Swarm II
$swarm2Base = Join-Path $env:APPDATA 'TurtleBeach\SWARMII'
Klasor-EnSon-Degisenleri-Goster -Etiket 'ROCCAT / Turtle Beach - SWARMII' -Klasor $swarm2Base -Limit 10

# Glorious Model O
ModelO-MCF-Dosyalarini-Goster

# Glorious Model D
ModelD-DCT-Dosyalarini-Goster

# Bloody7
Bloody7-Makro-Dosyalarini-Goster

# Corsair
Corsair-CUE-Config-Goster

Write-Host ""
Write-Host "Tamamlandý." -ForegroundColor Cyan