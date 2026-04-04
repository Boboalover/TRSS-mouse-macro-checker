# TRSS Mouse Macro / Profile Time Checker

Windows üzerinde bazı popüler mouse yazılımlarının profil / macro ile ilişkili dosyalarının **son değiştirilme zamanını** hızlıca kontrol etmek için hazırlanmış basit bir PowerShell scripti.

Bu araç:

- **dosya oluşturmaz**
- **sadece konsola çıktı verir**
- belirli yazılımların bilinen profil / config dosyalarına bakar
- dosyaların **oluşturulma**, **son değiştirilme** ve **son erişim** zamanlarını gösterir
- son **20 dakika** içinde değişiklik varsa uyarı verir
- ayrıca bazı **browser history** veritabanlarında belirli web-based software sitelerine en son ne zaman girildiğini kontrol etmeye çalışır

---

## Desteklenen yazılımlar

Şu an script aşağıdaki yazılımları kontrol eder:

- **Logitech G HUB**
  - `AppData\Local\LGHUB\settings.db`

- **Logitech Gaming Software (Old)**
  - `AppData\Local\Logitech\Logitech Gaming Software\settings.json`

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

---

## Browser history kontrolü

Script ayrıca bazı tarayıcıların yerel history veritabanlarında aşağıdaki web-based software sitelerini arar:

- **LAMZU Web Hub**
- **Keychron Launcher**
- **WLmouse Web Hub**
- **Corsair Web Hub**
- **Razer browser-based customization / Synapse web tarafı**

Kontrol edilen browserlar:

- **Google Chrome**
- **Microsoft Edge**
- **Brave**
- **Opera / Opera GX**
- **Vivaldi**
- **Yandex Browser**
- **Mozilla Firefox**

Script, bu sitelere **en son ne zaman girildiğini** göstermeye çalışır.

---

## Ne gösterir?

Script, bulduğu dosya veya klasörler için şunları yazdırır:

- dosya bulundu mu / bulunamadı mı
- dosya yolu
- dosya boyutu
- oluşturulma zamanı
- son değiştirilme zamanı
- son erişim zamanı
- değişikliğin üzerinden kaç gün / saat / dakika geçtiği
- son **20 dakika** içinde değişiklik varsa uyarı

Browser history kısmında ise:

- history veritabanı bulundu mu
- hedef domain ile eşleşme bulundu mu
- son eşleşen URL
- en son ziyaret zamanı
- son **20 dakika** içinde ziyaret edilmiş mi

Bazı yazılımlarda tek bir dosya yerine tüm klasör içeriği de listelenir.

---

## Kullanım

PowerShell üzerinden çalıştır:

```powershell
powershell -Command "IEX (New-Object Net.WebClient).DownloadString('https://github.com/Boboalover/TRSS-mouse-macro-checker/raw/refs/heads/main/TRSSmacroChecker.ps1')"
