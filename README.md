# deSchouwVloot — een AI-native CI/CD-pijplijn, als showcase

Gedeelde gitflow- en runner-infrastructuur voor meerdere projecten: herbruikbare workflows, een
routerende intake-poort, en een set machinaal toetsbare invarianten die de pijplijn zichzelf laten
bewaken. Geen productcode, geen domeinlogica, geen data — alleen de machinerie zelf.

Hierna kortweg **de Vloot**.

Dit is een **gecureerde, publieke kopie** van een privé-productierepo. Wat hier staat draait
echt; wat eruit is gehaald staat verderop expliciet benoemd.

> **Over de naamgeving.** Bestandsnamen en scripts dragen nog het `fleet`-voorvoegsel —
> `.fleet.yml`, `fleet-doctor.sh`, het `fleet-task`-label. Dat is bewust: dat zijn echte
> identifiers waar code en tests aan hangen, geen proza. De naam in de tekst is veranderd, de
> contracten niet.

## Inhoud

- [Waarom dit ontwerp](#waarom-dit-ontwerp)
- [Hoe het werkt](#hoe-het-werkt)
- [Beveiliging van deze repo](#beveiliging-van-deze-repo)
- [Zelf draaien](#zelf-draaien)

---

## Waarom dit ontwerp

De meeste CI-opstellingen groeien organisch: een workflow hier, een cron daar, en na een jaar weet
niemand meer welke poort wat bewaakt. Dit is een poging tot het tegenovergestelde — een pijplijn
die is **ontworpen**, met vier ideeën als ruggengraat.

### 1. Elke poort is machine-checkbaar, of het is geen poort

Menselijke aandacht is de schaarste. In het hele systeem zitten precies drie plekken waar een mens
verschijnt: feature-approval, release-approval, en escalatie bij `needs-human`. Al het andere is
doorstroom. Zie [docs/architectuur.md §3](docs/architectuur.md).

### 2. Configuratie die gedrag stuurt, is code — dus krijgt het tests

De intake-poort routeert issues naar het juiste project op basis van een trefwoordtabel. Eén te
breed trefwoord, en de unit-tests blijven groen terwijl de helft van de issues naar de verkeerde
plek stuitert. Daarom staat er naast de unit-tests een [golden-set](tests/golden/README.md):
bevroren echte gevallen met een bekende-goede uitkomst, inclusief drie **marge**-gevallen die met
2-1 winnen — een testset waarin alles met 3-0 wint, slaagt voor altijd en bewaakt dus niets.

### 3. De pijplijn repareert zichzelf; escalatie is de uitzondering

Een watchdog, een conflict-solver en een autofix-laag draaien zonder tussenkomst. De
`fleet-doctor` rapporteert hard maar muteert nooit — diagnose en mutatie zijn bewust gescheiden
bevoegdheden. Sinds kort geldt dat ook voor de KPI's zelf: een meting die alleen in een artifact
blijft liggen, wordt door niemand gelezen. Komt de permission-denial-ratio van een run boven de
drempel, dan opent de pijplijn daar zelf een issue over — van *meten* naar *melden*, zonder dat
een mens in logs hoeft te zoeken om te zien dat er iets structureel scheef staat.

### 4. Groen is geen bewijs

De gevaarlijkste storing in een pijplijn is niet de rode build — die ziet iedereen. Het is de
check die altijd hetzelfde antwoordt en daardoor van buiten niet te onderscheiden is van een check
die werkt. Deze pijplijn behandelt dat als een eigen faalklasse, met een eigen invariant per
instantie:

| | Waar "groen" misleidend zou zijn | De invariant die het nu vangt |
|---|---|---|
| **I23** | een golden-set waarin elk geval met 3-0 wint, slaagt voor altijd — geen enkel te breed trefwoord kán iets kantelen | de set moet grensgevallen met **marge 1** bevatten, anders bewaakt 'ie niets |
| **I27** | trigger, pad, naam en permissies allemaal correct, en tóch tien uur lang geen enkele run | meet het **gedrag**: liep de bron, en reageerde de luisteraar erop? |
| **I28** | een station mist een script bij de consument, draait fail-closed en merget per constructie nooit meer | de eis wordt **uit de stationsdefinitie zelf** afgeleid, niet uit een handlijst die achterloopt |
| **I24** | een pin die niet opschuift leest als groen, want een doctor-module die de gepinde versie nog niet kent wordt netjes overgeslagen | `doctor:pin` maakt achterstand en verdeelde pins een **harde** bevinding |

Vier keer dezelfde vorm, en dat het patroon één keer benoemd is, is precies waarom de vierde
gericht gevonden werd in plaats van toevallig. De verdediging is telkens hetzelfde principe: meet
het gedrag, niet de configuratie — en toets elke nieuwe guard één keer tégen de storing die 'm rood
hoort te maken, want een check die nooit rood is geweest is niet aantoonbaar een check. Zie
[docs/gitflow.md §11](docs/gitflow.md).

**Waar te beginnen:** [docs/architectuur.md](docs/architectuur.md) is de kaart — de vier lagen, de
pijplijn met z'n drie mens-poorten, het consumer-contract en het security-model.
[docs/gitflow.md](docs/gitflow.md) is de detailspec: elk station, het capaciteitsmodel, het
storingsdraaiboek en de machine-checkbare invarianten.

## Hoe het werkt

Een consument-repo levert per station een dunne caller; deze repo levert de logica:

```yaml
# in de consument, .github/workflows/checks.yml
on:
  pull_request:
jobs:
  checks:
    uses: KCTHolman/deSchouwVloot/.github/workflows/checks.yml@main
    secrets: inherit
```

Het dragende mechanisme is dat een reusable workflow draait in de context van de aanroeper:

- `runs-on: <lane>` resolvet tegen de runnerpool van de *aanroepende* repo;
- `github.repository` is de *aanroepende* repo, niet deze;
- `secrets: inherit` geeft de secrets van de *aanroeper* door.

De Vloot levert dus de logica, de consument levert de hardware en de secrets. Dat is ook waarom dit
werkt zonder GitHub-organisatie: er zijn geen org-level runners of org-secrets nodig.

### Een tweede ingang op dezelfde poort: interactief bouwen (ontwerp)

De bouwstap van de pijplijn (branch → PR) loopt nu uitsluitend via de autonome
`claude-code-action`-workflow. Interactieve, native Claude Code-sessies bouwen merkbaar prettiger
dan diezelfde Actions-runner — vandaar een ontwerp voor `/pickup #<issuenummer>`, een skill die
diezelfde bouwstap ook vanuit een chatsessie laat oppakken.

Additief, niet vervangend: de autonome workflow blijft de standaardroute voor achtergrondwerk en
werkt onveranderd door; `/pickup` is er alleen bij, voor de gevallen waarin de eigenaar zelf
meebouwt. Beide routes lopen door dezelfde gate, dezelfde claim (voorkomt dat ze hetzelfde issue
dubbel oppakken) en dezelfde bot-identiteit — geen van beide krijgt een kortere weg. Zie
[docs/architectuur.md §3c](docs/architectuur.md) voor het volledige ontwerp en de status.

Het contract tussen beide is één bestand: [`.fleet.yml`](.fleet.yml). Lanes, poorten, budgetten,
labelnamen en de "spine" (workflows waarvan uitval *stil* zou zijn). Zie
[`examples/tweede-consument.fleet.yml`](examples/tweede-consument.fleet.yml) voor hoe datzelfde
contract eruitziet bij een project met een heel andere vorm.

Dat begon als theorie en is inmiddels aantoonbaar: er draaien vier repo's op de Vloot. Naast de
productconsument en de infra-repo zelf zijn dat twee projecten met een compleet andere vorm —
andere taal, andere stack, geen self-hosted runner, alleen GitHub-hosted lanes. Voor geen van beide
is één regel fleet-logica geforkt. Dat is precies de test of de abstractie draagt: niet of het
contract *denkbaar* generiek is, maar of een project dat er niet op ontworpen is er zonder
uitzonderingen in past.

Het schaalt ook de andere kant op. Met vier bestemmingen werd de routeringspoort scherper afgesteld:
een genoemd bestandspad weegt vijf keer een trefwoord, omdat een pad iets zegt over de *plaats* en
een woord alleen over het *onderwerp* — wie `.github/workflows/pr-check.yml` noemt, verraadt al in
welke repo 'ie zit. De poort peilt dat pad bij elke consument en telt alleen wat er écht staat;
lukt die peiling niet volledig, dan wegen paden niet mee en is het gedrag exact als voorheen.

---

## Beveiliging van deze repo

Deze repo is publiek. Dat verandert de dreiging ten opzichte van het privé-origineel, en dat is
precies waar de meeste CI-ongelukken vandaan komen: niet uit slechte code, maar uit een aanname die
stilletjes vervalt. Een `on: issues`-trigger is in een privérepo een prima voordeur die alleen de
eigenaar kan gebruiken. Diezelfde trigger in een publieke repo is een anonieme voordeur voor
iedereen met een GitHub-account.

Daarom geldt hier één harde regel:

> **Geen enkele workflow in deze repo heeft een eigen trigger.**

Niet "alleen veilige triggers" — géén. Alle 16 workflows zijn `workflow_call`-only. Een reusable
workflow start nooit vanzelf; hij draait uitsluitend als een andere workflow hem expliciet
aanroept, en dan in de context van díé aanroeper: op diens runners, met diens secrets, tegen diens
repo. Roept een vreemde een workflow hieruit cross-repo aan, dan draait en betaalt hij dat volledig
zelf. Er is geen pad van publiek internet naar compute of secrets van de eigenaar.

Dat is machinaal gehandhaafd, niet alleen een belofte in proza:

```bash
bash scripts/check-no-triggers.sh
```

De guard faalt op `issues`, `pull_request`, `schedule`, `push` en `workflow_dispatch`, én op het
gevaarlijkste geval: een geldige `workflow_call` mét een verboden trigger ernaast. Hij herkent ook
de YAML-vormen die een naïeve `grep` mist — de gequote `"on":` (de YAML 1.1-booleanvalkuil) en de
inline lijstvorm `on: [push, pull_request]`. [`scripts/check-no-triggers.test.sh`](scripts/check-no-triggers.test.sh)
toetst al die gevallen.

De voorbeeld-caller in [`examples/`](examples/) heeft wél een echte trigger — dat hoort ook, want
dat is nou juist het punt: triggers leven in de consument, logica in de Vloot. Bestanden in
`examples/` staan buiten `.github/workflows/` en worden door GitHub nooit geregistreerd.

### Wat er uit deze kopie is gehaald, en waarom

Volledigheid is hier belangrijker dan een schone indruk:

| Weggelaten | Reden |
|---|---|
| De host-diagnostiekworkflow | Bracht in kaart wáár elk credential op de runner-host stond (paden en permissies, nooit inhoud). Legitiem gereedschap voor de eigenaar, maar publiek een kant-en-klare doelwitlijst. |
| Concrete hostcijfers — RAM, schijf, co-hostende diensten | Horen bij één specifieke machine; zeggen niets over het ontwerp en wél iets over waar die machine zwak staat. |
| Isolatiestatus per lane | Vermeldde per lane of hij al geïsoleerd was of nog niet. Dat is een tijdgebonden statusregel, geen ontwerpkenmerk. |
| De twee callers met echte triggers | `pull_request`/`schedule`-callers. Hun inhoud is het lezen waard, hun trigger niet. |
| Domeintrefwoorden en twee van de vier consumenten in `routing.yml` | Vervangen door neutrale voorbeelden; de tabel hier toont twee bestemmingen in plaats van vier. Dit is de enige plek waar projectkennis in de poort zit — dat is meteen het ontwerpargument: de rest van de machinerie is domeinvrij en dus deelbaar. De routeringslogica in `scripts/intake-decide.sh` is wél volledig, inclusief de pad-weging, en de golden-set toetst 'm op de tabel die hier staat. |
| Interne draaiboek-verwijzingen | Wezen naar documenten in privérepo's; als link waardeloos, als bestandsnaam soms verklappend. |

Drie wijzigingen in [`.github/workflows/intake.yml`](.github/workflows/intake.yml) zijn geen
weglating maar een verbetering, en staan voluit in de kop van dat bestand: de trigger werd
`workflow_call`, het GitHub-App-token kreeg een expliciete `repositories:`-scope in plaats van
installatiebreed, en de dedupe-stap is verwijderd omdat die issue-titels uit de doelrepo in een
comment op déze repo plaatste — prima als beide repo's dezelfde zichtbaarheid hebben, een lek zodra
dat niet meer zo is.

### Wat er bewust wél in staat

Geen secrets, in geen enkel bestand en in geen enkele commit. Wél: echte workflownamen, echte
issue-nummers uit de historie, en commentaar dat benoemt wat er ooit misging. Dat commentaar is het
waardevolste deel van deze repo — een workflow zonder de reden erachter is een workflow die de
volgende persoon met een gerust hart weer stukmaakt.

---

## Zelf draaien

Alle logica die iets beslist is een pure functie in bash of Python, offline testbaar zonder GitHub,
zonder netwerk en zonder tokens. Dat is een ontwerpkeuze: de workflows eromheen blijven dom en
voeren alleen uit, zodat het denkwerk in iets zit dat je op je laptop in een seconde kunt draaien.

```bash
# alle testsuites
for suite in scripts/*.test.sh; do bash "$suite"; done

# de golden-set: doet de routeringstabel nog wat we bedoelen?
bash scripts/golden-run.sh

# de invariant-checker op zichzelf
bash scripts/fleet-doctor.sh --module consistentie --root .

# I28: eist een aangeroepen station een script dat déze repo niet heeft?
bash scripts/fleet-doctor.sh --module afhankelijkheden --root . --fleet-root .

# I24: staat een consument te ver achter, of draagt 'ie twee verschillende pins?
bash scripts/fleet-doctor.sh --module pin --root .

# welke modules kent déze versie? (zodat een gepinde consument een typefout van
# pin-scheefstand kan onderscheiden — twee dingen die er van binnenuit identiek uitzien)
bash scripts/fleet-doctor.sh --module modules

# en het bewijs dat niets hier uit zichzelf kan vuren
bash scripts/check-no-triggers.sh
```

Nodig: `bash`, `awk`, `sed`, `python3` met PyYAML. Geen netwerk.

### En daarom is de Actions-tab hier leeg

Dat is geen nalatigheid maar de rekening van de regel hierboven. Elke workflow hier is
`workflow_call`-only, inclusief `checks.yml` — en een reusable workflow die niemand aanroept,
draait nooit. Er is in deze repo dus geen enkele automatische run; alle guards hierboven zijn
handwerk, of ze draaien in de context van een consument die ze aanroept.

Dat is een echte afweging, en de moeite waard om hardop te maken: in het licht van idee 4 hierboven
is het precies het scherpe randje. Een testsuite die niemand aftrapt, is een testsuite die altijd
hetzelfde antwoordt. Een `pull_request`-caller op `ubuntu-latest` zonder secrets zou hier veilig
zijn — maar "alleen veilige triggers" is nou juist de formulering die deze repo bewust niet
hanteert, omdat die weer op een beoordeling per geval leunt in plaats van op een eigenschap die een
script kan vaststellen. De keuze is dus: geen triggers, en de prijs zichtbaar opschrijven in plaats
van 'm te verstoppen achter een badge.
