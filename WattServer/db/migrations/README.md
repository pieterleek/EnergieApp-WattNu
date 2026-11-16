# Migraties

`db/init/` maakt het basisschema, maar alleen bij de allereerste start van een
lege database. Elke latere schemawijziging hoort hier, als genummerd bestand:

```
001_korte_omschrijving.sql
002_volgende_wijziging.sql
```

De `migrate`-service voert bij elke `docker compose up` de bestanden uit die nog
niet in de tabel `schema_migrations` staan, op naam gesorteerd, elk in één
transactie. Een toegepast bestand wijzig je daarna niet meer; maak een nieuw
bestand.

Sommige TimescaleDB-opdrachten (zoals een continuous aggregate aanmaken) mogen
niet in een transactie. Zet dan `-- migrate: no-transaction` op de eerste regel
en houd het bestand bij één opdracht.

Schrijf migraties zo dat ze ook kloppen op een verse installatie: daar draait
eerst `db/init/` en daarna deze map.
