# TRSS Mouse Macro / Profile Time Checker

Windows üzerinde bazı popüler mouse yazılımlarının profil / macro ile ilişkili dosyalarının **son değiştirilme zamanını** hızlıca kontrol etmek için hazırlanmış basit bir PowerShell scripti.

Bu araç:

- **dosya oluşturmaz**
- **sadece konsola çıktı verir**
- belirli yazılımların bilinen profil / config dosyalarına bakar
- dosyaların **oluşturulma**, **son değiştirilme** ve **son erişim** zamanlarını gösterir
- son **1 gün** içinde değişiklik varsa uyarı verir

---

## Desteklenen yazılımlar

Şu an script aşağıdaki yazılımları kontrol eder:

- **Logitech G HUB**
  - `AppData\Local\LGHUB\settings.db`

- **Glorious Core**
  - `AppData\Roaming\Glorious Core\datastore\DeviceProfiles.json`
  - `AppData\Roaming\Glorious Core\datastore\Macros.json`

- **ROCCAT / Turtle Beach SWARM II**
  - `AppData\Roaming\TurtleBeach\SWARMII`

- **Glorious Model O Software**
  - `AppData\Local\BY-COMBO2\Mac\*.mcf`

- **Glorious Model D Software**
  - `AppData\Local\BY-COMBO2\*.dct`

- **Bloody7**
  - `Program Files (x86)\Bloody7\Bloody7\Data\Mouse\English\ScriptsMacros\GunLib\MMO,FPS,Office COMBO Examples`

- **Corsair CUE**
  - `AppData\Roaming\Corsair\CUE\config.cuecfg`

Ayrıca script içinde sonradan path eklenebilecek boş alanlar da vardır:
- **Razer Synapse**
- **LAMZU**

---

## Ne gösterir?

Script, bulduğu dosya veya klasörler için şunları yazdırır:

- dosya bulundu mu / bulunamadı mı
- dosya yolu
- dosya boyutu
- oluşturulma zamanı
- son değiştirilme zamanı
- son erişim zamanı
- değişikliğin üzerinden kaç gün / saat geçtiği
- son **1 gün** içinde değişiklik varsa uyarı

Bazı yazılımlarda tek bir dosya yerine tüm klasör içeriği de listelenir.

---

## Kullanım

PowerShell üzerinden çalıştır:

```CMD(admin)
powershell -Command "IEX (New-Object Net.WebClient).DownloadString('https://github.com/Boboalover/TRSS-mouse-macro-checker/raw/refs/heads/main/TRSSmacroChecker.ps1')"
