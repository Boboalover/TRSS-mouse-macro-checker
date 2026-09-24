# TRSS Mouse Macro Checker v2.2
 
Ekran paylaşımı (SS) sırasında mouse makrosu / otomasyon kullanımına dair izleri toplayan PowerShell scripti.
Sadece **okuma** yapar; sisteme hiçbir şey yazmaz (rapor dosyası ve geçici kopyalar hariç, `%TEMP%`).
 
> Bulgular kesin kanıt değildir; SS yapan kişinin değerlendirmesine yardımcı göstergelerdir.
 
---
 
## Kullanım
 
**Yönetici** olarak açılmış CMD'de:
 
```bat
powershell -ExecutionPolicy Bypass -Command "IEX ((Invoke-RestMethod 'https://raw.githubusercontent.com/Boboalover/TRSS-mouse-macro-checker/refs/heads/main/TRSSmacroChecker.ps1').TrimStart([char]0xFEFF))"
```
 
Daha güvenli kullanım için `main` yerine sabit bir sürüme (etiket veya commit) bağlayın, örneğin:
`.../refs/tags/v2.0.0/TRSSmacroChecker.ps1`. Böylece repo sonradan değişse bile herkes aynı kodu çalıştırır.
 
Dosyayı indirip yerelde çalıştırmak için: `powershell -ExecutionPolicy Bypass -File TRSSmacroChecker.ps1` (dosya UTF-8 BOM ile kaydedilmiştir, Türkçe karakterler düzgün görünür).
 
Çıktı ayrıca `%TEMP%\TRSS_rapor_<tarih>.txt` dosyasına kaydedilir.
 
Yönetici yetkisi olmadan da çalışır, ancak **USN Journal** analizi ve **diğer kullanıcı profilleri** atlanır.
 
---
 
## Ne kontrol eder?
 
### 1. Çalışan süreçler
G HUB, LGS, Razer, iCUE, SteelSeries, NGENUITY, SWARM, Glorious, Bloody, AutoHotkey, X-Mouse, TinyTask vb.
Kısa süre önce başlatılan süreçler ve yazılım tabanlı makro araçları işaretlenir.
 
### 2. Kurulu yazılımlar (kayıt defteri)
HKLM (32/64 bit) ve tüm yüklü kullanıcı hive'larındaki Uninstall kayıtları. Bugün/dün kurulanlar işaretlenir.
Kurulum konumu, farklı diske kurulmuş yazılımların dosyalarını bulmak için de kullanılır.
 
### 3. Profil / makro dosyaları (tüm kullanıcı profilleri)
 
| Yazılım | Konum |
|---|---|
| Logitech G HUB | `Local\LGHUB\*.db, *.json` |
| Logitech Gaming Software | `Local\Logitech\Logitech Gaming Software\` (profiles\*.xml dahil) |
| Glorious Core | `Roaming\Glorious Core\**\*.json` |
| Glorious Model O / D | `Local\BY-COMBO*\**` |
| ROCCAT SWARM / Turtle Beach SWARM II | `Roaming\ROCCAT\SWARM`, `Roaming\Turtle*Beach\*SWARM*` |
| Corsair iCUE | `Roaming\Corsair\CUE*` (CUE, CUE4, CUE5) |
| Razer Synapse 4 | `Local\Razer\RazerAppEngine\User Data\Logs`, IndexedDB |
| Razer Synapse 3 / 2 | `Local\Razer\Synapse3`, `ProgramData\Razer\Synapse3`, `ProgramData\Razer\Synapse` |
| SteelSeries GG / Engine | `ProgramData\SteelSeries\GG`, `...\SteelSeries Engine 3` |
| HyperX NGENUITY | `Local\Packages\*NGENUITY*\LocalState` |
| Bloody / A4Tech | Program Files + kayıt defterindeki kurulum konumu, **tüm dil klasörleri** |
| X-Mouse Button Control | `Roaming\Highresolution Enterprises\XMouseButtonControl` |
| AutoHotkey / TinyTask | Masaüstü, İndirilenler, Belgeler (OneDrive dahil) |
 
Her dosya için bayraklar:
 
- **YENİ**: eşik (varsayılan 20 dk) içinde değişmiş. Yazılım **kapalıysa KIRMIZI**, açıksa SARI (program kendisi yazıyor olabilir).
- **KOPYALANMIŞ?**: oluşturulma zamanı değiştirilme zamanından sonra.
- **YUVARLAK-ZAMAN**: saniye-altı kısmı tam sıfır, yani zaman damgası elle ayarlanmış olabilir.
- İçerikte `macro` kelimesinin kaç kez geçtiği (bilgi amaçlı).
- Bloody: kurulumdan **sonra** eklenen makro dosyaları (programla gelen örnek dosyalardan ayırmak için).
### 4. USN Journal (yönetici gerekir)
Dosya tarihi elle geri alınsa bile NTFS değişiklik günlüğünde kayıt kalır. Çıktı kısadır:
 
- Her yazılım klasörü için **tek satır**: son yazma zamanı ve silme sayısı
- Günlük zamanı ile dosya tarihi tutmuyorsa **KIRMIZI** (tarih geri alınmış / dosya kopyalanmış)
- Başka konumlarda `.ahk`, makro dosyaları, TinyTask vb. için **son 10** oluşturma / silme
### 5. Tarayıcılar (sqlite3 / Python gerekmez, Windows'un `winsqlite3.dll`'i kullanılır)
Chrome, Edge, Brave, Vivaldi, Yandex, Chromium, Opera, Opera GX (tüm profiller), Firefox / Waterfox / LibreWolf / Zen.
 
- Web hub ziyaretleri (LAMZU, Keychron, WLmouse, Corsair, Razer, genel "web-hub" adresleri)
- İlgili indirmeler (Bloody, G HUB, AutoHotkey, TinyTask kurulum dosyaları vb.)
- **WebHID / WebUSB / WebSerial izinleri** (Chromium `Preferences`): geçmiş silinse bile kalır
- Web hub sitelerinin IndexedDB site verisi
- Firefox için `-wal` dosyası da kopyalanır; son dakikalardaki ziyaretler kaçmaz
### 6. Mouse / HID cihazları
- Bağlı **fiziksel** mouse sayısı (ContainerId ile gruplanır; bir fare 2-3 HID arayüzü açsa da tek sayılır)
- Harici / dahili (touchpad) / sanal (RDP) ayrımı
- Kısa süre önce **takılan** ve **çıkarılan** mouse'lar
- Aynı VID:PID'in iki farklı cihazda görünmesi (klon / spoof)
- Tüm cihaz sınıflarında şüpheli VID taraması: Arduino, SparkFun, Adafruit, Teensy, Raspberry Pi Pico, WCH (CH340/CH9329)
### 7. Mouse testi penceresi (opsiyonel)
 
**Sol taraf: tıklama testi**
- Oyuncu kutunun içine 10 saniye hızlı tıklar, **anlık CPS** büyük olarak gösterilir
- En yüksek CPS, toplam tık ve kalan süre canlı güncellenir, "Yeniden" ile test tekrarlanır
- Test sonunda konsola: ortalama / en yüksek CPS ve tıklama düzenliliği (makro gibi düzenliyse KIRMIZI)
**Sağ taraf: tuş kontrolü**
- Mouse çizimi üzerinde basılan tuş **turuncu** yanar, daha önce basılmış tuşlar **yeşil** kalır
- Sol, sağ, orta tuş, geri / ileri yan tuşları, tekerlek yukarı / aşağı ve tekerlek eğimi
- Basıldığı halde yanmayan tuş, yazılımda klavye tuşuna ya da makroya atanmış olabilir
Arka planda ayrıca yazılımla üretilmiş (INJECTED) tıklamalar ve ikinci bir cihazdan gelen girdi yakalanır.
 
---
 
## Sınırlamalar
 
- Farenin kendi hafızasına yazılmış makrolar yazılım kaldırılsa da çalışır; dosya kontrolleri bunu göstermez.
- Gizli sekmede açılan web hub'lar geçmişe yazılmaz (WebHID izni ve site verisi genelde kalır).
- KMBox gibi cihazlar gerçek bir farenin VID/PID'ini kopyalayabilir.
- Tıklama testi eşikleri sezgiseldir; tek başına karar vermek için kullanılmamalıdır.
## Ayarlar
 
Script'in başındaki değişkenler:
 
```powershell
$EsikDakika       = 20      # KIRMIZI eşik
$GunlukEsikDakika = 1440    # SARI eşik
$ListeLimit       = 8       # klasör başına listelenen dosya
$TestSuresiSn     = 10      # tıklama testi süresi
```
 
