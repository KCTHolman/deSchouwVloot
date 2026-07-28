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

deFleet heeft géén eigen constitution. De grondwet van een consument geldt voor het werk dát die
consument doet; deze repo levert alleen de machinerie eromheen. Bij twijfel of iets fleet- of
domeinlogica is: staat er een productnaam, een tabelnaam of een toolchain in, dan is het domein.

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
