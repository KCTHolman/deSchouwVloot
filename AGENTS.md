# AGENTS.md — werkwijze in deFleet

Dunne laag. Wat deze repo is en hoe de cross-repo-aanroep werkt staat in [README.md](README.md);
wat waarheen gaat in de interne workflow-inventaris. Herhaal dat hier
niet.

## Harde grenzen

- **Geen gezondheidsdata, ooit.** Deze repo raakt geen enkele datastroom van een consument. Komt
  er een wijziging die dat wél zou doen, dan hoort die in de consument-repo thuis, niet hier.
- **Geen secrets in deze repo.** Elke consument levert z'n eigen secrets via `secrets: inherit`.
  Een workflow hier declareert secrets alleen als `required: false` met een expliciet
  gedocumenteerde degradatie (zie hoe `pick-runner` omgaat met een ontbrekende
  `RUNNER_CHECK_TOKEN`: terugvallen op `ubuntu-latest`, nooit stil anders falen).
- **Host = alleen lezen.** Diagnostiek op de self-hosted host is read-only en sudo-loos. Iets repareren op
  de host is owner-assist: de eigenaar voert het zelf uit.
- **Verhuizen ≠ verbeteren.** Een workflow gaat één-op-één over uit BiohackOS, inclusief
  commentaar en bekende scherpe randjes. Verbeteren is een aparte PR daarna.

## Bron-hiërarchie

deFleet heeft géén eigen constitution voor domeinwerk. De grondwet van een consument geldt voor
het werk dát die consument doet; deze repo levert alleen de machinerie eromheen. Bij twijfel of
iets fleet- of domeinlogica is: staat er een productnaam, een tabelnaam of een toolchain in, dan
is het domein. Voor **fleet's eigen werkadministratie** (issues/epics in déze repo, label
`fleet-task`) geldt wél een eigen, smal mandaat — zie hieronder.

## Poort #1 (feature-approval) — zelf te sluiten op fleet's eigen werk (2026-08-21)

**Vastgelegd op expliciet verzoek van Koen.** Er blijven **twee** mens-poorten
([gitflow.md §1](docs/gitflow.md) / [architectuur.md §3](docs/architectuur.md)): feature-approval
en release-approval. Wat wijzigt is **hoe poort #1 gesloten mag worden** wanneer het gaat om
**déze repo's eigen fleet-task-werk** (nooit consumentwerk — dat blijft onder de grondwet van die
consument): een CLI-/agentsessie mag zelfstandig een issue/epic aanmaken, via de CLI oplossen
(branch → PR, dezelfde conventies als de machinerie: conventional-commit-titel, `Fixes #N`, één
issue = één PR) en poort #1 zelf sluiten — zelf mergen + het issue sluiten, zonder op Koens
PR-approval te wachten — **uitsluitend** wanneer **alle** onderstaande voorwaarden gelden.
Ontbreekt er ook maar één, dan sluit poort #1 zoals altijd: wachten op Koens approval (of
app-identiteit + approval, zie gitflow.md §1).

**Voorwaarden om poort #1 zelf te sluiten (alle vier, geen uitzondering):**

- **Groen, zonder omweg.** Alle vereiste checks (`PR check gate`, `impactanalyse`,
  `consistency-doctor` waar van toepassing) staan groen. Nooit een rode of `SKIPPED` check
  overrulen, nooit `gh run rerun` gebruiken om "groen" te forceren (draaiboekpunt 2).
- **Binnen de harde grenzen.** Geen gezondheidsdata, geen secrets, geen host-mutatie, I1
  (`workflow_call`-uitsluitendheid) intact, en verhuizen ≠ verbeteren — precies de vier grenzen
  bovenaan dit document, ongewijzigd.
- **Niet de spine, niet deze bevoegdheid zelf.** Wijzigingen aan `auto-merge.yml` (de spine, "hoog
  risico" in architectuur.md §9) of aan déze paragraaf zelf blijven altijd eigenaar-only, ook als
  de checks toevallig groen zijn. Zelfverruiming van deze bevoegdheid is er per definitie van
  uitgesloten.
- **Bewijs in de PR.** De PR-body benoemt expliciet dat poort #1 zelf gesloten is en welke van de
  bovenstaande voorwaarden zijn geverifieerd — dat is het controleerbare spoor achteraf, in de
  geest van het bewijsplicht-principe (gitflow.md §13.B).

**Wat expliciet ongewijzigd blijft:** poort #2 (release-approval, production-Environment met
required reviewer), elk `owner-gate`-gelabeld issue, credential-/host-/org-stappen, en
`needs-human`-escalaties. Er komt geen derde poort bij — dit is uitsluitend een andere manier om
poort #1 te sluiten, beperkt tot deFleet's eigen repo. Twijfel of iets binnen deze voorwaarden
valt → de standaardregel (wachten op Koen) geldt, nooit andersom.

## Conventies

- **Naam met bucketprefix**: `name: "[fleet] …"`. De consument houdt dezelfde prefixen aan, zodat
  beide Actions-lijsten dezelfde driedeling tonen.
- **Alles is `workflow_call`** tenzij het echt alleen deFleet zelf aangaat. Een fleet-workflow met
  een eigen `schedule` of `push`-trigger draait in deFleet's context en ziet dus géén consument —
  dat is bijna altijd een fout.
- **Commentaar in het Nederlands, met de reden erbij.** Identifiers, inputs en outputs in het
  Engels. Een comment dat alleen herhaalt wát er staat is ruis; schrijf op waaróm het er staat en
  wat er misging toen het er niet stond.
- **Geen magische labels.** Lane-namen (`biohack-agent`/`-heavy`/`-light`) komen via inputs binnen,
  nooit hardgecodeerd in een nieuwe workflow — met één gedocumenteerde uitzondering: de pick-job
  van `pick-runner` draait vast op `biohack-light` om te voorkomen dat 'ie de lane bezet houdt die
  'ie zelf opmeet.

## Voor je iets verhuist

1. Staat de probe groen bij de consument? Zo nee, eerst dat — anders debug je een verhuizing
   terwijl het mechanisme zelf nog niet bewezen is.
2. Draait de te verhuizen workflow al op `workflow_call`? Zo nee, dat ombouwen is stap 1 en een
   eigen PR — in de consument-repo, waar 'ie nu nog staat.
3. Wie roept 'm aan? Tel de aanroepers vóór je verhuist; die moeten allemaal in dezelfde PR mee
   van `uses: ./.github/workflows/x.yml` naar `uses: KCTHolman/fleet/.github/workflows/x.yml@main`.
4. Pin je `@main` of een tag? Voorlopig `@main` — deFleet en z'n consumenten bewegen nog samen.
   Zodra een tweede consument live staat, wordt dit een tag/SHA-besluit.
