# RXIOM

Gra typu Trading na Roblox wzorowana na [axiom.trade](https://axiom.trade), synchronizowana do Studio przez [Rojo](https://rojo.space).

## Start

1. Zainstaluj [Rokit](https://github.com/rojo-rbx/rokit), potem w katalogu repo: `rokit install`
2. Zainstaluj plugin Rojo w Studio: `rojo plugin install`
3. Uruchom serwer: `rojo serve`, a w Studio kliknij **Connect** w pluginie Rojo.

Zbudowanie pliku miejsca bez Studio: `rojo build -o RXIOM.rbxlx`

Zapis postępu (DataStore) działa w opublikowanej grze. W Studio trzeba włączyć
**Game Settings → Security → Enable Studio Access to API Services**; bez tego gracz dostaje tymczasowy profil, który nie jest zapisywany.

## Jak działa handel

- Każdy coin ma pulę płynności `x * y = k` (jak pump.fun). Kupno dodaje RXI do puli i podnosi cenę, sprzedaż ją obniża.
- Prowizja 1% od transakcji plus wybrany priority fee i tip.
- Serwer wykonuje wszystkie transakcje. Klient wysyła oczekiwany wynik, a serwer odrzuca transakcję, jeśli cena uciekła bardziej niż ustawiony slippage.
- Boty symulują innych traderów, więc ceny, wolumen i wykresy żyją także przy jednym graczu. Przy starcie serwer symuluje ostatnią godzinę historii.
- Zlecenia **Limit** trafiają do księgi zleceń (order book) i czekają, aż zostaną wykonane albo anulowane. **Advanced Trading Strategy** dokłada do kupna take profit i stop loss.
- **Deposit** daje darmowe RXI co 5 minut.
- Przy wejściu gracz loguje się przez portfel **Ghostbox** (wybiera swoje konto Roblox). Przy pierwszym logowaniu dostaje stały adres portfela z 24 znaków, zapisywany w profilu.

Ustawienia ekonomii są w `src/shared/Config.luau`, a lista coinów w `src/shared/Coins.luau` (12 coinów: ROXI, BLOKI, NOOB, RUGB, BLOX, RIXI, STUD, MBLOX, RXT, NBC, PXR, RPRIME, z opisem na stronie coina). Dawne tickery COIN1–COIN8 są przy wczytywaniu zapisu zamieniane na nowe (`Coins.rename`), więc pozycje graczy zostają.

## Księga zleceń (order book)

Każdy coin ma na serwerze księgę zleceń z priorytetem ceny i czasu (`src/server/Services/OrderBook.luau`), połączoną z pulą płynności:

- Każda transakcja rynkowa (gracze, boty, TP/SL) przechodzi przez księgę. Kupno bierze z puli tylko do ceny najlepszego asku, wykonuje ten ask po jego cenie i idzie dalej; sprzedaż analogicznie z bidami. Bidy leżą zawsze poniżej ceny puli, aski powyżej, a taker nigdy nie dostaje gorszej ceny niż z samej puli.
- Zlecenie limit, które krzyżuje się z rynkiem, wykonuje się od razu jako taker (prowizja 1%) do swojej ceny. Reszta czeka w księdze i wykonuje się później jako maker, dokładnie po swojej cenie i bez prowizji.
- Kupno rezerwuje wpisaną kwotę RXI (niewykorzystana część wraca po wykonaniu lub anulowaniu), sprzedaż blokuje tokeny.
- Zlecenia są zapisywane w profilu gracza. Gdy gracz wychodzi, znikają z księgi tego serwera; po ponownym wejściu wracają (i od razu się wykonują, jeśli cena je przekroczyła).
- Strona coina pokazuje księgę obok wykresu. Każdy poziom łączy płynność puli w danym przedziale cen ze zleceniami graczy: cena ($), ilość tokenów, wartość (RXI) i pasek skumulowanej głębokości. Kliknięcie poziomu wpisuje jego cenę do zakładki Limit.

Limity: 20 otwartych zleceń limit na gracza, cena najwyżej 100× od ceny rynkowej.

## Pulse (coiny graczy)

Zakładka **Pulse** pokazuje coiny tworzone przez graczy w trzech kolumnach: **New Pairs**, **Final Stretch** (od 50% bonding curve) i **Migrated**. Logika jest w `src/server/Services/Launchpad.luau`, ustawienia w `Config.Launch`.

- **Create coin**: nazwa (2–24 znaki), ticker (2–8 znaków A–Z/0–9, unikalny), kolor i opcjonalny dev buy. Stworzenie coina kosztuje 100 RXI (`Config.Launch.Fee`, opłata jest spalana), jeden coin na minutę na gracza. Nazwa i ticker przechodzą przez filtr tekstu Robloxa.
- Coin startuje z małą wirtualną pulą ($4K market cap) i migruje na stałe po osiągnięciu $40K. Boty handlują coinami z Pulse z losowym „hype’em”, więc część z nich pompuje aż do migracji, a część umiera.
- Definicje coinów i stan ich pul są zapisywane we wspólnym rejestrze w DataStore (`RXIOM_Launches_v1`), więc coiny i pozycje w nich przeżywają restart i są widoczne na innych serwerach. Każdy serwer prowadzi własny rynek i co minutę zapisuje pule; migracja jest trwała wszędzie.
- Serwer trzyma na rynku naraz do 24 coinów z Pulse (najnowsze i najaktywniejsze) plus te, w których gracze na serwerze mają pozycje lub zlecenia. Najsłabsze starsze coiny bez udziału graczy schodzą z rynku, ale zostają w rejestrze.
- W Studio bez dostępu do API coiny z Pulse działają tylko w bieżącej sesji.

## Wallet Tracker

Zakładka **Trackers** (`src/server/Services/Tracker.luau`, statystyki w `Stats.luau`):

- Wyszukiwanie po nazwie Roblox, nazwie wyświetlanej albo adresie portfela Ghostbox. Profil pokazuje wartość portfela, zrealizowany PnL (metodą średniego kosztu), wolumen, liczbę transakcji, ulubione tokeny i miejsce w rankingu.
- Ranking po zrealizowanym PnL (top 100, w tabeli 25 najlepszych). Trafiają do niego tylko publiczne profile z zyskiem.
- **Prywatność**: każdy profil jest domyślnie prywatny i gracz sam go upublicznia przełącznikiem w „Your profile”. Prywatny profil nie pokazuje żadnych liczb ani adresu portfela, nie da się go znaleźć po adresie, nie ma go w rankingu, a w listach transakcji gracz widnieje pod anonimowym adresem. Saldo i pozycje nigdy nie są publikowane osobno, tylko łączna wartość portfela.
- Publiczne dane są zapisywane w DataStore (`RXIOM_Public_v1`, ranking w OrderedDataStore `RXIOM_Leaderboard_v1`) co minutę i przy wyjściu, żeby było je widać, gdy gracz jest offline. Przejście na prywatny od razu je usuwa.

## Samouczek

Po pierwszym zalogowaniu (`UI/Tutorial.luau`) strona Discover się przyciemnia, a „reflektor” przesuwa się po kolejnych elementach: saldo, Deposit, lista cen, Quick Buy, Top Movers, Pulse, Trackers, Perpetuals, Send, Portfolio. Obok jest karta z opisem, kropkami postępu i przyciskami Back / Next / Skip (działają też strzałki, Enter i Esc). Na początku kręci się moneta RXI, na końcu leci konfetti. Obejrzenie zapisuje się w profilu (`TutorialDone`), więc samouczek pokazuje się raz; przycisk **?** na górnym pasku włącza go ponownie. Teksty kroków są w `STEPS` na górze pliku.

## Upgrades

Zakładka **Upgrades** (`src/shared/Upgrades.luau` z cenami i efektami, strona `MainMenu/UpgradesPage.luau`): stałe ulepszenia za RXI, zapisywane w profilu.

| Ulepszenie | Efekt (bez → max) | Ceny kolejnych poziomów |
|---|---|---|
| Bigger Deposit | 1 → 5 RXI za Deposit | 10, 25, 60, 150, 400 |
| Faster Deposit | 5 min → 1 min | 15, 40, 100, 250, 600 |
| Fee Cashback | 0 → 60% prowizji wraca po transakcji | 20, 60, 150, 400 |
| Cheaper Launch | 100 → 40 RXI za coina | 50, 120, 300, 700 |
| Pulse Radar | baner z przyciskiem Buy przy każdym nowym coinie na Pulse | 75 (jednorazowo) |

## Boty-snajperzy

Na 85% nowych coinów z Pulse rzuca się 2–5 botów `sniper_xxxx` (`src/server/Services/Snipers.luau`, ustawienia w `Config.Snipers`): pierwszy kupuje 1.5–4 s po starcie (dev buy zwykle zdąży przed nimi), każdy za 3–8% RXI z puli, więc cena skacze. Potem sprzedają według stylu: Flipper (wszystko przy +30–80% albo po 15–45 s), Swing (połowa przy +60–150% albo po 40–90 s, reszta po 2–4 min), Holder (wszystko po 3–7 min). Twórca dostaje ostrzeżenie, a w liście transakcji snajperzy są na żółto.

## Alerty cenowe

Dzwonek na stronie coina otwiera okno alertu (`MainMenu/AlertDialog.luau`, serwer w `src/server/Services/Alerts.luau`): market cap powyżej / poniżej kwoty (np. `200K`, `1.5M`) albo wzrost / spadek o X % od chwili ustawienia. Serwer sprawdza alerty co sekundę; alert, który zadziała, znika, a gracz dostaje baner z dźwiękiem na górze ekranu na każdej zakładce (kliknięcie otwiera coina). Alerty są zapisywane w profilu, do 20 na gracza (`Config.MaxAlerts`).

## Perpetuals

Zakładka **Perpetuals** (`src/server/Services/Perps.luau`, silnik w `PerpEngine.luau`, ceny w `PerpOracle.luau`, strona w `MainMenu/PerpsPage.luau`, ustawienia w `Config.Perps`):

- Rynki GHST (Ghost, duszek Ghostbox), OBBY (Obby) i BACON (Bacon Hair) z dźwignią (do 40x / 25x / 20x), Long i Short, zlecenia Market i Limit, TP/SL, izolowany margin w RXI. Prowizja 0.045% (market) / 0.015% (limit) od wartości pozycji, funding co godzinę.
- Ceny są symulowane: to deterministyczna funkcja czasu serwera (kilka skal szumu, ok. 2.5–4% zmienności dziennie), więc każdy serwer widzi tę samą cenę, a przeskakiwanie między serwerami nic nie daje. Funkcja jest tylko na serwerze, klient dostaje ceny co sekundę.
- Zlecenia limit, TP/SL, funding i likwidacje są rozliczane co sekundę, a po powrocie gracza także za czas, kiedy był offline (na próbkach ceny co kilka sekund).
- Pozycje są zapisywane w profilu, wliczają się do wartości portfela, a wynik do zrealizowanego PnL i rankingu w Trackerze.
- Księga zleceń i część listy transakcji są poglądowe (generowane wokół ceny); prawdziwe transakcje graczy też trafiają na listę.

## Przelewy RXI

Przycisk **Send** obok Deposit (`src/server/Services/Transfer.luau`, okno w `MainMenu/SendPanel.luau`, animacja w `UI/CoinBurst.luau`):

- Odbiorca po nazwie użytkownika Roblox, nazwie wyświetlanej gracza na serwerze albo adresie portfela Ghostbox; podgląd odbiorcy na żywo. Po samym adresie prywatnego portfela nie widać, czyj jest. Bez opłat, minimum jak przy handlu.
- Przelew trafia do skrzynki odbiorcy w DataStore (`RXIOM_Inbox_v1`) i jest księgowany od razu (ten sam serwer), po powiadomieniu MessagingService (inny serwer) albo przy następnym wejściu. Adresy portfeli są indeksowane w `RXIOM_Wallets_v1`. Zaksięgowane ID przelewów są w profilu, więc nic nie jest liczone dwa razy.
- Po wysłaniu i po otrzymaniu na środku ekranu kręci się moneta RXI (grafika `126450260339769`) z kwotą i nadawcą/odbiorcą.
- W Studio bez dostępu do API przelewy działają tylko między graczami na tym samym serwerze (np. **Test → Clients and Servers**, 2 graczy).
- Przelew do siebie (własny nick albo adres) to podgląd: pokazuje animację „Sent”, a po niej „Received”, ale saldo się nie zmienia.

## Struktura

| Folder                    | Trafia do                                   | Co zawiera                                       |
| ------------------------- | ------------------------------------------- | ------------------------------------------------ |
| `src/server`              | `ServerScriptService.Server`                | rynek, boty, dane graczy, obsługa transakcji     |
| `src/client/State`        | `StarterPlayerScripts.Client.State`         | stan rynku i portfela po stronie klienta, akcje  |
| `src/client/UI`           | `StarterPlayerScripts.Client.UI`            | interfejs: Discover, strona coina, Portfolio     |
| `src/shared`              | `ReplicatedStorage.Shared`                  | konfiguracja, coiny, matematyka puli, typy       |
