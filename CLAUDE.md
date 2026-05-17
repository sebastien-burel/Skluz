# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## État du dépôt

Les **10 phases** de `PLAN_SKLUZ.md` sont implémentées, plus la réadoption des tunnels orphelins (hors plan, décidée avec Sébastien). Le projet est fonctionnel ; reste à exécuter la signature/notarisation (cf. `NOTARIZATION.md`, action de Sébastien).

**`PLAN_SKLUZ.md` reste le document de référence** : il fait autorité sur l'architecture et les choix techniques. Si tu détectes une contradiction entre ce CLAUDE.md et le plan, le plan gagne (signale-la à Sébastien). Continuer à valider visuellement chaque changement notable avant de l'enchaîner.

## Ce que Skluz est

Gestionnaire de tunnels SSH macOS, app **menu bar uniquement** (`LSUIElement = YES`, pas d'icône Dock, pas de fenêtre principale). Chaque tunnel est un `Process` qui lance `/usr/bin/ssh`. État persisté en JSON dans `~/Library/Application Support/Skluz/tunnels.json`.

- **Plateforme** : macOS 26.5+ (Tahoe), Swift 6 strict concurrency, SwiftUI + AppKit (`NSStatusItem`).
- **Bundle ID** : `net.haruni.skluz` — éditeur Haruni SAS.
- **Distribution** : Developer ID signé + notarisé, **pas App Store** (besoin de `Process`, sandbox désactivé).

## Architecture en deux mots

Deux actors Swift 6 forment le cœur :

- **`TunnelStore`** (actor) : persistance JSON + état en mémoire de la liste des tunnels.
- **`TunnelRunner`** (actor) : gestion du cycle de vie des `Process` SSH (start/stop/restart, capture stderr → `LogStore`, backoff exponentiel auto-restart).

L'UI SwiftUI observe via `@Observable` (macros Swift 6), **pas de Combine**. Tous les modèles traversant les frontières d'actor doivent être `Sendable`.

Voir `PLAN_SKLUZ.md` §2 pour l'arborescence cible des fichiers, §4 pour le modèle de données, §6 pour le cycle de vie d'un tunnel.

## Méthode de travail

Le plan impose un découpage **phase par phase** (10 phases). Règles à respecter :

- **Implémenter une seule phase à la fois.** Faire valider visuellement par Sébastien avant de passer à la suivante.
- Chaque phase doit être **compilable et testable** à elle seule.
- **Demander plutôt qu'inventer** : si une décision d'archi n'est pas dans le plan, poser la question.
- Si tu vois un bug dans le plan lui-même, le signaler **avant** d'écrire du code basé dessus.

## Invariants critiques (à ne jamais enfreindre)

Ces points sont des sources de bugs subtils ou de failles de sécurité — toute déviation doit être justifiée explicitement :

- **Chemin SSH** : toujours `/usr/bin/ssh` en absolu. Jamais de résolution `PATH`.
- **Jamais de shell** : passer les arguments via `Process.arguments` (tableau). **Ne jamais** construire une string et l'envoyer à `/bin/sh` — ouvre la porte à l'injection.
- **Options SSH par défaut obligatoires** (cf. §5 du plan) :
  - `-N -T` (pas de commande, pas de pty).
  - `-o ServerAliveInterval=30 -o ServerAliveCountMax=3`.
  - `-o ExitOnForwardFailure=yes` — crucial : un port local déjà pris doit faire sortir ssh immédiatement plutôt que de laisser un process zombie.
  - `-o StrictHostKeyChecking=accept-new` — accepter les nouveaux hosts, refuser les changements de clé. **Ne jamais désactiver** host key checking par défaut.
- **`~/.ssh/config` est lu, jamais écrit.** Aucune modification, jamais.
- **Pas de stockage de credentials** : authentification uniquement via clés SSH + agent système. Pas de mot de passe, pas de Keychain (en v1).
- **Logs en buffer circulaire** (1000 lignes max par tunnel). Un tunnel verbeux sur plusieurs jours ne doit pas consommer toute la RAM.
- **Lecture continue des `Pipe`** stdout/stderr (`readabilityHandler` ou `bytes`) — sinon SIGPIPE bloque le child.
- **Persistance atomique** : écriture en fichier temporaire puis `rename`.

## Tests minimaux attendus

Au minimum un test unitaire sur **la construction des arguments SSH** dans `TunnelRunner` : donner un `Tunnel`, vérifier le tableau d'args produit. C'est là que les régressions silencieuses se cachent (le tunnel "marche" mais avec les mauvaises options).

## Commandes courantes

Scheme : `Skluz`. Cibles de test : `SkluzTests` (unitaires, Swift Testing) ;
`SkluzUITests` est du boilerplate neutralisé (app menu bar sans fenêtre).

```sh
# Build Debug
xcodebuild -project Skluz.xcodeproj -scheme Skluz -configuration Debug \
  -destination 'platform=macOS' build

# Toute la suite de tests
xcodebuild -project Skluz.xcodeproj -scheme Skluz -destination 'platform=macOS' test

# Test ciblé (Swift Testing : Suite/fonction)
xcodebuild -project Skluz.xcodeproj -scheme Skluz -destination 'platform=macOS' \
  test -only-testing:SkluzTests/SSHCommandBuilderTests/localForwardWithUserAndCustomSSHPort

# Lancer l'app buildée (chemin DerivedData variable selon la machine)
open -n "$(xcodebuild -project Skluz.xcodeproj -scheme Skluz -showBuildSettings \
  2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Skluz.app"
```

Régénérer l'AppIcon : `swift Tools/generate_appicon.swift`.
Signature Developer ID + notarisation : voir `NOTARIZATION.md`.

## Langue

- Conversations et issues internes : **français** (Sébastien est francophone, le plan est en français).
- Identifiants, commentaires de code, messages de commit : **anglais** (cf. préférences globales).
- Strings d'UI utilisateur : français par défaut en v1. Une localisation breton (`br`) est listée en extension future (cf. §13 du plan), à ignorer pour l'instant.
