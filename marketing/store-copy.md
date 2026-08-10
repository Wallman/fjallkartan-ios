# App Store copy

Everything here is entered per locale in App Store Connect. Apple's limit is
**30 characters** for both the app name and the subtitle; the counts below are
the current length of each line.

Screenshot captions for the same locales live in `COPY` in
`tools/compose_screenshots.py`.

## Support URL

App Store Connect requires one, and it must be a reachable page (not a bare
`mailto:`). The page lives in this repo at `docs/support.html`:

    https://wallman.github.io/fjallkartan-ios/support.html

It carries the contact address `fjallkartan@wallman.dev` plus an FAQ covering
offline downloads, measuring, blank tiles and privacy — enough that App Review
sees a real support page rather than a stub.

## Privacy policy URL

App Store Connect requires one. The page lives in this repo at
`docs/privacy.html`:

    https://wallman.github.io/fjallkartan-ios/privacy.html

To publish both: repository **Settings → Pages → Source: Deploy from a branch →
`main` / `/docs`**.

The policy states that the app collects nothing, which is checked against the
code: no third-party SDKs, no analytics, no accounts, no purchases, and location
used only on-device. It does disclose that Kartverket and Lantmäteriet see the
device IP address when tiles are fetched, since that is unavoidable and true.

In the separate **App Privacy** questionnaire, answer **"Data Not Collected"**.

## App name

| Locale | Name | Chars |
| --- | --- | --- |
| en | Fjällkartan – Nordics | 21 |
| sv | Fjällkartan – Norden | 20 |
| nb | Fjellkartet – Norden | 20 |
| da | Fjeldkortet – Norden | 20 |
| fi | Tunturikartta – Pohjoismaat | 27 |
| de | Fjällkartan – Nordeuropa | 24 |
| nl | Fjällkartan – Noord-Europa | 26 |
| fr | Fjällkartan – Pays nordiques | 28 |
| it | Fjällkartan – Paesi nordici | 27 |
| es | Fjällkartan – Países nórdicos | 29 |
| zh-Hans | Fjällkartan – 北欧 | 16 |

*Fjällkartan* is translated only into the languages that have a native word for
a fell — Norwegian, Danish and Finnish — where the Swedish spelling would read
as a foreign word rather than as a description:

- **nb** *Fjellkartet* — Norwegian *fjell* + *kart*, definite neuter.
- **da** *Fjeldkortet* — Danish uses *fjeld* for Nordic mountains and *kort*,
  not *karta*, for a map.
- **fi** *Tunturikartta* — *tunturi* is the Finnish fell, the exact landform the
  app covers. Finnish has no definite article.

Every other language keeps *Fjällkartan* as an untranslated brand name; in
German, Dutch, Romance languages and Chinese there is no equivalent everyday
word, and a literal "mountain map" would lose the specific Nordic sense.

The **home-screen name** is set separately, in `fjallkartan/InfoPlist.xcstrings`
(`CFBundleDisplayName`), and must be kept in step with the brand half of the
table above. It carries no region descriptor — there is no room for one — so it
is just *Fjällkartan* / *Fjellkartet* / *Fjeldkortet* / *Tunturikartta*.

The same file localizes `NSLocationWhenInUseUsageDescription`, the text of the
location permission prompt. The base value in the build settings is the English
source string and acts as the fallback for any locale not listed there.

The region descriptor is deliberately **the Nordics, not Scandinavia**, because
Finland is planned. Scandinavia would exclude it and would have to be renamed
later, and an App Store name change costs a review cycle.

- **Nordic languages** use *Norden*. Finnish has no cognate, so it uses
  *Pohjoismaat*, the standard Finnish term for the Nordic countries.
- **German** is the trap: *Norden* there means the compass direction, so it uses
  *Nordeuropa*. *Nordische Länder* is exactly 30 characters — correct, but with
  no headroom.
- **Romance languages** use the *pays/paesi/países nordiques/nordici/nórdicos*
  form, which names the Nordic countries specifically rather than the geographic
  north.
- **zh-Hans** keeps 北欧, which already denotes the Nordic region including
  Finland.

## Subtitle

The subtitle deliberately avoids the word "fjällkarta" and its translations,
since it sits directly beneath the app name *Fjällkartan* and Apple discourages
repeating the name.

| Locale | Subtitle | Chars |
| --- | --- | --- |
| en | Topographic maps, offline | 25 |
| sv | Topografiska kartor offline | 27 |
| nb | Topografiske kart offline | 25 |
| da | Topografiske kort offline | 25 |
| fi | Topografiset kartat offline | 27 |
| de | Topografische Karten offline | 28 |
| nl | Topografische kaarten offline | 29 |
| fr | Cartes topo, hors ligne | 23 |
| it | Mappe topografiche offline | 26 |
| es | Mapas topográficos offline | 26 |
| zh-Hans | 官方地形图，可离线使用 | 11 |

Two lines are not literal translations:

- **fr** — "Cartes topographiques hors ligne" is 32 characters. *Topo* is the
  ordinary French shorthand among hikers, and *hors ligne* reads far better in
  the French store than the English *offline*.
- **zh-Hans** — "official topographic maps, usable offline". Chinese has
  characters to spare, so it adds the provenance rather than padding.

## Promotional text

Up to **170 characters**, shown above the description. This is the only
field that can be changed without submitting a new build for review, so keep
seasonal or time-sensitive lines here rather than in the description.

The Nordic locales name **Kartverket** and **Lantmäteriet** outright, because
there the agencies are recognised institutions and saying so is the strongest
credibility signal available. Everywhere else those names mean nothing to the
reader, so the line leads with *official Swedish and Norwegian maps* instead.
The agencies are still credited in the body of every description.

| Locale | Promotional text | Chars |
| --- | --- | --- |
| en | Official Swedish and Norwegian maps in one app. Download the areas you need before you leave, and keep reading the terrain where there is no signal. | 148 |
| sv | Kartverkets och Lantmäteriets kartor i en och samma app. Ladda ner områdena du behöver innan du åker och läs terrängen även utan täckning. | 138 |
| nb | Kartene fra Kartverket og Lantmäteriet i én app. Last ned områdene du trenger før du drar, og les terrenget der det ikke er dekning. | 132 |
| da | Kort fra Kartverket og Lantmäteriet i én app. Hent de områder, du skal bruge, før du tager af sted, og læs terrænet uden dækning. | 129 |
| fi | Kartverketin ja Lantmäterietin kartat yhdessä sovelluksessa. Lataa tarvitsemasi alueet ennen lähtöä ja lue maastoa ilman kuuluvuutta. | 133 |
| de | Amtliche schwedische und norwegische Karten in einer App. Lade die Gebiete vor der Tour herunter und lies das Gelände auch ohne Empfang. | 136 |
| nl | Officiële Zweedse en Noorse kaarten in één app. Download de gebieden die je nodig hebt voor vertrek en lees het terrein zonder bereik. | 134 |
| fr | Les cartes officielles suédoises et norvégiennes dans une seule app. Téléchargez les zones utiles avant de partir et lisez le terrain sans réseau. | 146 |
| it | Le mappe ufficiali svedesi e norvegesi in un'unica app. Scarica le aree che ti servono prima di partire e leggi il terreno anche senza campo. | 141 |
| es | Los mapas oficiales suecos y noruegos en una sola app. Descarga las zonas que necesites antes de salir y lee el terreno sin cobertura. | 134 |
| zh-Hans | 瑞典与挪威的官方地图，尽在一个应用中。出发前下载所需区域，在没有信号的地方依然能读懂地形。 | 45 |

## Keywords

**100 characters** per locale, comma-separated. No space after the commas —
a space costs a character and buys nothing. Apple already indexes the app
name and the subtitle, so nothing from those is repeated here.

| Locale | Keywords | Chars |
| --- | --- | --- |
| en | `hiking,trail,fell,gps,trekking,norway,sweden,outdoor,route,cabin,ski,terrain,tour` | 81 |
| sv | `vandring,led,fjäll,gps,tur,friluftsliv,skidtur,terräng,stuga,kompass,natur,turkarta` | 83 |
| nb | `fottur,tur,fjell,gps,friluftsliv,sti,hytte,terreng,ski,turkart,natur,jakt,merket` | 80 |
| da | `vandring,fjeld,tur,gps,friluftsliv,sti,hytte,terræn,ski,natur,bjerg,vandrekort` | 78 |
| fi | `vaellus,retki,tunturi,gps,polku,maasto,kämppä,hiihto,luonto,erä,retkeily,reitti` | 79 |
| de | `wandern,wanderkarte,tour,gps,outdoor,skitour,norwegen,schweden,trekking,hütte,natur` | 83 |
| nl | `wandelen,wandelkaart,gps,outdoor,trekking,noorwegen,zweden,hut,natuur,route,berg` | 80 |
| fr | `randonnée,rando,gps,montagne,trek,norvège,suède,refuge,sentier,ski,nature,relief` | 80 |
| it | `escursionismo,trekking,gps,montagna,norvegia,svezia,rifugio,sentiero,sci,natura` | 79 |
| es | `senderismo,trekking,gps,montaña,noruega,suecia,refugio,sendero,esquí,naturaleza` | 79 |
| zh-Hans | `徒步,登山,户外,越野滑雪,挪威,瑞典,导航,离线地图,等高线,山峰,徒步旅行,野外` | 42 |

## Description

Limit is **4000 characters**; these run to roughly a quarter of that, which
is deliberate — only the first two lines are visible before the *more* link.

The claims here are checked against the app: there is no account, no sign-up,
no purchase and no analytics, and location is requested as when-in-use only.
The 1.6 million figure is the row count of the bundled `places.sqlite`.

### en (928 characters)

```
Fjällkartan puts the official topographic maps of Norway and Sweden side by side in one app, stitched together across the border so your route never stops at the national boundary.

The cartography comes straight from Kartverket and Lantmäteriet — the same maps you would otherwise carry on paper, with contour lines, marked trails, cabins, bridges and winter routes.

WORKS OFFLINE
Download an area before you leave and carry the whole map on your phone. No coverage required.

MEASURE A ROUTE
Trace a line with your finger and read its length. Distances are geodesic, so they stay accurate this far north, where a flat map would overstate them.

SEARCH 1.6 MILLION PLACES
Every Swedish and Norwegian place name, searchable without a connection. Find a peak, a lake or a cabin by name and go straight to it.

No account, no sign-up, no tracking. Your location never leaves your phone.

Map data © Kartverket and © Lantmäteriet.
```

### sv (901 characters)

```
Fjällkartan lägger Norges och Sveriges officiella topografiska kartor sida vid sida i en app, sammanfogade över gränsen så att din tur aldrig tar slut vid riksröset.

Kartorna kommer direkt från Kartverket och Lantmäteriet — samma kartografi som du annars bär med dig på papper, med höjdkurvor, markerade leder, stugor, broar och vinterleder.

FUNGERAR OFFLINE
Ladda ner ett område innan du åker och bär hela kartan i telefonen. Ingen täckning behövs.

MÄT EN RUTT
Dra ett streck med fingret och läs av längden. Avstånden är geodetiska och stämmer därför så här långt norrut, där en platt karta annars överdriver dem.

SÖK BLAND 1,6 MILJONER PLATSER
Alla svenska och norska ortnamn, sökbara utan uppkoppling. Hitta en topp, en sjö eller en stuga på namn och åk rakt dit.

Inget konto, ingen registrering, ingen spårning. Din position lämnar aldrig telefonen.

Kartdata © Kartverket och © Lantmäteriet.
```

### nb (862 characters)

```
Fjellkartet legger Norges og Sveriges offisielle topografiske kart side om side i én app, sydd sammen over grensen slik at turen aldri stopper ved riksgrensen.

Kartene kommer rett fra Kartverket og Lantmäteriet — samme kartografi som du ellers bærer med deg på papir, med høydekurver, merkede stier, hytter, broer og vinterruter.

VIRKER OFFLINE
Last ned et område før du drar, og ha hele kartet i lomma. Ingen dekning nødvendig.

MÅL EN RUTE
Dra en strek med fingeren og les av lengden. Avstandene er geodetiske og stemmer derfor så langt nord, der et flatt kart ellers overdriver dem.

SØK I 1,6 MILLIONER STEDER
Alle svenske og norske stedsnavn, søkbare uten nett. Finn en topp, et vann eller en hytte på navn og dra rett dit.

Ingen konto, ingen registrering, ingen sporing. Posisjonen din forlater aldri telefonen.

Kartdata © Kartverket og © Lantmäteriet.
```

### da (882 characters)

```
Fjeldkortet lægger Norges og Sveriges officielle topografiske kort side om side i én app, syet sammen over grænsen, så turen aldrig stopper ved landegrænsen.

Kortene kommer direkte fra Kartverket og Lantmäteriet — samme kartografi, som du ellers har med på papir, med højdekurver, afmærkede stier, hytter, broer og vinterruter.

VIRKER OFFLINE
Hent et område, før du tager af sted, og hav hele kortet i lommen. Der kræves ingen dækning.

MÅL EN RUTE
Træk en streg med fingeren, og aflæs længden. Afstandene er geodætiske og holder derfor så langt mod nord, hvor et fladt kort ellers overdriver dem.

SØG I 1,6 MILLIONER STEDER
Alle svenske og norske stednavne, søgbare uden forbindelse. Find en top, en sø eller en hytte på navn, og tag direkte derhen.

Ingen konto, ingen oprettelse, ingen sporing. Din position forlader aldrig telefonen.

Kortdata © Kartverket og © Lantmäteriet.
```

### fi (927 characters)

```
Tunturikartta tuo Norjan ja Ruotsin viralliset topografiset kartat samaan sovellukseen, saumattomasti yhteen liitettyinä, joten reitti ei katkea valtakunnan rajalle.

Kartat tulevat suoraan Kartverketiltä ja Lantmäterietiltä — samaa kartografiaa kuin paperikartassa, korkeuskäyrineen, merkittyine polkuineen, kämppineen, siltoineen ja talvireitteineen.

TOIMII ILMAN VERKKOA
Lataa alue ennen lähtöä ja kanna koko kartta puhelimessasi. Kuuluvuutta ei tarvita.

MITTAA REITTI
Vedä viiva sormella ja lue sen pituus. Etäisyydet ovat geodeettisia ja pitävät siksi paikkansa näinkin pohjoisessa, missä tasokartta liioittelisi niitä.

HAE 1,6 MILJOONASTA PAIKASTA
Kaikki ruotsalaiset ja norjalaiset paikannimet, haettavissa ilman yhteyttä. Etsi huippu, järvi tai kämppä nimellä ja siirry suoraan sinne.

Ei tiliä, ei rekisteröitymistä, ei seurantaa. Sijaintisi ei poistu puhelimestasi.

Kartta-aineisto © Kartverket ja © Lantmäteriet.
```

### de (985 characters)

```
Fjällkartan bringt die amtlichen topografischen Karten Norwegens und Schwedens in eine App und fügt sie über die Grenze hinweg zusammen, damit deine Tour nicht an der Landesgrenze endet.

Die Kartografie stammt direkt von Kartverket und Lantmäteriet — dieselben Karten, die du sonst auf Papier dabeihättest, mit Höhenlinien, markierten Wegen, Hütten, Brücken und Winterrouten.

FUNKTIONIERT OFFLINE
Lade ein Gebiet vor dem Aufbruch herunter und trage die ganze Karte im Telefon. Kein Empfang nötig.

ROUTE MESSEN
Zieh mit dem Finger eine Linie und lies ihre Länge ab. Die Entfernungen sind geodätisch und stimmen daher auch hoch im Norden, wo eine flache Karte sie überschätzen würde.

1,6 MILLIONEN ORTE SUCHEN
Alle schwedischen und norwegischen Ortsnamen, auch ohne Verbindung durchsuchbar. Finde einen Gipfel, einen See oder eine Hütte über den Namen.

Kein Konto, keine Anmeldung, kein Tracking. Dein Standort verlässt das Telefon nie.

Kartendaten © Kartverket und © Lantmäteriet.
```

### nl (960 characters)

```
Fjällkartan legt de officiële topografische kaarten van Noorwegen en Zweden naast elkaar in één app, naadloos aan elkaar gezet over de grens heen, zodat je route niet stopt bij de landsgrens.

De cartografie komt rechtstreeks van Kartverket en Lantmäteriet — dezelfde kaarten die je anders op papier meeneemt, met hoogtelijnen, gemarkeerde paden, hutten, bruggen en winterroutes.

WERKT OFFLINE
Download een gebied voor vertrek en draag de hele kaart in je telefoon. Bereik is niet nodig.

METEN
Trek met je vinger een lijn en lees de lengte af. De afstanden zijn geodetisch en kloppen daardoor ook hoog in het noorden, waar een platte kaart ze zou overdrijven.

ZOEK IN 1,6 MILJOEN PLAATSEN
Alle Zweedse en Noorse plaatsnamen, ook zonder verbinding doorzoekbaar. Zoek een top, een meer of een hut op naam en ga er direct heen.

Geen account, geen registratie, geen tracking. Je locatie verlaat je telefoon nooit.

Kaartgegevens © Kartverket en © Lantmäteriet.
```

### fr (1023 characters)

```
Fjällkartan réunit dans une seule app les cartes topographiques officielles de la Norvège et de la Suède, assemblées par-delà la frontière pour que votre itinéraire ne s'arrête pas à la limite des pays.

La cartographie provient directement de Kartverket et de Lantmäteriet — les mêmes cartes que vous emporteriez sur papier, avec courbes de niveau, sentiers balisés, refuges, ponts et itinéraires d'hiver.

FONCTIONNE HORS LIGNE
Téléchargez une zone avant de partir et gardez toute la carte dans votre téléphone. Aucune couverture requise.

MESURER UN ITINÉRAIRE
Tracez une ligne du doigt et lisez sa longueur. Les distances sont géodésiques : elles restent justes à ces latitudes, où une carte plane les surestimerait.

1,6 MILLION DE LIEUX
Tous les noms de lieux suédois et norvégiens, consultables sans connexion. Trouvez un sommet, un lac ou un refuge par son nom.

Pas de compte, pas d'inscription, pas de pistage. Votre position ne quitte jamais le téléphone.

Données cartographiques © Kartverket et © Lantmäteriet.
```

### it (978 characters)

```
Fjällkartan riunisce in un'unica app le mappe topografiche ufficiali di Norvegia e Svezia, unite oltre il confine perché il tuo percorso non si fermi alla frontiera.

La cartografia arriva direttamente da Kartverket e Lantmäteriet — le stesse mappe che porteresti su carta, con curve di livello, sentieri segnalati, rifugi, ponti e itinerari invernali.

FUNZIONA OFFLINE
Scarica un'area prima di partire e porta l'intera mappa nel telefono. Non serve copertura.

MISURA UN PERCORSO
Traccia una linea con il dito e leggine la lunghezza. Le distanze sono geodetiche e restano quindi corrette a queste latitudini, dove una mappa piana le sovrastimerebbe.

CERCA TRA 1,6 MILIONI DI LUOGHI
Tutti i toponimi svedesi e norvegesi, consultabili senza connessione. Trova una cima, un lago o un rifugio per nome e raggiungilo subito.

Nessun account, nessuna registrazione, nessun tracciamento. La tua posizione non lascia mai il telefono.

Dati cartografici © Kartverket e © Lantmäteriet.
```

### es (974 characters)

```
Fjällkartan reúne en una sola app los mapas topográficos oficiales de Noruega y Suecia, unidos a través de la frontera para que tu ruta no se detenga en el límite entre países.

La cartografía procede directamente de Kartverket y Lantmäteriet — los mismos mapas que llevarías en papel, con curvas de nivel, senderos señalizados, refugios, puentes y rutas de invierno.

FUNCIONA SIN CONEXIÓN
Descarga una zona antes de salir y lleva el mapa completo en el teléfono. No hace falta cobertura.

MIDE UNA RUTA
Traza una línea con el dedo y lee su longitud. Las distancias son geodésicas, así que siguen siendo exactas en estas latitudes, donde un mapa plano las exageraría.

BUSCA ENTRE 1,6 MILLONES DE LUGARES
Todos los topónimos suecos y noruegos, disponibles sin conexión. Encuentra una cima, un lago o un refugio por su nombre y ve directo a él.

Sin cuenta, sin registro, sin rastreo. Tu ubicación nunca sale del teléfono.

Datos cartográficos © Kartverket y © Lantmäteriet.
```

### zh-Hans (345 characters)

```
Fjällkartan 将挪威与瑞典的官方地形图汇于一个应用，并在国界处无缝拼接，让你的路线不会止步于边境线。

地图数据直接来自 Kartverket 与 Lantmäteriet——与纸质地图相同的制图，包含等高线、标记步道、山间小屋、桥梁和冬季路线。

离线可用
出发前下载所需区域，把整张地图装进手机。无需网络覆盖。

测量路线
用手指划出一条线，即可读出长度。距离基于大地线计算，因此在高纬度地区依然准确——平面地图在这里会高估距离。

搜索 160 万个地点
所有瑞典与挪威地名，无需联网即可搜索。按名称查找山峰、湖泊或小屋，直接前往。

无需账户，无需注册，不做任何追踪。你的位置信息永远不会离开手机。

地图数据 © Kartverket 与 © Lantmäteriet。
```
