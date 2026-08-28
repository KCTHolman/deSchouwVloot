# CI/CD-metadata-retentie-audit — vastleggen vs. laten zien (deSchouwVloot)

**Datum:** 2026-08-28 · **Scope:** alleen `KCTHolman/deSchouwVloot` zelf.
**Aanleiding:** [koenholman.nl/onderzoek/meten-is-vastleggen/](https://koenholman.nl/onderzoek/meten-is-vastleggen/),
dezelfde vraag als de zusteraudit in `KCTHolman/fleet`
(`docs/analyses/2026-08-28-cicd-metadata-retentie-audit.md` aldaar) — hier toegepast op de publieke
kopie in plaats van de bron.

**Plaatsing van dit document.** deSchouwVloot heeft geen bestaande `docs/analyses/`-conventie (de
map bestond niet); ik heb 'm aangemaakt naar analogie van de fleet-versie. Dat is hier veilig: de
sync-machinerie (`showcase-merge.sh` in de bronrepo) maakt nooit nieuwe paden aan én verwijdert
nooit bestaande, dus een pad dat alleen hier bestaat wordt door een volgende nachtelijke sync met
rust gelaten.

> **De hoofdbevinding staat vóór de inventaris, niet erna.** Deze repo is een publieke, gecureerde
> spiegel van deFleet (`showcase-sync.yml`/`showcase-guard.py`/`showcase-merge.sh` in de bronrepo).
> Het README van déze repo zegt het zelf, met opzet, in een eigen paragraaf: **"En daarom is de
> Actions-tab hier leeg"** (README.md regel 251-264). Alle 16 workflows in `.github/workflows/`
> hebben uitsluitend `on: workflow_call` — geverifieerd hieronder, niet aangenomen — en er bestaat
> in deze repo geen enkele workflow die ze aanroept. Een reusable workflow die niemand aanroept,
> draait nooit. **Er is dus geen enkele automatische CI/CD-run in deSchouwVloot, en dus ook geen
> enkel stuk run-metadata (geen `GITHUB_STEP_SUMMARY`, geen artefact, geen jobresultaat) dat hier
> ooit ontstaat.** Dat is zelf de belangrijkste bevinding van stap 1 — geen tekortkoming, een
> bewuste ontwerpkeuze (zie citaat hieronder), maar wel een keuze die deze audit fundamenteel anders
> maakt dan de fleet-versie: er is weinig pijplijn om te inventariseren, en veel meer om uit te
> leggen waaróm er weinig is.
>
> **Wat niet geverifieerd kon worden.** Repo-instellingen (branch protection op `main`, wie een PR
> mag mergen zonder review) zijn vanuit deze sessie niet op te vragen: `GET
> /repos/KCTHolman/deSchouwVloot/branches/main/protection` gaf `403 Resource not accessible by
> integration`. Elke uitspraak hieronder die daarvan afhangt, staat er expliciet bij.

## 0. Het bewijs dat de Actions-tab leeg is

| Check | Uitkomst | Bron |
|---|---|---|
| Elke workflow se `on:`-blok | Alle 16 bestanden in `.github/workflows/` hebben letterlijk alleen `workflow_call` (met of zonder `inputs:`) | zelf gegrept over alle 16 bestanden — geen enkele `push`/`pull_request`/`schedule`/`workflow_dispatch` |
| Handhaving | `scripts/check-no-triggers.sh`, een DOM tekstueel script (bewust geen YAML-parser, moet ook zonder python draaien) dat exact dit afdwingt | code + `scripts/check-no-triggers.test.sh` |
| Een caller binnen deze repo die er wél een aanroept | Bestaat niet — geen enkel bestand in `.github/workflows/` heeft een `uses: ./.github/workflows/…` naar een van de 16 | eigen scan |
| Een externe consument die deSchouwVloot's workflows aanroept | Niet aannemelijk: alle vier de echte consumenten (BiohackOS, InvestingOS, Portfolio, en deFleet zichzelf) pinnen op `KCTHolman/fleet`, niet op deSchouwVloot — deSchouwVloot is de vitrine, niet de leverancier | `routing.yml`/`.fleet.yml` in deze repo, plus de architectuurbeschrijving in `README.md` |
| Repo-eigen automatiseringsconfig (dependabot, CODEOWNERS) | Geen van beide aanwezig in `.github/` | eigen scan (`.github/` bevat alleen `workflows/`) |
| `.fleet.yml` in deze repo | Byte-voor-byte dezelfde tekst als fleet's eigen "consument-contract van deFleet zelf" — hier puur illustratief, want er draait geen enkele workflow die 'm leest | vergelijking met `/home/user/fleet/.fleet.yml` |

Het README trekt zelf de conclusie die deze audit ook trekt: *"Elke workflow hier is
`workflow_call`-only, inclusief `checks.yml` — en een reusable workflow die niemand aanroept,
draait nooit. Er is in deze repo dus geen enkele automatische run; alle guards hierboven zijn
handwerk, of ze draaien in de context van een consument die ze aanroept."* (README.md, regel
253-256). Zelfs `checks.yml` — de testsuite van deze repo's eigen shellscripts — draait dus nooit
automatisch; het README wijst in plaats daarvan naar handmatig `for suite in scripts/*.test.sh; do
bash "$suite"; done`.

## 1. Wat er tóch ontstaat — de twee mechanismen die deze repo wél raken

Geen runs, maar niet niets: twee mechanismen muteren deze repo, en beide laten VCS-metadata na.

| Mechanisme | Wat ontstaat | Komt terecht in | Bewaartermijn | Vastgesteld via |
|---|---|---|---|---|
| **Nachtelijke showcase-sync** (draait in `fleet`, port hierheen) | Eén vaste tak `sync/upstream-fleet`, bij elke run **force-pushed** (`git push --force-with-lease`) | PR tegen `main` van deSchouwVloot, geopend/bijgewerkt door `fleet-showcase-sync[bot]` | PR-object: voor altijd via de GitHub PR-API zodra gemerged; **tussentijdse commits op de tak die door een latere force-push zijn overschreven vóór iemand mergede, zijn NIET te reconstrueren** — GitHub geeft geen garantie op het bewaren van onbereikbare commits | `showcase-sync.yml` regel 196-247 in `fleet` + geverifieerd: `KCTHolman/deSchouwVloot` heeft nu **0 open PR's en 0 open issues** (GitHub API, `open_issues_count: 0`, `pulls?state=open` → `[]`, bevraagd 2026-08-28) |
| **Rechtstreekse commits/PR's op `main`** (redactiewerk, feature-werk direct in de showcase) | 7 gemergede PR's ⋯ ván 2026-07-31 (#1) t/m 2026-08-23 (#7) — **plus minstens twee commits die géén PR zijn**: `d3d744c` en `ff8333f` (auteur `Koen Holman <koenholman@gmail.com>`, geen `Merge pull request`-regel, `GET .../commits/{sha}/pulls` geeft `[]`) | git-geschiedenis + (waar van toepassing) PR-object | Git-commits: **voor altijd**, git verwijdert bereikbare geschiedenis niet. PR-metadata (`createdAt`/`mergedAt`/reviews): voor altijd via de GitHub-API, zolang de PR bestaat als object — maar geldt dus **niet** voor de twee directe commits, die nooit een PR-object hadden | GitHub API, bevraagd 2026-08-28: `pulls?state=closed` (7 resultaten) + `commits/d3d744c` (`parents: [ff8333f]`, rechtstreeks op `main`, geen mergecommit) |
| Curatiecontract (`showcase.yml`, `nooit`/`verboden`-lijsten) dat bepaalt wat hier binnenkomt | — | Leeft **alleen in `fleet`** (privé); komt zelf nooit mee de sync over — geverifieerd: geen `showcase.yml` in deze repo-checkout | git-commit in `fleet`, buiten bereik van deze audit | eigen scan van beide repo's |
| "Openstaande besluiten"-issue (conflict/schoning/nieuw-bovenstrooms per sync) | Wordt **bijgewerkt, niet herhaald** | Issue in **`fleet`** (`$GITHUB_REPOSITORY` in die workflow-run), niet in deSchouwVloot | 90 dagen op de losse run, voor altijd op het issue zelf — maar **in de verkeerde repo voor deze audit**: deSchouwVloot draagt zelf geen spoor van hoeveel bestanden ooit zijn overgeslagen | `showcase-sync.yml` regel 252-291 (`fleet`) |
| README-drift-issue | — | Issue in **`Portfolio`**, niet hier | idem | `showcase-sync.yml` regel 296-330 (`fleet`) |

**Wat dit tabelletje al laat zien:** de twee sync-side-effects die je als eerste zou verwachten —
"hoeveel bestanden liggen te wachten" en "de README loopt uit de pas" — landen allebei in een
*andere* repo dan deSchouwVloot zelf. Wie alleen deze repo raadpleegt, ziet dus **niets** van de
achterstand die de sync elke nacht meet; die zit bij `fleet` en `Portfolio`, niet hier.

**En de tweede observatie die de API-bevraging boven op tafel legt:** niet elke wijziging die hier
ooit is aangekomen, ging via een PR. `d3d744c` en `ff8333f` — de twee meest recente sync-commits —
staan rechtstreeks op `main`, met Koen als committer, zonder mergecommit en zonder PR-nummer erbij.
De commit-body van `d3d744c` bevat wél een uitgebreide, door de sync-tooling gegenereerde
verslaglegging in vrije tekst (63 bestanden gescand, welke bestanden wél/niet zijn meegenomen en
waarom) — maar dat is tekst in een commitbericht, geen gestructureerd PR-veld. Zonder toegang tot
`branches/main/protection` (zie caveat bovenaan) is niet vast te stellen of dat een uitzondering was
(bijv. een noodgeval) of de gewone gang van zaken voor sync-content — die vraag is voor déze audit
dus zelf een open vraag.

## 2. Vijf vragen voor over drie maanden

1. Hoe lang lag een gewone PR op deze repo gemiddeld open — aanmaak tot merge, en apart tot eerste
   approval?
2. Hoeveel van de wijzigingen die de afgelopen drie maanden op `main` zijn beland, gingen via een
   PR (met een review-spoor) versus rechtstreeks als commit — en verschuift die verhouding?
3. Hoe lang duurt het tussen het moment dat een wijziging in `fleet` landt en het moment dat de
   resulterende sync-PR hier gemerged is (sync-latentie, cross-repo)?
4. **deSchouwVloot-specifiek (drift):** hoeveel bestanden staan op enig moment "buiten de
   curatiegrens" te wachten — conflict, schoning-nodig, of nieuw-bovenstrooms — en groeit die
   achterstand structureel, of wordt hij elke keer weer opgelost?
5. **deSchouwVloot-specifiek (overschreven voorstellen):** hoe vaak werd de sync-tak
   (`sync/upstream-fleet`) door een volgende nachtelijke run overschreven vóórdat er iemand naar
   keek — dus hoeveel tussentijdse syncvoorstellen zijn nooit door een mens beoordeeld?

*Bewust weggelaten uit dit rijtje: de klassieke reeks uit het artikel ("hoe vaak rood", "hoeveel
pogingen tot groen", "hoeveel zonder mens door") — die veronderstelt een poort die hier draait, en
die is er niet (§0). Ze zouden in deze repo altijd hetzelfde antwoord geven: nul runs, dus nul
rode runs, dus het getal "hoeveel pogingen tot groen" bestaat niet als concept. Vraag 2 hierboven is
de dichtstbijzijnde herformulering die wél iets meet: niet "ging het door de poort", maar "ging het
via het enige spoor dat hier wél metadata nalaat (een PR) of niet".*

## 3. Is het antwoord er over drie maanden nog?

| # | Vraag | Categorie | Toelichting |
|---|---|---|---|
| 1 | PR-doorlooptijd (open→merge, open→approval) | **Sterke (c)** voor PR's die als PR liepen: `gh pr list --json createdAt,mergedAt,reviews` is platform-waarheid, GitHub verwijdert gemergede PR's niet. **Ontbreekt volledig** voor de twee directe commits — daarvoor bestaat het concept "PR-doorlooptijd" niet, dat is geen (d) maar een niet-toepasselijkheid | Het verschil tussen "de waarde is er niet meer" en "de waarde heeft nooit bestaan" is hier concreet zichtbaar, niet hypothetisch |
| 2 | PR vs. directe commit, verhouding | **Sterke (c), maar met handwerk.** Reconstructie moet per commit-SHA op `main` nagaan of 'ie voorkomt als merge-commit van een bekende PR (`GET /commits/{sha}/pulls`) — dat kán vandaag al, precies zoals ik het hierboven voor `d3d744c`/`ff8333f` deed. Het is structureel te herhalen, dus geen gok, maar niemand telt het vandaag en er is geen kant-en-klaar rapport | Sterk omdat de bronvelden (commit-parents, PR-lijst) allebei platform-data zijn; het is geen giswerk uit een titel |
| 3 | Sync-latentie (fleet-commit → hier gemerged) | **Sterke (c)**, cross-repo: de commit-datum in `fleet` (git/commits-API, voor altijd) en de PR-`mergedAt` hier (voor altijd) zijn allebei structurele platform-tijdstempels. Vereist wel toegang tot beide repo's tegelijk om te koppelen — dat heeft deze sessie, een toekomstige lezer met alleen deSchouwVloot-toegang niet vanzelf | Voor de twee directe commits (geen PR) is dit **(d)**: geen `mergedAt` om aan te koppelen, alleen de commit-datum zelf, die niets zegt over hoe lang de review duurde omdat er geen review was |
| 4 | Curatie-achterstand (conflict/schoning/nieuw-bovenstrooms), en de trend erin | **(b)/(d) gemengd, en in de verkeerde repo.** Het *huidige* getal staat (a)-achtig in het "openstaande besluiten"-issue — maar dat issue leeft in `fleet`, niet hier, en wordt bij elke run **overschreven**, dus er is nergens een tijdreeks van eerdere standen. Om een trend te zien moet iemand elke run het issue lezen vóórdat de volgende 'm overschrijft — vandaag gebeurt dat niet | Exact het patroon uit `watermerken`/`aantekeningen` in fleet's eigen audit: een levende teller zonder geheugen van eerdere waarden |
| 5 | Overschreven sync-voorstellen (force-push vóór review) | **(d), hard.** `git push --force-with-lease` vervangt de tak; de oude commits worden onbereikbaar. GitHub biedt geen gedocumenteerde garantie dat onbereikbare commits een vaste tijd blijven staan (in tegenstelling tot de wél-gedocumenteerde 90-dagen-log-/artifactretentie). Er is vandaag geen enkele plek — issue, log, database — die bijhoudt hóe vaak dit gebeurde | Dit is het scherpste voorbeeld in deze audit van "laten zien, niet vastleggen": de PR die je nu ziet is per definitie de laatste in de rij; hoeveel voorgangers hij had, is al bij de tweede overschrijving niet meer op te vragen |

## 4. Waar had het moeten worden opgeschreven

Voor de vragen uit categorie (b)/(d): het station, en het veld — bij voorkeur een bestaande OTel
CI/CD-/VCS-naam.

- **Er is voor bijna geen van deze vragen een station ín deSchouwVloot zelf beschikbaar om aan te
  haken — en dat is zelf het antwoord.** Omdat geen enkele workflow hier ooit draait (§0), bestaat
  er geen stap die op het moment zelf `cicd.pipeline.*` of `vcs.change.*` zou kunnen emitten. Elke
  aanhaking moet dus vanaf de kant komen die wél schrijftoegang en een lopende workflow heeft: de
  bronrepo `fleet`, op het moment dat die de push/PR naar deSchouwVloot doet.
- **Vraag 2 (PR vs. directe commit):** op het moment vlak vóór `git push` in
  `showcase-sync.yml` (regel 223, `fleet`) — dat is de enige plek waar de machinerie zelf al weet of
  wat ze doet een PR opent of niet. Veld: **`vcs.change.id`** (het PR-nummer, of leeg als het geen
  PR wordt) naast **`vcs.revision_delta.direction`** (ahead/behind t.o.v. `main` van deSchouwVloot
  op dat moment) — dat legt exact vast wat een latere API-reconstructie vandaag nog met moeite moet
  combineren. Voor de twee waargenomen directe commits geldt: die liepen sowieso niet via
  `showcase-sync.yml` (dat opent altijd een PR, nooit een directe push), dus die twee zijn per
  definitie via een ander, hier onzichtbaar kanaal ontstaan — vermoedelijk een handmatige
  `git push` door de eigenaar. Dát instrumenteren kan niet vanuit een workflow; het enige station
  is de mens die het commando typt.
- **Vraag 3 (sync-latentie):** ook in `showcase-sync.yml`, in de stap "Basis bepalen" (regel
  119-137, `fleet`) — die kent op dat moment al de vorige en de nieuwe `Upstream-Sha`. Veld:
  **`vcs.change.time_to_merge`** zou hier niet de juiste naam zijn (dat meet PR-doorlooptijd, niet
  cross-repo-latentie) — er is geen OTel-veld voor "tijd tussen ontstaan in bron A en landen in
  kopie B". Terecht een projecteigen veld, bijvoorbeeld `showcase.sync_latency_seconds`, geschreven
  naast de bestaande **`cicd.pipeline.run.id`** van de sync-run zelf.
- **Vraag 4 (curatie-achterstand, trend):** in dezelfde stap die vandaag al `conflicten`/`nieuw`/
  `schoning` telt (`showcase-sync.yml` regel 146-155, `fleet`) — alleen dan **toevoegen aan** een
  tijdreeks in plaats van het ene issue te overschrijven. Geen OTel-veld dekt "curatie-achterstand";
  dit is, net als `later_teruggedraaid` in fleet's eigen audit, een projectbeslissing zonder
  platformequivalent.
- **Vraag 5 (overschreven voorstellen):** vlak vóór de `git push --force-with-lease` zelf (regel
  223) is het enige moment waarop de SHA die dadelijk onbereikbaar wordt nog bekend is. Er bestaat
  geen OTel-veld voor "dit voorstel is nooit bekeken" — het dichtstbijzijnde platformconcept is
  **`vcs.revision_delta.direction`**, maar dat beschrijft een verschíl tussen twee revisies, niet
  het feit dát een revisie werd weggegooid zonder beoordeling. Ook dit blijft dus terecht
  projecteigen: bijvoorbeeld één regel appenden aan een klein bestand of issue-log met de oude en
  nieuwe SHA, in plaats van de tak in stilte te vervangen.

## 5. Wat ik zou weglaten

**Instrumenteer geen van de 16 workflows in déze repo met de velden uit stap 4** — niet
`checks.yml`, niet `auto-merge.yml`, niet welke van de zestien dan ook. Dat is geen algemene
voorzichtigheid maar een concrete, bewezen dode plek: `scripts/check-no-triggers.sh` toont dat elke
workflow hier uitsluitend `on: workflow_call` heeft, en er bestaat in deze repo geen enkele caller
die ze aanroept (§0). Een `GITHUB_STEP_SUMMARY`-regel met `cicd.pipeline.result` of een emit-stap
die je in bijvoorbeeld `doctor.yml` zou zetten, bereikt hier bewijsbaar nooit een run — het zou
onderhoud zijn voor een lezer die niet kan bestaan, want er is geen executie om over te
rapporteren. Wil je die velden wél zien, dan hoort de instrumentatie bij de bron (`fleet`, waar
deze workflows *wel* draaien, aangeroepen door de echte consumenten), niet bij de kopie. Dat is
precies de fout die deze audit had kunnen maken door de vragen uit `docs/gitflow.md`/`AGENTS.md`
hier één-op-één na te doen zonder eerst §0 vast te stellen.

---

*Bronnen: [1] `KCTHolman/deSchouwVloot` GitHub API, bevraagd 2026-08-28 (`/pulls?state=closed`,
`/pulls?state=open`, `/issues?state=open`, `/commits/{sha}`, `/commits/{sha}/pulls`,
`/branches/main/protection` — laatste gaf `403`, zie caveat) · [2] `README.md` regel 251-264 in
deze repo · [3] `scripts/check-no-triggers.sh` in deze repo · [4] `showcase-sync.yml` en
`.fleet.yml` in `KCTHolman/fleet` (deze sessie had toegang tot beide repo's; een lezer met alleen
deSchouwVloot-toegang kan [4] niet zelf verifiëren).*
