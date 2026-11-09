# WattNu-server

Leest een Eastron SDM630 uit via een USR-DR302 en bewaart de geschiedenis.

```
SDM630 --RS485--> USR-DR302 --Modbus--> Telegraf --> TimescaleDB --> Grafana
```

## Starten

Nodig: een machine met Docker die de DR302 kan bereiken, altijd aan.

1. Maak de instellingen aan en vul het adres en de wachtwoorden in:

   ```
   cp .env.example .env
   ```

2. Test de verbinding. Zet de `MODBUS_MODE` die het script noemt in `.env`:

   ```
   docker compose run --rm check
   ```

3. Start alles:

   ```
   docker compose up -d
   ```

4. Open `http://<machine>:3000` en log in als `admin` met `GRAFANA_ADMIN_PASSWORD`.

Controleer of er metingen binnenkomen:

```
docker compose logs telegraf
docker compose exec timescaledb psql -U energy -c "select * from sdm630 order by time desc limit 1"
```

## Telegrammeldingen instellen

De API kan via een Telegram-bot meldingen versturen voor:

- langer dan één minuut 14 A of meer afname op L1, L2 of L3;
- langer dan één minuut 14 A of meer teruglevering op L1, L2 of L3;
- langer dan één minuut ontbrekende meterdata;
- een per apparaat instelbare dagelijkse kWh-limiet.

De stroomregisters van de SDM630 zijn absolute waarden. De API gebruikt daarom
het teken van `power_l1`, `power_l2` en `power_l3` om afname van teruglevering te
onderscheiden. Een fase-alarm wordt pas opnieuw actief nadat de stroom onder
13 A is geweest.

1. Open [@BotFather](https://t.me/BotFather) in Telegram, stuur `/newbot` en volg
   de stappen. Bewaar het bottoken dat BotFather terugstuurt.
2. Open daarna je nieuwe bot en stuur hem zelf één bericht, bijvoorbeeld `start`.
   Een bot mag niet uit zichzelf een gesprek met je beginnen.
3. Vraag de updates op en zoek in het antwoord naar `message.chat.id`:

   ```
   curl -s "https://api.telegram.org/bot<BOT_TOKEN>/getUpdates"
   ```

4. Vul het token en de gevonden chat-ID in `.env` in:

   ```dotenv
   TELEGRAM_BOT_TOKEN=123456789:AA...
   TELEGRAM_CHAT_ID=123456789
   ```

5. Bouw de API opnieuw op en controleer de logs:

   ```
   docker compose up -d --build api
   docker compose logs -f api
   ```

Voorkeuren en alarmstatussen staan in het Docker-volume `api-data`. Zonder geldig
Telegram-token en chat-ID blijft de meet-API gewoon werken, maar meldt de log dat
Telegrammeldingen uitstaan. De Pi maakt alleen een uitgaande HTTPS-verbinding met
Telegram; er hoeft geen extra poort open.

De WattNu-app voor iPhone, iPad en Mac staat in `WattApp/`.

## Nederlandse netbelasting

De tab **Net** toont de totale Nederlandse elektriciteitsvraag per kwartier voor
de laatste 24 uur, 7 dagen of 30 dagen. De API haalt dit zonder abonnement of
persoonlijk token op bij Energy-Charts en bewaart elk antwoord 15 minuten in het
geheugen. De onderliggende gegevens komen van ENTSO-E/TenneT en vallen onder
CC BY 4.0. Dit staat los van een dynamisch energiecontract en van de eigen meter.

## Instellingen op de meter

De meter moet op **3P4W** staan; anders geeft het N-register 0.
Is het Modbus-adres niet 1, pas dan `slave_id` aan in `telegraf/telegraf.conf`
en `MODBUS_SLAVE` in `.env`.

## Opslag

| Tabel | Inhoud | Bewaartermijn |
|---|---|---|
| `sdm630` | Alle metingen, elke 5 seconden | 90 dagen, gecomprimeerd na 7 dagen |
| `sdm630_1m` | Per minuut: gemiddelden en pieken | Onbeperkt |
| `sdm630_1h` | Per uur, met kWh-tellerstanden | Onbeperkt |
| `energy_hourly` | kWh per klokuur, totaal en per fase | Onbeperkt (view) |

Grafieken kiezen zelf de fijnste bron die bij de gekozen periode past.
Bij stroom zie je de piek per interval, zodat korte pieken niet wegvallen.

## Aanpassen

- **Hoofdzekering:** de drempels in het paneel "Stroom per fase en N" staan op
  20 en 25 A. Pas die aan in `grafana/dashboards/wattnu.json`; Grafana leest het
  bestand vanzelf opnieuw in.
- **Dashboard bewerken in Grafana:** zet `allowUiUpdates: true` in
  `grafana/provisioning/dashboards/wattnu.yml`. Standaard komt het dashboard
  alleen uit het bestand.
- **Bestaande TimescaleDB:** draai `db/init/01-schema.sql` daar, en wijs
  `connection` in `telegraf/telegraf.conf` en de datasource naar die database.

Het schema wordt alleen geladen als de database nog leeg is. Wijzigingen daarna
voer je zelf uit met `psql`.

## N-stroom

Register 30225 komt van de meter zelf. Ik kon niet vaststellen of die waarde
gemeten of berekend is. Vergelijk hem eenmalig met een true-RMS stroomtang op de N,
liefst terwijl er veel leds en voedingen aan staan. Daarbij is de derde harmonische
het grootst, dus daar wijkt een berekende waarde het meest af.

## Beveiliging

Modbus heeft geen authenticatie, dus houd de DR302 op een vertrouwd netwerk.
Telegraf gebruikt alleen leesfuncties. Grafana heeft een eigen databasegebruiker
die niets kan wijzigen. De database heeft geen open poort naar buiten.

Het Telegram-bottoken is een geheim met volledige controle over de bot. Deel of
commit het niet. Is het uitgelekt, trek het dan direct in via BotFather.
