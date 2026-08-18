#!/usr/bin/env python3
"""Fill in the legend translations in fjallkartan/Localizable.xcstrings.

Xcode's build extracts the new keys but leaves them empty. Doing this from a
table in one place, rather than by hand in the string catalog editor, keeps the
43 symbol names consistent with each other -- "wind shelter" and "lean-to
shelter" have to stay distinguishable in every language, and several of these
terms recur across the Swedish and Norwegian lists.

Run after a build has extracted the keys:
    python3 tools/fill_legend_translations.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "fjallkartan" / "Localizable.xcstrings"
LANGUAGES = ["da", "de", "es", "fi", "fr", "it", "nb", "nl", "sv", "zh-Hans"]

# Purely numeric labels. Marking them untranslatable stops Xcode from listing
# them as missing work forever.
NOT_TRANSLATED = ["30–35°", "35–40°", "40–45°", "45–50°"]

# key -> (da, de, es, fi, fr, it, nb, nl, sv, zh-Hans)
TRANSLATIONS: dict[str, tuple[str, ...]] = {
    # --- Section headers and chrome ---
    "Trails and routes": (
        "Stier og ruter", "Wege und Routen", "Senderos y rutas", "Polut ja reitit",
        "Sentiers et itinéraires", "Sentieri e percorsi", "Stier og ruter",
        "Paden en routes", "Leder och stigar", "步道与路线",
    ),
    "Cabins and shelter": (
        "Hytter og læ", "Hütten und Schutz", "Cabañas y refugios", "Tuvat ja suojat",
        "Cabanes et abris", "Rifugi e ripari", "Hytter og ly",
        "Hutten en schuilplaatsen", "Stugor och skydd", "小屋与庇护所",
    ),
    "Facilities and crossings": (
        "Faciliteter og overgange", "Einrichtungen und Übergänge", "Servicios y pasos",
        "Palvelut ja ylitykset", "Équipements et passages", "Servizi e attraversamenti",
        "Fasiliteter og kryssinger", "Voorzieningen en oversteken",
        "Anläggningar och passager", "设施与渡口",
    ),
    "Fences and restrictions": (
        "Hegn og restriktioner", "Zäune und Beschränkungen", "Vallas y restricciones",
        "Aidat ja rajoitukset", "Clôtures et restrictions", "Recinzioni e divieti",
        "Gjerder og restriksjoner", "Hekken en beperkingen",
        "Stängsel och restriktioner", "围栏与限制",
    ),
    "Steepness": (
        "Stejlhed", "Steilheit", "Pendiente", "Jyrkkyys", "Pente", "Pendenza",
        "Bratthet", "Steilheid", "Branthet", "坡度",
    ),
    "Find a symbol": (
        "Find et symbol", "Symbol suchen", "Buscar un símbolo", "Etsi symbolia",
        "Rechercher un symbole", "Cerca un simbolo", "Finn et symbol",
        "Zoek een symbool", "Sök symbol", "查找图例",
    ),
    # --- Steepness ---
    "50° and steeper": (
        "50° og stejlere", "50° und steiler", "50° o más", "50° tai jyrkempi",
        "50° et plus", "50° e oltre", "50° og brattere", "50° en steiler",
        "50° och brantare", "50° 及以上",
    ),
    "Modelled avalanche runout": (
        "Modelleret lavineudløb", "Modellierter Lawinenauslauf",
        "Zona de alcance de aludes modelada", "Mallinnettu lumivyöryn valuma-alue",
        "Zone d’arrêt d’avalanche modélisée", "Zona di arresto valanghe modellata",
        "Modellert utløpsområde for skred", "Gemodelleerd lawine-uitloopgebied",
        "Modellerat lavinutlopp", "模拟雪崩堆积区",
    ),
    # --- Sweden: trails ---
    "Marked hiking trail": (
        "Markeret vandrerute", "Markierter Wanderweg", "Sendero señalizado",
        "Merkitty vaellusreitti", "Sentier de randonnée balisé",
        "Sentiero escursionistico segnalato", "Merket vandrerute",
        "Gemarkeerde wandelroute", "Markerad vandringsled", "有标记的徒步道",
    ),
    "Marked summer and winter trail": (
        "Markeret sommer- og vinterrute", "Markierter Sommer- und Winterweg",
        "Ruta señalizada de verano e invierno", "Merkitty kesä- ja talvireitti",
        "Itinéraire balisé d’été et d’hiver", "Percorso segnalato estivo e invernale",
        "Merket sommer- og vinterrute", "Gemarkeerde zomer- en winterroute",
        "Markerad sommar- och vinterled", "有标记的夏冬两季路线",
    ),
    "Marked winter trail": (
        "Markeret vinterrute", "Markierter Winterweg", "Ruta señalizada de invierno",
        "Merkitty talvireitti", "Itinéraire hivernal balisé",
        "Percorso invernale segnalato", "Merket vinterrute", "Gemarkeerde winterroute",
        "Markerad vinterled", "有标记的冬季路线",
    ),
    "Marked summer trail": (
        "Markeret sommerrute", "Markierter Sommerweg", "Ruta señalizada de verano",
        "Merkitty kesäreitti", "Itinéraire estival balisé", "Percorso estivo segnalato",
        "Merket sommerrute", "Gemarkeerde zomerroute", "Markerad sommarled",
        "有标记的夏季路线",
    ),
    "Recommended route, unmarked": (
        "Anbefalet rute, umarkeret", "Empfohlene Route, unmarkiert",
        "Ruta recomendada, sin señalizar", "Suositeltu reitti, merkitsemätön",
        "Itinéraire recommandé, non balisé", "Percorso consigliato, non segnalato",
        "Anbefalt rute, umerket", "Aanbevolen route, ongemarkeerd",
        "Lämplig färdväg, omarkerad", "推荐路线（无标记）",
    ),
    "Path that is hard to follow": (
        "Sti, der er svær at følge", "Schwer erkennbarer Pfad",
        "Sendero difícil de seguir", "Vaikeasti seurattava polku",
        "Sentier difficile à suivre", "Sentiero difficile da seguire",
        "Sti som er vanskelig å følge", "Moeilijk te volgen pad",
        "Svårorienterad gångstig", "难以辨认的小径",
    ),
    "Ski track": (
        "Skispor", "Loipe", "Pista de esquí de fondo", "Latu", "Piste de ski de fond",
        "Pista da sci di fondo", "Skispor", "Langlaufloipe", "Skidspår", "越野滑雪道",
    ),
    "Snowmobile route": (
        "Snescooterrute", "Schneemobilroute", "Ruta para motos de nieve",
        "Moottorikelkkareitti", "Itinéraire de motoneige", "Percorso per motoslitte",
        "Snøscooterløype", "Sneeuwscooterroute", "Färdväg vid skoteråkning",
        "雪地摩托路线",
    ),
    "Mandatory snowmobile route": (
        "Påbudt snescooterrute", "Vorgeschriebene Schneemobilroute",
        "Ruta obligatoria para motos de nieve", "Pakollinen moottorikelkkareitti",
        "Itinéraire de motoneige obligatoire", "Percorso obbligatorio per motoslitte",
        "Påbudt snøscooterløype", "Verplichte sneeuwscooterroute",
        "Påbjuden färdväg vid skoteråkning", "强制雪地摩托路线",
    ),
    "Reindeer husbandry route": (
        "Rendriftsrute", "Rentierwirtschaftsweg", "Ruta de pastoreo de renos",
        "Poronhoitoreitti", "Voie d’élevage de rennes",
        "Percorso per l’allevamento di renne", "Reindriftsvei", "Rendierhouderijroute",
        "Rennäringsled", "驯鹿放牧通道",
    ),
    "Boat route, rowing route": (
        "Bådrute, rorute", "Bootsroute, Ruderroute", "Ruta de barco, ruta de remo",
        "Veneväylä, soutureitti", "Itinéraire en bateau, itinéraire à la rame",
        "Rotta per barche, percorso a remi", "Båtrute, rorute", "Bootroute, roeiroute",
        "Trafikerad båtled, roddled", "船行航线、划船航线",
    ),
    "Boat portage": (
        "Bådtræk", "Bootsumtragestelle", "Porteo de embarcaciones",
        "Veneen vetopaikka", "Portage de bateau", "Trasporto barca a terra",
        "Båtdrag", "Bootoverdracht", "Båtdrag", "船只陆运段",
    ),
    # --- Sweden: cabins ---
    "Mountain lodge": (
        "Fjeldstation", "Berghotel", "Estación de montaña", "Tunturiasema",
        "Station de montagne", "Stazione alpina", "Fjellstue", "Berghotel",
        "Fjällstation", "山地旅馆",
    ),
    "Tourist hut, overnight hut": (
        "Turisthytte, overnatningshytte", "Touristenhütte, Übernachtungshütte",
        "Refugio turístico, refugio de pernocta", "Tunturitupa, yöpymistupa",
        "Refuge touristique, refuge d’étape", "Rifugio turistico, rifugio per pernottamento",
        "Turisthytte, overnattingshytte", "Toeristenhut, overnachtingshut",
        "Turiststuga, övernattningsstuga", "旅游小屋、过夜小屋",
    ),
    "Solitary mountain cabin": (
        "Enlig fjeldhytte", "Einzelne Berghütte", "Cabaña aislada de montaña",
        "Yksinäinen tunturimökki", "Cabane de montagne isolée",
        "Baita isolata di montagna", "Enslig fjellhytte", "Alleenstaande berghut",
        "Enslig stuga i fjällen", "山中独立小屋",
    ),
    "Rest cabin": (
        "Rastehytte", "Rasthütte", "Cabaña de descanso", "Taukotupa",
        "Abri de repos", "Rifugio di sosta", "Rastebu", "Rusthut", "Raststuga",
        "休息小屋",
    ),
    "Wind shelter": (
        "Læskur", "Windschutz", "Refugio cortavientos", "Tuulensuoja",
        "Abri coupe-vent", "Riparo dal vento", "Vindskjul", "Windscherm",
        "Vindskydd", "挡风棚",
    ),
    "Sami hut": (
        "Samisk kåte", "Samische Kote", "Cabaña sami (kåta)", "Kota",
        "Hutte sami (kåta)", "Capanna sami (kåta)", "Gamme", "Samische kota",
        "Kåta", "萨米人锥形屋",
    ),
    "Blast shelter": (
        "Beskyttelsesrum", "Schutzbunker", "Refugio antiexplosiones", "Suojahuone",
        "Abri de protection", "Ricovero antiesplosione", "Tilfluktsrom",
        "Schuilbunker", "Skyddsvärn", "防爆掩体",
    ),
    # --- Sweden: facilities ---
    "Parking": (
        "Parkering", "Parkplatz", "Aparcamiento", "Pysäköinti", "Stationnement",
        "Parcheggio", "Parkering", "Parkeerplaats", "Parkering", "停车场",
    ),
    "Helicopter pad": (
        "Helikopterplads", "Hubschrauberlandeplatz", "Helipuerto",
        "Helikopterikenttä", "Hélisurface", "Piazzola per elicotteri",
        "Helikopterplass", "Helikopterplatform", "Helikopterplats", "直升机停机坪",
    ),
    "Emergency telephone": (
        "Nødtelefon", "Nottelefon", "Teléfono de emergencia", "Hätäpuhelin",
        "Téléphone d’urgence", "Telefono di emergenza", "Nødtelefon", "Noodtelefoon",
        "Hjälptelefon", "紧急电话",
    ),
    "Bridge": (
        "Bro", "Brücke", "Puente", "Silta", "Pont", "Ponte", "Bro", "Brug", "Bro", "桥",
    ),
    "Ford": (
        "Vadested", "Furt", "Vado", "Kahlaamo", "Gué", "Guado", "Vadested",
        "Doorwaadbare plaats", "Vad", "涉水点",
    ),
    # --- Sweden: fences and restrictions ---
    "Reindeer fence": (
        "Renhegn", "Rentierzaun", "Valla para renos", "Poroaita", "Clôture à rennes",
        "Recinzione per renne", "Reingjerde", "Rendierhek", "Renstängsel", "驯鹿围栏",
    ),
    "Reindeer corral": (
        "Renfold", "Rentiergehege", "Corral de renos", "Poroerotusaita",
        "Enclos à rennes", "Recinto per renne", "Reinsamlekve", "Rendierkraal",
        "Rengärde", "驯鹿围场",
    ),
    "Camping and open fires prohibited": (
        "Telt- og bålforbud", "Zelten und offenes Feuer verboten",
        "Prohibido acampar y hacer fuego", "Telttailu ja avotuli kielletty",
        "Camping et feux interdits", "Divieto di campeggio e fuochi",
        "Telt- og bålforbud", "Kamperen en open vuur verboden",
        "Tält- och eldningsförbud", "禁止露营和明火",
    ),
    # --- Norway: trails ---
    "Marked trail": (
        "Markeret sti", "Markierter Pfad", "Sendero señalizado", "Merkitty polku",
        "Sentier balisé", "Sentiero segnalato", "Merket sti", "Gemarkeerd pad",
        "Markerad stig", "有标记的小径",
    ),
    "Unmarked trail": (
        "Umarkeret sti", "Unmarkierter Pfad", "Sendero sin señalizar",
        "Merkitsemätön polku", "Sentier non balisé", "Sentiero non segnalato",
        "Umerket sti", "Ongemarkeerd pad", "Omarkerad stig", "无标记的小径",
    ),
    "Tractor road, foot and cycle path": (
        "Traktorvej, gang- og cykelsti", "Traktorweg, Fuß- und Radweg",
        "Camino de tractor, senda peatonal y ciclista",
        "Traktoritie, jalankulku- ja pyörätie",
        "Chemin de tracteur, voie piétonne et cyclable",
        "Strada per trattori, percorso pedonale e ciclabile",
        "Traktorveg, gang- og sykkelveg", "Tractorweg, voet- en fietspad",
        "Traktorväg, gång- och cykelväg", "拖拉机道、步行与自行车道",
    ),
    "Off-road vehicle route, summer": (
        "Terrængående køretøjsrute, sommer", "Geländefahrzeugroute, Sommer",
        "Ruta para vehículos todoterreno, verano", "Maastoajoneuvoreitti, kesä",
        "Itinéraire pour véhicules tout-terrain, été",
        "Percorso per veicoli fuoristrada, estate", "Barmarksløype",
        "Terreinvoertuigroute, zomer", "Barmarksled, sommar", "越野车路线（夏季）",
    ),
    "Floodlit trail": (
        "Oplyst løjpe", "Beleuchtete Loipe", "Pista iluminada", "Valaistu latu",
        "Piste éclairée", "Pista illuminata", "Lysløype", "Verlichte loipe",
        "Elljusspår", "照明雪道",
    ),
    "Ski lift": (
        "Skilift", "Skilift", "Remonte", "Hiihtohissi", "Remontée mécanique",
        "Skilift", "Skitrekk", "Skilift", "Skidlift", "滑雪缆车",
    ),
    # --- Norway: cabins ---
    "Staffed tourist cabin": (
        "Betjent turisthytte", "Bewirtschaftete Touristenhütte",
        "Refugio turístico con servicio", "Miehitetty turistimaja", "Refuge gardé",
        "Rifugio turistico custodito", "Betjent turisthytte", "Bemande toeristenhut",
        "Bemannad turiststuga", "有人值守的旅游小屋",
    ),
    "Self-service tourist cabin": (
        "Selvbetjent turisthytte", "Selbstversorgerhütte",
        "Refugio turístico de autoservicio", "Itsepalvelutupa",
        "Refuge en libre-service", "Rifugio turistico self-service",
        "Selvbetjent turisthytte", "Zelfbedieningshut", "Självbetjäningsstuga",
        "自助式旅游小屋",
    ),
    "Unstaffed tourist cabin": (
        "Ubetjent turisthytte", "Unbewirtschaftete Touristenhütte",
        "Refugio turístico sin servicio", "Miehittämätön turistimaja",
        "Refuge non gardé", "Rifugio turistico incustodito", "Ubetjent turisthytte",
        "Onbemande toeristenhut", "Obemannad turiststuga", "无人值守的旅游小屋",
    ),
    "Lean-to shelter": (
        "Shelter", "Schutzdach", "Refugio abierto", "Laavu", "Abri ouvert",
        "Riparo aperto", "Gapahuk", "Open schuilhut", "Vindskydd", "简易避风棚",
    ),
    # --- Norway: facilities ---
    "Campsite": (
        "Campingplads", "Campingplatz", "Camping", "Leirintäalue", "Camping",
        "Campeggio", "Campingplass", "Camping", "Campingplats", "露营地",
    ),
    "Large helicopter landing site": (
        "Stor helikopterlandingsplads", "Großer Hubschrauberlandeplatz",
        "Helipuerto grande", "Suuri helikopterikenttä", "Grande hélisurface",
        "Grande piazzola per elicotteri", "Stor helikopterlandingsplass",
        "Groot helikopterlandingsterrein", "Stor helikopterplats", "大型直升机降落场",
    ),
    "Pier and jetty": (
        "Kaj og bådebro", "Kai und Steg", "Muelle y embarcadero",
        "Laituri ja venelaituri", "Quai et embarcadère", "Banchina e pontile",
        "Kai og brygge", "Kade en steiger", "Kaj och brygga", "码头与栈桥",
    ),
}


def main() -> None:
    catalog = json.loads(CATALOG.read_text())
    strings = catalog["strings"]

    # Xcode only rewrites the catalog on some builds, so create anything it has
    # not extracted yet rather than depending on build order.
    created = [key for key in TRANSLATIONS if key not in strings]

    for key, values in TRANSLATIONS.items():
        if len(values) != len(LANGUAGES):
            sys.exit(f"{key!r}: {len(values)} values for {len(LANGUAGES)} languages")
        entry = strings.setdefault(key, {})
        localizations = entry.setdefault("localizations", {})
        for language, value in zip(LANGUAGES, values):
            localizations[language] = {
                "stringUnit": {"state": "translated", "value": value}
            }

    for key in NOT_TRANSLATED:
        if key in strings:
            strings[key]["shouldTranslate"] = False

    # Xcode's own writer puts a space before the colon and sorts keys; matching
    # it keeps this script and the string catalog editor from fighting over the
    # file on every build.
    CATALOG.write_text(
        json.dumps(
            catalog,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            separators=(",", " : "),
        )
        + "\n"
    )

    still_empty = sorted(k for k, v in strings.items() if not v.get("localizations") and v.get("shouldTranslate") is not False)
    print(f"filled {len(TRANSLATIONS)} keys x {len(LANGUAGES)} languages")
    if created:
        print(f"created {len(created)} keys not yet extracted by Xcode")
    print(f"untranslated remaining: {len(still_empty)}")
    for key in still_empty:
        print(f"  {key!r}")


if __name__ == "__main__":
    main()
