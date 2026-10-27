# GeoFinder

System do koordynacji przeszukiwania terenu. Uczestnicy chodzą z telefonami, a każdy z nich
„maluje mazakiem” o swoim promieniu wspólną mapę przeszukanego terenu. Koordynator
wyznacza obszar, dzieli go na kwadraty (A1, B2, …) i ustala każdemu promień. Zgłoszenie
(np. *„W kwadracie A1 znaleziono ślad”*) trafia do wszystkich jako powiadomienie.

```
server/   mały serwer (Python, FastAPI + SQLite + WebSocket)
app/      aplikacja Flutter – Android, iOS, web, Windows, macOS, Linux
          (jedna aplikacja: tryb „Uczestnik” i tryb „Koordynator”)
```

## 1. Serwer

Wymaga Pythona 3.10+. Wystarczy laptop albo Raspberry Pi w tej samej sieci (np. hotspot
z telefonu) albo VPS w internecie.

```bash
cd server
python -m venv .venv
.venv\Scripts\activate          # Linux/macOS: source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8000
```

Po starcie w konsoli pojawią się **klucz administratora** i **kod dołączenia**. Za pierwszym
razem są losowane i zapisywane w bazie. Możesz je ustawić sam: zmienne środowiskowe
`ADMIN_KEY` i `JOIN_CODE`. Dane trzyma plik `server/geofinder.db`.

## 2. Aplikacja (Flutter)

Wymaga Flutter SDK 3.22+.

```bash
cd app
dart run tool/setup.dart      # jednorazowo: tworzy android/ ios/ web/ … i dodaje uprawnienia
flutter pub get
flutter run                   # na podłączonym telefonie
flutter build apk --release   # plik APK do rozesłania uczestnikom
```

**Wersja przeglądarkowa** (wygodna dla koordynatora na laptopie):

```bash
flutter build web
# skopiuj app/build/web do server/web, a serwer sam ją udostępni pod http://<serwer>:8000/
```

Na Windows: `xcopy /E /I app\build\web server\web`.

## Jak to działa

**Koordynator** (tryb „Koordynator”, klucz administratora):
1. **Obszar**: klika na mapie dwa przeciwległe rogi terenu akcji.
2. **Siatka i parametry**: liczba kolumn i wierszy albo bok kwadratu w metrach (przycisk
   „Dopasuj”). Kolumny to litery, wiersze to cyfry, A1 jest w lewym górnym rogu. Kwadraty
   służą tylko do opisu miejsca, to nie są punkty kontrolne.
3. **Punkt kalibracyjny**: klika znane, łatwe do znalezienia miejsce (np. słup, róg
   budynku przy bazie).
4. **Uczestnicy**: każdemu ustawia promień w metrach, czyli szerokość „mazaka”. Na
   otwartym polu może to być 15–20 m, w gęstym lesie 3–5 m. Może też zmienić kolor,
   podejrzeć stan kalibracji i usunąć osobę.
5. Widzi pozycje ludzi na żywo, % przeszukania całości i każdego kwadratu oraz zgłoszenia.

**Uczestnik** (tryb „Uczestnik”, imię + kod dołączenia):
1. **Kalibruj**: staje w punkcie kalibracyjnym i stoi 30 s. Aplikacja uśrednia odczyty
   GPS i zapamiętuje przesunięcie swojego telefonu, a potem poprawia nim każdą pozycję.
   Bez punktu kalibracyjnego sprawdzana jest tylko jakość sygnału.
2. **Szukam**: włącza zapis śladu. Pozycje gorsze niż próg dokładności (domyślnie 25 m) są
   odrzucane. Gdy nie ma zasięgu, punkty czekają w kolejce i wysyłają się później.
3. **Zgłoś**: wybiera kategorię (ślad, przedmiot, osoba, zagrożenie, inne) i opis.
   Zgłoszenie dostaje pozycję telefonu. Żeby wskazać inne miejsce, przytrzymaj palec na mapie.
   Wszyscy dostają powiadomienie, np. „W kwadracie C4 znaleziono ślad”.

## Uwagi

- **Powiadomienia:** w trakcie akcji aplikacja trzyma stałe połączenie z serwerem. Na
  Androidzie działa wtedy usługa pierwszoplanowa (stała notyfikacja „Akcja w toku”), więc
  powiadomienia i zapis śladu działają też przy wygaszonym ekranie. Na webie i Windows
  zgłoszenie pokazuje się jako baner w oknie. Firebase (FCM) nie jest potrzebny, a cały
  system może działać w sieci lokalnej bez internetu.
- **Mapy offline:** kafelki OpenStreetMap wymagają internetu. W terenie bez zasięgu
  przybliż wcześniej obszar akcji, żeby kafelki trafiły do pamięci podręcznej.
- **Kalibracja** usuwa stały błąd danego telefonu w danym miejscu i czasie. Błąd GPS z
  czasem się zmienia, więc warto kalibrować na początku każdej zmiany i po dłuższej przerwie.
- **iOS:** zapis w tle wymaga zgody na lokalizację „Zawsze”. Skrypt `tool/setup.dart`
  dodaje odpowiednie wpisy do `Info.plist`.
- Na produkcyjnym serwerze w internecie postaw go za HTTPS (np. Caddy albo nginx).
